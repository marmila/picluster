#!/bin/bash
# Weekly cluster status digest, sent to the alerts ntfy topic every Monday morning
# (CronJob weekly-digest, homelab-docs/alerting.md "Weekly digest").
#
# Layout: problems first ("To look at", one line each), then short summary lines. Normal values
# are summed up (ranges, maxima); a node or object is named only when it needs a look.
#
# Read-only: Prometheus instant queries only, one ntfy message (at most ~3.8 KB, under the
# 4096-byte ntfy limit). Any failed query or send exits non-zero, so KubeJobFailed fires.
#
# Env:
#   NTFY_URL     alerts topic URL from Vault (alertmanager/notifications ntfy_url); its query
#                string (Alertmanager template parameters) is dropped, never printed.
#   PROM_URL     Prometheus base URL.
#   FLUX_IGNORE  regex of Flux object names left out (default: the e-commerce demo stack).
set -euo pipefail

PROM="${PROM_URL:-http://kube-prometheus-stack-prometheus.kube-prom-stack.svc:9090}"
NTFY="${NTFY_URL%%\?*}"
FLUX_IGNORE="${FLUX_IGNORE:-e-commerce.*}"
UN='on (instance) group_left (nodename) node_uname_info{job="node-exporter"}'

# Thresholds for naming something under "To look at".
TEMP_PI=60 TEMP_X86=75      # 10 °C below NodeTemperatureHigh
DISK_ROOT=70 DISK_STORAGE=80
RESTARTS=50                 # restarts of one pod in 7 days
CERT_DAYS=14

# q <promql> [jq expression for the label]: one "label<TAB>value" line per series.
q() {
  local label="${2:-.metric.nodename}"
  curl -fsS --max-time 30 -G "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | jq -r "(.data.result // [])[] | \"\\(${label})\\t\\(.value[1])\""
}
# Single value (first series), or the default when the query returns nothing.
v() { local out; out=$(q "$1" '""' | head -1 | cut -f2); echo "${out:-${2:-0}}"; }
# "label<TAB>value" lines -> "a 1 · b 2". The format gets: separator, label, value.
join() { awk -F'\t' -v f="$1" 'NF { printf f, (n++ ? " · " : ""), $1, $2 } END { if (!n) printf "none" }'; }

todo=()   # lines for "To look at"

# --- Nodes -------------------------------------------------------------------------------
ready=$(v 'sum(kube_node_status_condition{condition="Ready",status="true"})')
total=$(v 'count(kube_node_info)')
[ "$ready" = "$total" ] || todo+=("Nodes: only $ready of $total Ready")
rebooted=$(q "(time() - node_boot_time_seconds{job=\"node-exporter\"}) * $UN < 7 * 86400" | sort \
  | awk -F'\t' '{ printf "%s%s %.0fd ago", (n++ ? " · " : ""), $1, $2 / 86400 } END { if (!n) printf "none" }')

# --- Temperature: Pi SoC on aarch64, CPU (coretemp) on x86_64; the x86 chipset is left out --
temps=$(q 'max by (nodename, machine) (
    (max_over_time(node_hwmon_temp_celsius{job="node-exporter",chip="thermal_thermal_zone0"}[7d])
      * on (instance) group_left (nodename, machine) node_uname_info{job="node-exporter",machine="aarch64"})
    or
    (max_over_time(node_hwmon_temp_celsius{job="node-exporter",chip=~"platform_coretemp_.*"}[7d])
      * on (instance) group_left (nodename, machine) node_uname_info{job="node-exporter",machine="x86_64"}))' \
  '"\(.metric.nodename) \(.metric.machine)"')
temp_line=$(printf '%s\n' "$temps" | awk -F'\t' 'NF == 2 { split($1, a, " "); k = (a[2] == "x86_64" ? "HP" : "Pi")
    if (!(k in lo) || $2 < lo[k]) lo[k] = $2; if (!(k in hi) || $2 > hi[k]) hi[k] = $2 }
  END { s = ""; for (k in lo) s = s (s ? " · " : "") sprintf("%s %.0f–%.0f°C", k, lo[k], hi[k]); print (s ? s : "no data") }')
hot=$(printf '%s\n' "$temps" | awk -F'\t' -v p="$TEMP_PI" -v x="$TEMP_X86" 'NF == 2 { split($1, a, " ")
  if ($2 >= (a[2] == "x86_64" ? x : p)) printf "%s%s %.0f°C", (n++ ? " · " : ""), a[1], $2 }')
[ -z "$hot" ] || todo+=("Hot this week: $hot")
softtemp=$(q "max_over_time(rpi_throttled_flag{flag=\"soft_temp_limit_now\"}[7d]) * $UN > 0" | cut -f1 | paste -sd' ')
[ -z "$softtemp" ] || todo+=("Pi soft temperature limit hit: $softtemp")

# --- Disks -------------------------------------------------------------------------------
disk() {  # disk <mountpoint>: "nodename<TAB>percent", fullest first
  q "sort_desc(max by (nodename) ((1 - node_filesystem_avail_bytes{job=\"node-exporter\",mountpoint=\"$1\"} / node_filesystem_size_bytes{job=\"node-exporter\",mountpoint=\"$1\"}) * 100 * $UN))"
}
root=$(disk /); storage=$(disk /storage)
max_of() { printf '%s\n' "$1" | awk -F'\t' 'NF && !n++ { printf "%.0f%% %s", $2, $1 } END { if (!n) printf "n/a" }'; }
full=$( { printf '%s\n' "$root" | awk -F'\t' -v t="$DISK_ROOT" 'NF && $2 >= t { printf "%s /\t%s\n", $1, $2 }'
          printf '%s\n' "$storage" | awk -F'\t' -v t="$DISK_STORAGE" 'NF && $2 >= t { printf "%s /storage\t%s\n", $1, $2 }'; } \
        | join '%s%s %.0f%%')
[ "$full" = "none" ] || todo+=("Disk filling: $full")

# --- Alerts ------------------------------------------------------------------------------
NOISE='alertname!~"Watchdog|InfoInhibitor"'
fired=$(q "sort_desc(count by (alertname) (max_over_time(ALERTS{alertstate=\"firing\",$NOISE}[7d])))" '.metric.alertname')
kinds=$(printf '%s' "$fired" | grep -c . || true)
top=$(printf '%s' "$fired" | head -3 | join '%s%s %.0f')
firing=$(q "count by (alertname) (ALERTS{alertstate=\"firing\",$NOISE})" '.metric.alertname' | join '%s%s%.0s')
[ "$firing" = "none" ] || todo+=("Firing now: $firing")

# --- Velero --------------------------------------------------------------------------------
vel_age=$(v '(time() - max(velero_backup_last_successful_timestamp)) / 3600' -1)
vel_fail=$(v '(sum(increase(velero_backup_failure_total[7d])) or vector(0)) + (sum(increase(velero_backup_partial_failure_total[7d])) or vector(0))')
vel_ok=$(awk -v a="$vel_age" 'BEGIN { printf (a < 0 ? "no successful backup" : "OK %.0fh ago"), a }')
awk -v a="$vel_age" 'BEGIN { exit !(a < 0 || a > 30) }' && todo+=("Velero: $vel_ok")
awk -v f="$vel_fail" 'BEGIN { exit !(f >= 0.5) }' && todo+=("Velero: $(printf '%.0f' "$vel_fail") failed/partial backup(s) this week (last $vel_ok)")

# --- Certificates ---------------------------------------------------------------------------
cert=$(q 'bottomk(1, (min by (name) (certmanager_certificate_expiration_timestamp_seconds) - time()) / 86400)' '.metric.name' | head -1)
cert_days=$(printf '%s' "$cert" | cut -f2); cert_name=$(printf '%s' "$cert" | cut -f1)
awk -v d="${cert_days:-999}" -v t="$CERT_DAYS" 'BEGIN { exit !(d < t) }' && todo+=("Certificate $cert_name expires in $(printf '%.0f' "$cert_days") days")
cert_bad=$(q 'certmanager_certificate_ready_status{condition="False"} == 1' '.metric.name' | cut -f1 | paste -sd' ')
[ -z "$cert_bad" ] || todo+=("Certificates not ready: $cert_bad")

# --- Longhorn (robustness 1 healthy, 2 degraded, 3 faulted, 0 detached) -----------------------
lh_bad=$(q 'longhorn_volume_robustness >= 2' '"\(.metric.volume)\(if .value[1] == "3" then " FAULTED" else " degraded" end)"' | cut -f1 | awk 'NF { printf "%s%s", (n++ ? " · " : ""), $0 }')
[ -z "$lh_bad" ] || todo+=("Longhorn: $lh_bad")

# --- Flux: only objects that failed (ready=False); Unknown = still reconciling -----------------
flux_bad=$(q "gotk_resource_info{ready=\"False\",name!~\"$FLUX_IGNORE\"}" '.metric.name' | cut -f1 | sort -u)
flux_n=$(printf '%s' "$flux_bad" | grep -c . || true)
if [ "$flux_n" -gt 0 ]; then
  more=""; [ "$flux_n" -le 5 ] || more=" +$((flux_n - 5))"
  todo+=("Flux not ready ($flux_n): $(printf '%s\n' "$flux_bad" | head -5 | awk 'NF { printf "%s%s", (n++ ? " · " : ""), $0 }')$more")
fi

# --- Pods restarting a lot ------------------------------------------------------------------------
crashy=$(q "topk(3, sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[7d]))) >= $RESTARTS" \
  '"\(.metric.namespace)/\(.metric.pod)"' | sort -t$'\t' -k2 -rn | join '%s%s %.0f×')
[ "$crashy" = "none" ] || todo+=("Restarting a lot this week: $crashy")

# --- Raspberry Pi under-voltage: minutes with at least one kernel dip message ------------------
uv=$(q "sum by (nodename) (count_over_time((rpi_undervoltage_events_recent > 0)[7d:1m]) * $UN)" | sort | join '%s%s %.0f min')
[ "$uv" = "none" ] || todo+=("Under-voltage: $uv")

# --- RustFS buckets on node1: size (>= 1 GB) and 7-day growth (empty during the first week) ----
q 'sort_desc(rustfs_bucket_size_bytes)' '.metric.bucket' > /tmp/size
q 'rustfs_bucket_size_bytes - rustfs_bucket_size_bytes offset 7d' '.metric.bucket' > /tmp/growth
rustfs=$(awk -F'\t' 'FILENAME ~ /growth/ { g[$1] = $2; next } $2 >= 1e9 { b = $1; sub(/^k3s-/, "", b)
    printf ($2 < 1e10 ? "%s%s %.1fG" : "%s%s %.0fG"), (n++ ? " · " : ""), b, $2 / 1e9; if ($1 in g) printf " (%+.1fG)", g[$1] / 1e9 }
  END { if (!n) printf "no data" }' /tmp/growth /tmp/size)
orphans=$(v 'sum(rustfs_bucket_orphan_bytes) / 1e9')

# --- Message ------------------------------------------------------------------------------------
{
  if [ "${#todo[@]}" -eq 0 ]; then
    echo "✅ Nothing to look at"
  else
    echo "⚠️ To look at"
    printf '• %s\n' "${todo[@]}"
  fi
  echo
  echo "📋 Nodes $ready/$total Ready · Longhorn ${lh_bad:+not }healthy · next cert $([ -n "$cert_days" ] && printf "%.0fd" "$cert_days" || echo n/a) · Velero $vel_ok"
  echo "🌡️ Max temp: $temp_line"
  echo "💾 Disk: / max $(max_of "$root") · /storage max $(max_of "$storage")"
  echo "🪣 RustFS: $rustfs · orphaned $(printf '%.1f' "$orphans")G"
  if [ "$kinds" -gt 0 ]; then
    echo "🔔 Alerts: $kinds kinds fired, $([ "$firing" = none ] && echo "none" || echo "some") firing now"
    echo "   Top: $top"
  else
    echo "🔔 Alerts: none fired this week"
  fi
  echo "🔁 Rebooted: $rebooted"
} > /tmp/msg
msg=$(head -c 3800 /tmp/msg | iconv -c -f UTF-8 -t UTF-8)

n=${#todo[@]}; week=$(date +%G-W%V)
if [ "$n" -eq 0 ]; then prio=3; tags=bar_chart; title="Weekly digest $week: all good"
else prio=4; tags=bar_chart; title="Weekly digest $week: $n to look at"; fi

printf '%s\n\n%s\n' "$title" "$msg"
curl -fsS --max-time 30 -o /dev/null -H "Title: $title" -H "Tags: $tags" -H "Priority: $prio" \
  --data-binary "$msg" "$NTFY"
echo "sent ($(printf '%s' "$msg" | wc -c) bytes)"
