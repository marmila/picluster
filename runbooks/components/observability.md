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

1. Check Loki and agent pod health.

```bash
kubectl -n monitoring get pods | grep -i loki
kubectl -n monitoring logs deploy/loki --tail=200
```

2. Validate ingest path from Fluent Bit/Promtail to Loki endpoint.
3. Check object storage connectivity and auth for chunks/index.
4. Verify retention/compaction settings and available storage.
5. Reconcile observability stack config if drift is suspected.

Verify:

- New logs appear in Grafana Explore.
- Query latency/error rate returns to normal.
- Retention jobs complete without errors.

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
