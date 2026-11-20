#!/bin/bash
# Weekly cluster status digest, sent to the alerts ntfy topic every Monday morning
# (CronJob weekly-digest, homelab-docs/alerting.md "Weekly digest").
#
# Read-only: Prometheus instant queries only, one ntfy message (at most ~3.8 KB, under the
# 4096-byte ntfy limit). Any failed query or send exits non-zero, so KubeJobFailed fires.
#
# Env:
#   NTFY_URL  alerts topic URL from Vault (alertmanager/notifications ntfy_url); its query
#             string (Alertmanager template parameters) is dropped, never printed.
#   PROM_URL  Prometheus base URL.
set -euo pipefail

PROM="${PROM_URL:-http://kube-prometheus-stack-prometheus.kube-prom-stack.svc:9090}"
NTFY="${NTFY_URL%%\?*}"
UN='on (instance) group_left (nodename) node_uname_info{job="node-exporter"}'

# q <promql> [jq expression for the label]: one "label<TAB>value" line per series.
q() {
  local label="${2:-.metric.nodename}"
  curl -fsS --max-time 30 -G "$PROM/api/v1/query" --data-urlencode "query=$1" \
    | jq -r "(.data.result // [])[] | \"\\(${label})\\t\\(.value[1])\""
}
# Single value (first series), or the default when the query returns nothing.
v() { local out; out=$(q "$1" '""' | head -1 | cut -f2); echo "${out:-${2:-0}}"; }
# "label<TAB>value" lines -> "a 1, b 2". The format gets: separator, label, value.
join() { awk -F'\t' -v f="$1" 'NF { printf f, (n++ ? ", " : ""), $1, $2 } END { if (!n) printf "none" }'; }

issues=0
week=$(date +%G-W%V)

# Nodes
ready=$(v 'sum(kube_node_status_condition{condition="Ready",status="true"})')
total=$(v 'count(kube_node_info)')
[ "$ready" = "$total" ] || issues=$((issues + 1))
reboots=$(q "changes(node_boot_time_seconds{job=\"node-exporter\"}[7d]) * $UN > 0" | sort | join '%s%s (%.0f)')

# Temperature: Pi SoC on aarch64, CPU (coretemp) on x86_64; the x86 chipset zone is left out.
temps=$(q 'max by (nodename, machine) (
    (max_over_time(node_hwmon_temp_celsius{job="node-exporter",chip="thermal_thermal_zone0"}[7d])
      * on (instance) group_left (nodename, machine) node_uname_info{job="node-exporter",machine="aarch64"})
    or
    (max_over_time(node_hwmon_temp_celsius{job="node-exporter",chip=~"platform_coretemp_.*"}[7d])
      * on (instance) group_left (nodename, machine) node_uname_info{job="node-exporter",machine="x86_64"}))' \
  '"\(.metric.nodename) \(.metric.machine)"' | sort)
# Flag 10 °C below the warning alert (Pi 60, x86 75).
temp_line=$(echo "$temps" | awk -F'\t' 'NF == 2 { split($1, a, " "); hot = (a[2] == "x86_64" ? 75 : 60);
  printf "%s%s %.0f°%s", (n++ ? ", " : ""), a[1], $2, ($2 >= hot ? " ⚠" : "") } END { if (!n) printf "no data" }')
softtemp=$(q "max_over_time(rpi_throttled_flag{flag=\"soft_temp_limit_now\"}[7d]) * $UN > 0" | join '%s%s')

# Disks
root=$(q "sort_desc(max by (nodename) ((1 - node_filesystem_avail_bytes{job=\"node-exporter\",mountpoint=\"/\"} / node_filesystem_size_bytes{job=\"node-exporter\",mountpoint=\"/\"}) * 100 * $UN))" | join '%s%s %.0f%%')
storage=$(q "topk(3, max by (nodename) ((1 - node_filesystem_avail_bytes{job=\"node-exporter\",mountpoint=\"/storage\"} / node_filesystem_size_bytes{job=\"node-exporter\",mountpoint=\"/storage\"}) * 100 * $UN))" | sort -t$'\t' -k2 -rn | join '%s%s %.0f%%')

# Alerts
NOISE='alertname!~"Watchdog|InfoInhibitor"'
fired_all=$(q "sort_desc(count by (alertname) (max_over_time(ALERTS{alertstate=\"firing\",$NOISE}[7d])))" '.metric.alertname')
fired_n=$(printf '%s' "$fired_all" | grep -c . || true)
fired=$(printf '%s' "$fired_all" | head -12 | join '%s%s (%.0f)')
[ "$fired_n" -le 12 ] || fired="$fired, +$((fired_n - 12)) more"
firing=$(q "count by (alertname, severity) (ALERTS{alertstate=\"firing\",$NOISE})" '"\(.metric.alertname) [\(.metric.severity)]"' | join '%s%s')
[ "$firing" = "none" ] || issues=$((issues + 1))

# Velero
vel_age=$(v '(time() - max(velero_backup_last_successful_timestamp)) / 3600' -1)
vel_ok=$(v 'sum(increase(velero_backup_success_total[7d]))')
vel_fail=$(v '(sum(increase(velero_backup_failure_total[7d])) or vector(0)) + (sum(increase(velero_backup_partial_failure_total[7d])) or vector(0))')
awk -v a="$vel_age" -v f="$vel_fail" 'BEGIN { exit !(a < 0 || a > 30 || f >= 0.5) }' && issues=$((issues + 1))
velero=$(awk -v a="$vel_age" -v o="$vel_ok" -v f="$vel_fail" 'BEGIN {
  printf "%s; 7d: %.0f ok, %.0f failed/partial", (a < 0 ? "no successful backup" : sprintf("last OK %.0fh ago", a)), o, f }')

# Certificates
cert=$(q 'bottomk(1, (min by (name) (certmanager_certificate_expiration_timestamp_seconds) - time()) / 86400)' '.metric.name' | join '%s%s in %.0fd')
cert_bad=$(v 'count(certmanager_certificate_ready_status{condition="False"} == 1)')
[ "$cert_bad" = "0" ] || issues=$((issues + 1))

# Longhorn (robustness: 1 healthy, 2 degraded, 3 faulted; 0 = detached)
lh_bad=$(q 'longhorn_volume_robustness >= 2' '"\(.metric.volume)\(if .value[1] == "3" then " FAULTED" else " degraded" end)"' | cut -f1 | paste -sd, - | sed 's/,/, /g')
[ -z "$lh_bad" ] || issues=$((issues + 1))

# Flux
flux_bad=$(q 'gotk_resource_info{ready!="True"}' '"\(.metric.customresource_kind)/\(.metric.name)"' | cut -f1 | sort -u | paste -sd, - | sed 's/,/, /g')
[ -z "$flux_bad" ] || issues=$((issues + 1))

# RustFS buckets on node1: size now and growth over 7 days (empty until 7 days of data).
rustfs=$(q 'sort_desc(rustfs_bucket_size_bytes)' '.metric.bucket' > /tmp/size
  q 'rustfs_bucket_size_bytes - rustfs_bucket_size_bytes offset 7d' '.metric.bucket' > /tmp/growth
  awk -F'\t' 'NR == FNR { g[$1] = $2; next } $2 >= 1e8 {
      printf "%s%s %.1fG", (n++ ? ", " : ""), $1, $2 / 1e9
      if ($1 in g) printf " (%+.1fG)", g[$1] / 1e9 } END { if (!n) printf "no data" }' /tmp/growth /tmp/size)
orphans=$(v 'sum(rustfs_bucket_orphan_bytes) / 1e9')

# Raspberry Pi under-voltage: minutes with at least one kernel dip message.
uv=$(q "sum by (nodename) (count_over_time((rpi_undervoltage_events_recent > 0)[7d:1m]) * $UN)" | sort | join '%s%s (%.0f min)')

# Pods that restarted most
restarts=$(q 'topk(3, sum by (namespace, pod) (increase(kube_pod_container_status_restarts_total[7d]))) >= 1' \
  '"\(.metric.namespace)/\(.metric.pod)"' | sort -t$'\t' -k2 -rn | join '%s%s (%.0f)')

msg=$(cat <<EOF
Nodes: ${ready}/${total} Ready. Reboots: ${reboots}
Temp max 7d: ${temp_line}
Pi soft temp limit: ${softtemp}
Disk /: ${root}
Disk /storage top: ${storage}
Alerts this week: ${fired}
Firing now: ${firing}
Velero: ${velero}
Certs: next ${cert}; not ready: ${cert_bad}
Longhorn: ${lh_bad:-all healthy}
Flux: ${flux_bad:-all ready}
RustFS: ${rustfs}; orphaned $(printf '%.1f' "$orphans")G
Under-voltage: ${uv}
Restarts top: ${restarts}
EOF
)
msg=$(printf '%s\n' "$msg" | head -c 3800 | iconv -c -f UTF-8 -t UTF-8)

if [ "$issues" -eq 0 ]; then prio=3; tags=bar_chart,white_check_mark; title="Weekly digest $week: all good"
else prio=4; tags=bar_chart,warning; title="Weekly digest $week: $issues to look at"; fi

printf '%s\n\n%s\n' "$title" "$msg"
curl -fsS --max-time 30 -o /dev/null -H "Title: $title" -H "Tags: $tags" -H "Priority: $prio" \
  --data-binary "$msg" "$NTFY"
echo "sent ($(printf '%s' "$msg" | wc -c) bytes)"
