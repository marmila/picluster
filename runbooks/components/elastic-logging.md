# Elastic and Logging Runbooks

## ELASTIC-001 Elasticsearch Red, Down, or Kibana Not Ready

<a id="runbook-elastic-001"></a>
Runbook ID: `ELASTIC-001`
Owner: Observability Platform
Severity: `SEV-1` or `SEV-2`

Objective: Get Elasticsearch (`efk`, one node: pod `efk-es-default-0` in `elastic`) back to green or yellow,
and Kibana (`efk-kb`) Ready.

Alerts: `ElasticsearchNotHealthy` (red, unreachable, or no exporter data for 15 minutes),
`KubeDeploymentReplicasMismatch` for `efk-kb` (Kibana). Also seen through `config-elastic` Terraform errors
(`dial tcp ...:9200` / `:5601`, `GITOPS-007`) and `elastic-stack-app` not ready (its health check waits for
Elasticsearch green or yellow and Kibana green).

Preconditions:

- `kubectl` on node2. The Elasticsearch API is reached through the pod, no port-forward needed.

Procedure:

1. Pods, health and shards. One paste:

```bash
kubectl -n elastic get elasticsearch,kibana
kubectl -n elastic get pods -o wide | grep -E "NAME|efk"
PW=$(kubectl -n elastic get secret efk-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
ES="kubectl -n elastic exec efk-es-default-0 -c elasticsearch -- curl -s -u elastic:$PW http://localhost:9200"
echo "=== health ==="
$ES/_cluster/health?pretty | grep -E '"status"|active_primary|initializing|unassigned_shards|unassigned_primary'
echo "=== disk ==="
$ES/_cat/allocation?v
echo "=== shards not started ==="
$ES/_cat/shards?h=index,shard,prirep,state,unassigned.reason | grep -v STARTED | head -20
echo "=== why the first unassigned shard is unassigned ==="
$ES/_cluster/allocation/explain?pretty | grep -E '"index"|"primary"|"can_allocate"|"allocate_explanation"|"explanation"' | head -10
```

   If `efk-es-default-0` is not Running, the `exec` commands fail: use the first two lines and the table.

2. Match the case:

| Step 1 shows | Meaning | Do |
| --- | --- | --- |
| `efk-es-default-0` in `Init:0/2`, events `FailedAttachVolume` | Its Longhorn volume cannot attach | `LONGHORN-002`. Elasticsearch starts by itself afterwards |
| Pod `Pending` | No node with room or the volume's node down | `kubectl -n elastic describe pod efk-es-default-0`, events at the end |
| Pod Running, unassigned shards with reason `CLUSTER_RECOVERED`, `can_allocate: yes`, `initializing` > 0 | Normal recovery after a restart; slow while Longhorn rebuilds the volume | Wait, step 3 |
| `can_allocate: no`, explanation mentions `disk watermark` | Disk nearly full | `postmortems/incident-elasticsearch-disk-watermark.md`; check ILM retention |
| Unassigned **replica** shards (`r`) only, status yellow | Single node: replicas cannot be placed | Normal; yellow is fine here |
| Elasticsearch green or yellow, Kibana not Ready | Kibana stuck after an Elasticsearch outage | Step 4 |

3. Wait for recovery (up to 30 minutes), it prints the health every 30 seconds:

```bash
PW=$(kubectl -n elastic get secret efk-es-elastic-user -o jsonpath='{.data.elastic}' | base64 -d)
timeout 1800 bash -c "until kubectl -n elastic exec efk-es-default-0 -c elasticsearch -- curl -s -u elastic:$PW 'http://localhost:9200/_cluster/health?filter_path=status,unassigned_shards' | tee /dev/stderr | grep -qv red; do sleep 30; done"
```

   If `unassigned_shards` does not go down at all for 30 minutes, retry the allocations that failed:

```bash
kubectl -n elastic exec efk-es-default-0 -c elasticsearch -- curl -s -u elastic:$PW -X POST 'http://localhost:9200/_cluster/reroute?retry_failed=true' -o /dev/null -w '%{http_code}\n'
```

4. Restart Kibana:

```bash
kubectl -n elastic rollout restart deploy efk-kb
kubectl -n elastic rollout status deploy efk-kb --timeout=5m
```

5. Re-run what depends on Elasticsearch: `config-elastic` (`GITOPS-007` step 6 with `TF=config-elastic`).

Verify:

- `kubectl -n elastic get elasticsearch,kibana`: Elasticsearch `green` or `yellow`, Kibana `green`.
- `kubectl -n flux-system get kustomization elastic-stack-app elastic-stack-config`: both Ready.
- `ElasticsearchNotHealthy` resolves; new logs show up in Kibana.

Rollback:

1. Revert recent index template, ILM or config changes in `terraform/elastic` (`GITOPS-010`) if the problem
   started with one.
2. Do not delete the Elasticsearch PVC or its Longhorn volume: it holds all indexed logs.

References:

- `kubernetes/platform/elastic-stack/prometheus-elasticsearch-exporter/base/elasticsearch-alert-rules.yaml`
- `postmortems/incident-2026-11-12-longhorn-instance-manager-outofcpu.md`
- `postmortems/incident-elasticsearch-disk-watermark.md`
