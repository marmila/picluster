# Incident: Elasticsearch Red Health — Disk High Watermark Exceeded

**Date:** 2026-04-27
**Status:** Resolved
**Affected components:** `flux-system/elastic-stack-app` → cascading to `elastic-stack-config`, `fluentd-app`, `fluent-bit-app`, `fluent-common-app`, `opentelemetry-collector-app`, `prometheus-elasticsearch-exporter-app`

---

## Symptom

`elastic-stack-app` Flux Kustomization was stuck `False`:

```
flux-system   elastic-stack-app   False   health check failed after 69ms:
  failed early due to stalled resources:
  [Elasticsearch/elastic/efk status: 'Failed']
```

Elasticsearch cluster health was `red` with 30 unassigned primary shards:

```json
{
  "status": "red",
  "number_of_nodes": 1,
  "active_primary_shards": 93,
  "unassigned_shards": 30,
  "unassigned_primary_shards": 30,
  "active_shards_percent_as_number": 75.6
}
```

All downstream Kustomizations depending on `elastic-stack-config` were also blocked.

---

## Root Cause

The Elasticsearch data PVC (`elasticsearch-data-efk-es-default-0`) had reached **91.1% capacity** (27.3 GiB of 30 GiB), crossing Elasticsearch's default **high watermark threshold of 90%**.

Elasticsearch disk watermark behaviour:

| Watermark   | Default | Effect |
|-------------|---------|--------|
| Low         | 85%     | Stop allocating new shards to the node |
| High        | 90%     | Attempt to move shards off the node |
| Flood stage | 95%     | Force all indices read-only |

Since this is a **single-node cluster**, when the high watermark was crossed Elasticsearch could not move shards to another node — they became permanently UNASSIGNED, turning cluster health red.

### Why the `*-000003` indices specifically

ILM rolled over the active write indices (creating the `-000003` generation) around the same time the disk crossed 90%. The new primary shards were created but immediately blocked from allocating. Older generations (`-000001`, `-000002`) were already allocated before the threshold was hit and remained healthy.

Unassigned shard reason was `CLUSTER_RECOVERED` — after an Elasticsearch pod restart, the node refused to re-allocate these primaries due to ongoing disk pressure.

---

## Diagnosis Steps

```bash
PASS=$(kubectl get secret -n elastic efk-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)

# Cluster health
kubectl exec -n elastic efk-es-default-0 -- \
  curl -s -u "elastic:$PASS" \
  "http://localhost:9200/_cluster/health?pretty"

# List unassigned shards with reason
kubectl exec -n elastic efk-es-default-0 -- \
  curl -s -u "elastic:$PASS" \
  "http://localhost:9200/_cat/shards?h=index,shard,prirep,state,unassigned.reason&s=state&v" \
  | grep -v STARTED

# Check disk usage per node
kubectl exec -n elastic efk-es-default-0 -- \
  curl -s -u "elastic:$PASS" \
  "http://localhost:9200/_cat/allocation?v&h=node,disk.used,disk.avail,disk.percent,shards"
```

Disk usage confirmed via Grafana Longhorn dashboard: PVC at **91.1%**.

---

## Fix Applied

### Step 1 — Temporarily raise watermarks to unblock shards

Applied transient cluster settings to allow shard allocation while the PVC expansion was pending:

```bash
kubectl exec -n elastic efk-es-default-0 -- \
  curl -s -X PUT -u "elastic:$PASS" \
  "http://localhost:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "transient": {
      "cluster.routing.allocation.disk.watermark.low": "93%",
      "cluster.routing.allocation.disk.watermark.high": "95%",
      "cluster.routing.allocation.disk.watermark.flood_stage": "97%"
    }
  }'
```

### Step 2 — Expand PVC in code

Updated `kubernetes/platform/elastic-stack/app/base/elasticsearch.yaml` from `30Gi` to `50Gi` and pushed to git. Flux applied the change and Longhorn expanded the volume online (no pod restart required).

### Step 3 — Reset watermarks to defaults

After PVC expansion completed:

```bash
kubectl exec -n elastic efk-es-default-0 -- \
  curl -s -X PUT -u "elastic:$PASS" \
  "http://localhost:9200/_cluster/settings" \
  -H "Content-Type: application/json" \
  -d '{
    "transient": {
      "cluster.routing.allocation.disk.watermark.low": null,
      "cluster.routing.allocation.disk.watermark.high": null,
      "cluster.routing.allocation.disk.watermark.flood_stage": null
    }
  }'
```

---

## Monitoring PVC in Real Time

Check PVC capacity (what Kubernetes/Longhorn reports):
```bash
watch kubectl get pvc -n elastic elasticsearch-data-efk-es-default-0
```

Check actual filesystem usage from inside the ES container (the number ES uses for watermark decisions):
```bash
watch -n5 'kubectl exec -n elastic efk-es-default-0 -- df -h /usr/share/elasticsearch/data'
```

---

## Prevention

- **Monitor PVC usage** — set Grafana alerts on the Longhorn dashboard when Elasticsearch PVC exceeds 75% to give enough lead time before hitting the 85% low watermark.
- **Review ILM retention** — the previous commit `reduce retention policies and ilm settings to optimize resource usage` was a step in the right direction but wasn't sufficient to keep disk under control long term.
- **Consider index lifecycle** — ensure ILM delete phases are aggressive enough for a 50 GiB volume on a single-node cluster.
