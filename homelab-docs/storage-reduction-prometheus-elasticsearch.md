# Runbook: Storage Reduction — Prometheus and Elasticsearch PVCs

**Date:** 2026-04-17
**Status:** Applied
**Affected components:** `kube-prom-stack/prometheus`, `elastic/elasticsearch-data`

---

## Symptom

Both 30 GiB PVCs approaching capacity (observed via Grafana volume dashboard):

| Volume | PVC | Used | Capacity | Usage |
|---|---|---|---|---|
| prometheus | `prometheus-kube-prom-stack` | 27.7 GiB | 30.0 GiB | ~92% |
| elasticsearch | `elasticsearch-data` | 27.3 GiB | 30.0 GiB | ~91% |

PVCs were **not extended** — data volume was reduced instead.

---

## Root Cause

### Prometheus

Two compounding issues:

1. **`retentionSize: 50GB` misconfiguration** — the size-based eviction limit was set above the PVC capacity (30 GiB ≈ 32 GB), so it never triggered. Prometheus only enforces `retentionSize` proactively; once the disk is full, it can crash or refuse writes.
2. **14-day retention** — at the cluster's scrape load, 14 days of TSDB data exceeds the available space.

Config file: `kubernetes/platform/kube-prometheus-stack/app/base/values.yaml`

### Elasticsearch

The `fluentd-policy` ILM policy (written to Elasticsearch by fluentd on every restart via `ilm_policy_overwrite: true`) had:
- Hot phase rollover at `max_size: 10gb` — large indices stay in hot (uncompressed) before rolling over
- Delete at `min_age: 7d` — data lives longer than necessary for a homelab cluster

The same values were mirrored in `terraform/elastic/resources/policies/7-days-retention.json` (applied by tofu-controller).

---

## Changes Applied

### 1. Prometheus retention — `kubernetes/platform/kube-prometheus-stack/app/base/values.yaml`

```yaml
# Before
retention: 14d
retentionSize: 50GB

# After
retention: 7d
retentionSize: 25GB
```

- `retentionSize: 25GB` is now below the 30 GiB PVC, so Prometheus will actively evict old TSDB blocks before the disk fills.
- `retention: 7d` halves the stored time-series history.

### 2. Elasticsearch ILM policy (fluentd inline) — `kubernetes/platform/fluent/fluentd/base/fluentd-config.yaml`

```
# Before
rollover: max_size 10gb, max_age 7d
delete:   min_age 7d

# After
rollover: max_size 5gb, max_age 5d
delete:   min_age 5d
```

Indices roll over at 5 GB (or 5 days), move to warm phase at 2 days (shrink + forcemerge for compression), and are deleted at 5 days from creation.

### 3. Elasticsearch ILM policy (Terraform) — `terraform/elastic/resources/policies/7-days-retention.json`

Same values as above, kept in sync with the fluentd inline policy.

---

## How Changes Take Effect

No manual steps required. Everything is automated via Flux + tofu-controller.

### Prometheus

1. Flux syncs the `kube-prometheus-stack` HelmRelease.
2. Prometheus pod restarts with new flags: `--storage.tsdb.retention.time=7d --storage.tsdb.retention.size=25GB`.
3. On the next compaction cycle (minutes to ~1 hour), Prometheus deletes TSDB blocks older than 7 days and enforces the 25 GB size cap.

### Elasticsearch

1. Flux syncs the fluentd ConfigMap → fluentd pods restart → on startup, fluentd pushes the updated `fluentd-policy` to Elasticsearch (overwriting the old one).
2. Elasticsearch ILM checks policies every ~10 minutes. Existing indices older than 5 days are immediately scheduled for deletion on the next check.
3. The `config-elastic` Terraform resource (tofu-controller, `interval: 30m`, `approvePlan: auto`) detects `7-days-retention.json` changed and applies it within 30 minutes of Flux sync.

---

## Verification

### Check Prometheus retention flags are active

```bash
kubectl exec -n kube-prom-stack \
  $(kubectl get pod -n kube-prom-stack -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -c prometheus -- \
  prometheus --version 2>&1 | head -1

# Check active config via API
kubectl exec -n kube-prom-stack \
  $(kubectl get pod -n kube-prom-stack -l app.kubernetes.io/name=prometheus -o jsonpath='{.items[0].metadata.name}') \
  -c prometheus -- \
  wget -qO- http://localhost:9090/prometheus/api/v1/status/flags \
  | jq '{"retention": .data["storage.tsdb.retention.time"], "retentionSize": .data["storage.tsdb.retention.size"]}'
```

Expected:
```json
{
  "retention": "7d",
  "retentionSize": "25GB"
}
```

### Check active Elasticsearch ILM policy

```bash
PASS=$(kubectl get secret -n elastic efk-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

kubectl exec -n elastic deployment/efk-kb -c kibana -- \
  curl -s -u "elastic:$PASS" \
  http://efk-es-http:9200/_ilm/policy/fluentd-policy \
  | jq '.fluentd_policy.policy.phases | {hot_max_size: .hot.actions.rollover.max_size, delete_min_age: .delete.min_age}'
```

Expected:
```json
{
  "hot_max_size": "5gb",
  "delete_min_age": "5d"
}
```

### Monitor volume usage in Grafana

Grafana → Dashboards → Kubernetes → K8s / Storage / Volumes / Cluster

Both volumes should decrease over the following hours as old data is evicted. Steady-state usage should stabilise well below 20 GiB on both.

---

## Expected Steady-State

| Volume | Expected Usage | Headroom |
|---|---|---|
| prometheus | ~10–13 GiB (7d of data) | ~17 GiB |
| elasticsearch | ~8–12 GiB (5d of data, warm-compressed) | ~18 GiB |

---

## Rollback

If reduced retention causes problems (e.g., alerting rules need more history):

```yaml
# prometheus: restore original values
retention: 14d
retentionSize: 28GB   # keep below PVC to avoid the original bug
```

For Elasticsearch, revert the ILM values in both `fluentd-config.yaml` and `7-days-retention.json`. Reducing retention does not delete more data than intended — rolling back only stops future eviction from being more aggressive.

---

## Known Issue: tofu-controller state lock

After applying changes, the `config-elastic` Terraform resource may be stuck with:

```
error acquiring the state lock: Lock Info:
  ID: <uuid>
  Operation: OperationTypePlan
  Who: runner@config-elastic-tf-runner
```

This happens when a previous runner pod was killed mid-plan, leaving an orphaned Kubernetes Lease.

**Fix:**

```bash
# Delete the orphaned lock lease (name always follows this pattern)
kubectl delete lease -n flux-system lock-tfstate-default-config-elastic

# Force immediate reconciliation
kubectl annotate terraform -n flux-system config-elastic \
  reconcile.fluxcd.io/requestedAt="$(date -u +%Y-%m-%dT%H:%M:%SZ)" --overwrite

# Watch it recover
kubectl get terraform -n flux-system config-elastic --watch
```

Expected progression: `Applying` → `Applied successfully` → `Outputs written` → `READY: True`.
