# Monitoring and Tracing Runbooks

## OBS-001 Prometheus Target Missing Triage

<a id="runbook-obs-001"></a>
Runbook ID: `OBS-001`
Owner: Observability Platform
Severity: `SEV-2`

Objective: Restore monitoring visibility when scrape targets disappear or are down.

Alerts: `ScrapeTargetDown` (any target down for 15 minutes; the e-commerce app is excluded). Labels `job`
and `instance` name the target. node1 targets (`node-exporter` on `node1:9100`, bind on `ns:9119`) are
scraped from outside the cluster: check the service on node1 first.

Procedure:

1. List the down targets and their scrape errors (on node2):

```bash
P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1"
kubectl get --raw "$P/targets?state=active" | python3 -c 'import json,sys; [print(t["labels"].get("job"), t["scrapeUrl"], t["lastError"]) for t in json.load(sys.stdin)["data"]["activeTargets"] if t["health"]!="up"]'
```

2. Match the error:

| Error | Meaning | Go to |
| --- | --- | --- |
| `context deadline exceeded` | No answer: the service hangs, or a network policy drops the traffic | Step 3 |
| `connection refused` | Service down or listening on another port or address | Step 4 |
| `x509`, `tls`, `401`, `403` | TLS or auth mismatch in the ServiceMonitor | Step 5 |
| Target missing from the list | ServiceMonitor or selector problem | Step 5 |

3. Timeouts. Time the endpoint from inside its own pod (`curl -m 30 -w '%{http_code} %{time_total}s'
   http://<pod-ip>:<port>/metrics`). If it answers fast there, the network blocks Prometheus. Look for drops
   with the Cilium agent on the target's node:

```bash
CP=$(kubectl -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=<node> -o jsonpath='{.items[0].metadata.name}')
kubectl -n kube-system exec $CP -c cilium-agent -- timeout 20 cilium-dbg monitor --type drop | grep <port>
kubectl -n <ns> get networkpolicy
```

   `Policy denied` means a NetworkPolicy in the target namespace does not allow Prometheus. Add an allow
   policy in Git (example: `kubernetes/platform/longhorn/app/components/monitor/prometheus-networkpolicy.yaml`,
   added 2026-11-08 after the Longhorn chart's own policy had blocked metrics for weeks).

4. Service down: check the pods (`kubectl -n <ns> get pods`) or, for node1, `systemctl status
   prometheus-node-exporter` / the bind exporter on node1.

5. Selector, port, TLS or auth: compare the monitor with the service.

```bash
kubectl get servicemonitor,podmonitor -A | grep -i <target>
kubectl -n <ns> get svc,pods --show-labels
kubectl -n kube-prom-stack logs deploy/kube-prometheus-stack-operator --tail=100
```

   Fix it in Git and let Flux reconcile.

Verify:

- Target appears as `UP` in Prometheus.
- Alert noise related to missing target clears.

Rollback:

1. Revert monitor changes to last known-good commit.
2. Reconcile monitoring Kustomization.

## OBS-004 Loki Ingestion and Retention Issues

<a id="runbook-obs-004"></a>
Runbook ID: `OBS-004`
Owner: Observability Platform
Severity: `SEV-2`

Objective: Restore Loki ingestion/query health and retention behavior.

Procedure:

1. Check Loki and agent pod health. Loki runs in namespace `loki` (SimpleScalable: `loki-write-0`,
   `loki-backend-0` with the compactor, `loki-read`):

```bash
kubectl -n loki get pods
kubectl -n loki logs loki-write-0 --since=1h | grep -i "level=error" | tail -10
kubectl -n loki logs loki-backend-0 -c loki --since=1h | grep -i "level=error" | tail -10
```

   A `loki-write-0` with many restarts (OOMKilled, CPU throttled) re-uploads the same chunks on every restart:
   fix it first (resources in `kubernetes/platform/loki/app/overlays/prod/values.yaml`), then check step 6.

2. Validate ingest path from Fluent Bit/Promtail to Loki endpoint.
3. Check object storage connectivity and auth for chunks/index.
4. Check retention (7 days, `retention_period: 168h`, compactor on `loki-backend-0`). The index keeps one table
   per day, so there should be about 8 (`loki_index_<day>`), plus `delete_requests`. On node1:

```bash
sudo sh -c 'ls /storage/rustfs/k3s-loki/index | sort | sed -n "1p;\$p"; ls /storage/rustfs/k3s-loki/index | wc -l'
kubectl -n loki logs loki-backend-0 -c loki --since=24h | grep -iE "retention|mark file|delet" | tail -10   # on node2
```

5. Reconcile observability stack config if drift is suspected.
6. Bucket `k3s-loki` much larger than the log volume (about 0.15 GB/day, so 1-2 GB in total): orphaned data
   copies in RustFS. During a `loki-write` crash loop the same chunk keys are uploaded again and again; RustFS
   kept a data folder per upload (`<key>/<uuid>/part.1`). When retention deletes the object, only `xl.meta` and
   the current copy go; the other copies stay. S3 cannot see them (`rc object stat` says "Not found"), so
   neither Loki nor `rc rm` can delete them. Found on 2026-11-15: 70 GB from 8-25 October.

   On node1, measure by day first (read-only). Data older than about 8 days should be close to zero:

```bash
sudo sh -c 'cd /storage/rustfs/k3s-loki/fake && nice -n 19 ionice -c3 find . -type f -printf "%TY-%Tm-%Td %s\n"' \
  | awk -v cut="$(date -d '-8 days' +%F)" '{ if ($1 < cut) old+=$2; else new+=$2 } END { printf "older than 8 days: %.1f GB | last 8 days: %.1f GB\n", old/1e9, new/1e9 }'
```

   If "older" is large, list the object folders that have no `xl.meta` (S3 treats them as non-existent) and
   whose data is older than the cutoff, and check the list:

```bash
CUT=$(date -d '-9 days' +%F)
sudo sh -c "find /storage/rustfs/k3s-loki/fake -mindepth 3 -maxdepth 3 -type d ! -newermt $CUT -printf '%h\n' | sort -u | while read o; do [ -e \"\$o/xl.meta\" ] || echo \"\$o\"; done" > ~/loki-dead-objects.txt
wc -l < ~/loki-dead-objects.txt
grep -vc '^/storage/rustfs/k3s-loki/fake/[0-9a-f]\{16\}/' ~/loki-dead-objects.txt     # must be 0
sudo xargs -d '\n' -a ~/loki-dead-objects.txt du -sc | tail -1                        # size in KB
```

   Remove 5 as a test, check the Loki logs (step 1) for errors, then the rest in tmux. Each folder is checked
   again for `xl.meta` right before removal:

```bash
head -5 ~/loki-dead-objects.txt | sudo sh -c 'while read o; do [ -e "$o/xl.meta" ] || rm -rf -- "$o"; done'
tail -n +6 ~/loki-dead-objects.txt | sudo sh -c 'while read o; do [ -e "$o/xl.meta" ] || rm -rf -- "$o"; done'
df -h /
```

   Never remove anything with an `xl.meta`, nor anything under `index/`: those are live objects. Deleting old
   objects through S3 (`rc rm`) does not help here; it only removes the small live ones.

Verify:

- New logs appear in Grafana Explore.
- Query latency/error rate returns to normal.
- Retention jobs complete without errors.
- `k3s-loki` size in line with the log volume (step 6), node1 root disk below 80%.

Rollback:

1. Revert recent Loki config/image changes.
2. Reconcile observability manifests and revalidate ingestion.

## OBS-002 Alertmanager Notification Failures

<a id="runbook-obs-002"></a>
Runbook ID: `OBS-002`
Owner: Platform Observability
Severity: `SEV-2` (nobody is being alerted)

Objective: Restore alert delivery when ntfy messages stop arriving or healthchecks.io reports the `picluster` check as down.

How delivery works: Alertmanager sends `severity=warning|critical` alerts to an ntfy webhook and the `Watchdog` alert (always firing) to a healthchecks.io ping URL every minute. Both URLs come from Vault `secret/alertmanager/notifications` through the ExternalSecret `alertmanager-notifications-externalsecret` and are mounted at `/etc/alertmanager/secrets/alertmanager-notifications/`. If the pings stop for more than the grace time, healthchecks.io raises its own alarm.

Triggered by: the healthchecks.io alarm (Watchdog pings stopped), or an alert visible in the Alertmanager UI that never reached the phone.

Preconditions:

- `kubectl` access to the cluster (node2).
- healthchecks.io account access to see the check's ping log.

Procedure:

1. Check that Prometheus and Alertmanager are running and that Watchdog is firing:

```bash
kubectl -n kube-prom-stack get pods | grep -E "prometheus-kube|alertmanager"
kubectl get --raw "/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-alertmanager:http-web/proxy/api/v2/alerts?active=true" \
  | grep -o '"alertname":"Watchdog"' | head -1
```

   No Watchdog means the problem is before Alertmanager: Prometheus down, or the `general` PrometheusRule missing (`kubectl get prometheusrule -A | grep general`).

2. Check that the notification secret is synced from Vault:

```bash
kubectl -n kube-prom-stack get externalsecret alertmanager-notifications-externalsecret
kubectl get clustersecretstore vault-backend
```

   `SecretSyncedError` or a store that is not ready points at Vault (see `VAULT-001`, and `NET-009` if its certificate expired).

3. Check that Alertmanager loaded the receivers:

```bash
kubectl -n kube-prom-stack get secret alertmanager-kube-prometheus-stack-generated \
  -o jsonpath='{.data.alertmanager\.yaml\.gz}' | base64 -d | gunzip | grep -E "^\s*- name:"
```

   Expected: `"null"`, `ntfy`, `healthchecks`. Only `"null"` means the `alertmanager-notifications` component is not applied: check the `kube-prometheus-stack-app` Kustomization and HelmRelease `valuesFrom` (`GITOPS-002`, `GITOPS-003`).

4. Look for delivery errors in Alertmanager:

```bash
kubectl -n kube-prom-stack logs alertmanager-kube-prometheus-stack-0 -c alertmanager --since=1h \
  | grep -iE "notify|error|webhook" | tail -20
```

   Typical errors: DNS or network failure to `ntfy.sh` / `hc-ping.com`, HTTP 4xx from a wrong URL, or `no such file` for the `url_file` (secret not mounted).

5. Send a test alert and confirm it reaches ntfy:

```bash
kubectl -n kube-prom-stack exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- \
  amtool alert add OBS002Test severity=warning --annotation=summary="OBS-002 delivery test" \
  --alertmanager.url=http://localhost:9093
```

Verify:

- The test alert arrives on the phone within about a minute (group wait 30s).
- healthchecks.io shows recent pings and the check is "up".
- No new notify errors in the Alertmanager log.

Rollback:

1. If a URL was wrong, correct it in `~/.secrets/alertmanager-notifications.ini` on pimaster and run `make load-external-services-keys`, or write it directly with `vault kv put secret/alertmanager/notifications ...`.
2. Force a resync: `kubectl -n kube-prom-stack annotate externalsecret alertmanager-notifications-externalsecret force-sync=$(date +%s) --overwrite`.

References:

- `kubernetes/platform/kube-prometheus-stack/app/components/alertmanager-notifications/`
- `homelab-docs/alerting.md`, section "Alert notifications (ntfy and healthchecks.io)"
