---
name: Cluster Triage
description: Use when the Pi cluster is unhealthy — pods failing, Flux not reconciling, nodes NotReady, storage, TLS, DNS or external-service problems — to run a read-only, layer-ordered sweep and hand off to the right runbook.
---

# Cluster Triage

A read-only investigation procedure. Do not propose a fix until the failing layer is identified.

With a focus (an alert, or a question from the operator), do not run the whole sweep: go to the
layer of that problem and dig. Each finding leads to the next check, until the cause is backed by
quoted evidence. Before writing a cause, test it: what else would be true if it were right? A cause
that explains one failure but contradicts the rest (one volume failed, the others in the same bucket
uploaded fine) is wrong or incomplete.

Filter and threshold numbers with `jq` (`select(.[1] | tonumber > 60)`), not `awk` or `sed`: those
are not allowed.

## Preconditions

- A valid kubeconfig. Confirm the target first:

  ```bash
  kubectl config current-context
  kubectl version
  ```

- Nothing in this skill mutates the cluster. If a step needs a write, stop and ask.

## Sweep order

Work top-down. Stop at the first layer that is broken; lower layers are often symptoms of it.

### 0. Firing alerts

Start from what Prometheus already knows. List the active, unsilenced alerts from Alertmanager:

```bash
kubectl get --raw "/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-alertmanager:http-web/proxy/api/v2/alerts?active=true&silenced=false&inhibited=false" \
  | jq -r '.[] | select(.labels.alertname != "Watchdog") | [.labels.severity, .labels.alertname, (.labels.namespace // .labels.target // "-"), (.annotations.runbook // "-")] | @tsv' \
  | sort | uniq -c
```

- Every alert added in this repository carries a `runbook` annotation with a runbook ID; the
  [alert → runbook table](references/runbook-map.md#alerts) covers the others.
- If the user pasted an alert from ntfy, start from that alert's runbook.
- `Watchdog` is always firing on purpose (dead-man's switch) and is filtered out above. If it is
  **missing**, alert delivery itself is broken: go to `OBS-002`.
- No alerts does not mean healthy: continue with the sweep below.

If `jq` is not available, drop the `jq` line and read the JSON for `alertname`, `severity` and
`runbook`.

### 1. Context

Record the context, server version, and current time. A stale kubeconfig or the wrong cluster is a
common cause of "everything is down".

### 2. Nodes

```bash
kubectl get nodes -o wide
kubectl get nodes -o custom-columns=NAME:.metadata.name,READY:.status.conditions[-1].type,STATUS:.status.conditions[-1].status
kubectl describe node <node> | sed -n '/Conditions:/,/Addresses:/p'
kubectl top nodes
```

Healthy: all nodes `Ready`, no `MemoryPressure` / `DiskPressure` / `PIDPressure`, CPU and memory not
saturated. Pi nodes also suffer from throttling and SD-card wear — check with `make get-pi-status`.

### 3. Control plane and system components

```bash
kubectl -n kube-system get pods
kubectl -n kube-system get events --sort-by=.lastTimestamp | tail -30
```

On K3s, `kube-system` includes CoreDNS, metrics-server, and local-path. For HA control plane issues,
check that the kube-vip VIP is reachable and that all servers agree on the API endpoint.

### 4. Flux sources and Kustomizations

```bash
flux get sources all -A
flux get kustomizations -A
flux get kustomizations -A --status-selector ready=false
```

Healthy: every source `READY=True` with a recent revision, and every Kustomization `READY=True`.
A `False` source makes every downstream Kustomization stale — fix the source before touching apps.

### 5. HelmReleases

```bash
flux get helmreleases -A
flux get helmreleases -A --status-selector ready=false
kubectl -n <ns> describe helmrelease <name>
```

Read the `Ready` condition message and the last Helm failure. Typical causes: chart version not
available in the repository, values schema change, dependency Kustomization not ready, or an existing
resource that cannot be adopted.

### 6. Workloads

```bash
kubectl get pods -A --field-selector status.phase!=Running
kubectl get pods -A | grep -Ev '([0-9]+)/\1|Completed'
kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp | tail -40
```

For a specific pod:

```bash
kubectl -n <ns> describe pod <pod>
kubectl -n <ns> logs <pod> --tail=200
kubectl -n <ns> logs <pod> --previous --tail=200
```

Check restart counts before reading logs — a repeatedly restarted pod often has the useful error in
`--previous`.

### 7. Storage

```bash
kubectl -n longhorn-system get pods
kubectl get pvc -A | grep -v Bound
kubectl get volumes.longhorn.io -n longhorn-system
kubectl get nodes.longhorn.io -n longhorn-system
```

Healthy: Longhorn manager/engine pods running, every PVC `Bound`, every volume `healthy` with the
expected replica count. Degraded replicas often surface as an app pod stuck `ContainerCreating`.

Velero backups (runbook `BACKUP-004`). Use the full resource name: plain `backups` resolves to
another CRD and returns nothing.

```bash
kubectl -n velero get backups.velero.io --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERRORS:.status.errors,WARNINGS:.status.warnings,START:.status.startTimestamp | tail -5
kubectl -n velero get backupstoragelocations.velero.io
```

Error details without the Velero CLI (it needs `kubectl exec`, which the agent cannot use). Read them
from the places Velero and Longhorn record them:

```bash
# Velero's own log lines for the backup
kubectl -n velero logs deploy/velero -c velero --since=24h | grep <backup> | grep -iE "level=(error|warning)" | tail -20
# Volume snapshots that never became ready, and why
kubectl get volumesnapshots -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyToUse,ERR:.status.error.message | grep -v true
# Longhorn uploads to RustFS (k3s-longhorn) that failed: the S3 error is in .status.error
kubectl -n longhorn-system get backups.longhorn.io -o custom-columns=NAME:.metadata.name,VOL:.status.volumeName,STATE:.status.state,CREATED:.metadata.creationTimestamp,ERR:.status.error | grep -vi completed
kubectl -n longhorn-system get backupvolumes.longhorn.io
```

`backupvolumes.longhorn.io` shows `LASTBACKUPAT` per volume: a volume that stopped advancing is the
one that fails. Exception: the Prometheus volume (`pvc-e1c0c8e4…`, `kube-prom-stack`) is excluded from
backups on purpose since 2026-11-15 (`velero.io/exclude-from-backup=true`), so its last backup stays at
2026-11-15. To find which pod reported an upload error, grep the instance-manager logs
(`kubectl -n longhorn-system logs <instance-manager pod> --since=24h | grep -i <error>`).

- A single `PartiallyFailed` with one `connection reset by peer` error is usually transient: the next
  nightly run decides.
- An S3 error (`NoSuchBucket`, HTTP 500, timeouts) from Longhorn while other volumes upload fine:
  RustFS on node1 struggling, not a missing bucket. Check node1's disk load in step 10 at the time of
  the error; `BACKUP-004` step 3a. RustFS logs are on node1 (`/var/log/rustfs/`): Not checked, give
  the person the grep from `MINIO-001` step 2.
- For a person, the full details: `kubectl -n velero exec deploy/velero -c velero -- /velero backup describe <name> --details`.

### 8. Gateway, TLS and DNS

```bash
kubectl -n envoy-gateway-system get pods,svc
kubectl get gateway,httproute -A
kubectl -n cert-manager get pods
kubectl get certificates -A
kubectl -n cert-manager get challenges,orders -A
kubectl -n external-dns get pods
kubectl get dnsendpoints -A 2>/dev/null || true
```

Healthy: certificates `READY=True` and not near expiry, no pending `Challenge`, gateway address
assigned, DNS records matching the gateway. DNS-01 issuance depends on IONOS credentials and on
DNS propagation — a failed challenge is usually credential or propagation, not the app.

### 9. Observability

```bash
kubectl -n kube-prom-stack get pods
kubectl -n loki get pods
kubectl -n tempo get pods
kubectl -n elastic get pods
kubectl -n grafana get pods
```

If Prometheus targets are missing, use runbook `OBS-001`; for Loki ingestion use `OBS-004`.

Log history (Loki, read-only through the API server proxy). List the labels first, then query; the
query must be URL-encoded (`jq -rn --arg q '<LogQL>' '$q|@uri'` prints it). `since` takes 1h, 6h, 24h;
for a past window use `start=` and `end=` in RFC 3339 instead.

```bash
L="/api/v1/namespaces/loki/services/loki-gateway:80/proxy/loki/api/v1"
kubectl get --raw "${L}/labels" | jq -r '.data[]'
kubectl get --raw "${L}/label/namespace/values" | jq -r '.data[]'
# {namespace="velero"} |~ "(?i)error", last 6 hours
kubectl get --raw "${L}/query_range?query=%7Bnamespace%3D%22velero%22%7D%20%7C~%20%22%28%3Fi%29error%22&since=6h&limit=50" | jq -r '.data.result[].values[] | .[1]' | tail -50
```

Use it for pods that restarted or were replaced (their logs are gone from `kubectl logs`) and for
what happened before an alert started. If the label is not `namespace`, use the one `/labels` lists.

### 10. External services

Vault, RustFS and the OpenWrt gateway run **outside** the cluster, so they will not appear as
cluster workloads. The blackbox exporter probes them over TLS every minute. One query shows
reachability and certificate days left for all three:

```bash
P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
kubectl get --raw "${P}probe_success" | jq -r '.data.result[] | "\(.metric.target) reachable=\(.value[1])"'
kubectl get --raw "${P}%28probe_ssl_earliest_cert_expiry-time%28%29%29%2F86400" \
  | jq -r '.data.result[] | "\(.metric.target) days_left=\(.value[1] | tonumber | floor)"'
```

Healthy: `reachable=1` and `days_left` above 14 for `vault`, `object-store` and `gateway`.

- `days_left` below 14, or negative: certificate renewal, runbook `NET-009`.
- `reachable=0` with a valid certificate: the service is down. Vault `VAULT-001`, RustFS `MINIO-001`.

Host disks, including node1 (Vault, RustFS, DNS: not a cluster node, so `kubectl` shows nothing
about it and there is no shell access). node-exporter runs on every host, so Prometheus has the
numbers. Root and `/storage` usage in percent, fullest first:

```bash
P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
kubectl get --raw "${P}sort_desc%28100%20%2A%20%281%20-%20node_filesystem_avail_bytes%7Bjob%3D%22node-exporter%22%2Cfstype%21%3D%22%22%2Cmountpoint%3D~%22%2F%7C%2Fstorage%22%7D%20%2F%20node_filesystem_size_bytes%7Bjob%3D%22node-exporter%22%2Cfstype%21%3D%22%22%2Cmountpoint%3D~%22%2F%7C%2Fstorage%22%7D%29%20%2A%20on%20%28instance%29%20group_left%20%28nodename%29%20node_uname_info%7Bjob%3D%22node-exporter%22%7D%29" \
  | jq -r '.data.result[] | "\(.metric.nodename) \(.metric.mountpoint) \(.value[1] | tonumber | floor)%"'
```

Disk load. node1 has one disk for the OS, Vault and RustFS; when it is busy near 100%, RustFS times
out and S3 clients (Longhorn, Velero, Loki, CNPG) get errors. Busy % now, and over a past window
(`query_range` with `start`, `end` in RFC 3339 UTC and `step=300`):

```bash
P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
kubectl get --raw "${P}100%20%2A%20rate%28node_disk_io_time_seconds_total%7Bjob%3D%22node-exporter%22%2Cdevice%3D~%22sd%5Ba-z%5D%7Cnvme%5B0-9%5Dn%5B0-9%5D%7Cmmcblk%5B0-9%5D%22%7D%5B5m%5D%29%20%2A%20on%20%28instance%29%20group_left%20%28nodename%29%20node_uname_info%7Bjob%3D%22node-exporter%22%2Cnodename%3D%22node1%22%7D"   | jq -r '.data.result[] | "\(.metric.nodename) \(.metric.device) busy=\(.value[1] | tonumber | floor)%"'
```

Drop `,nodename="node1"` (`%2Cnodename%3D%22node1%22`) for all hosts. For the history, replace
`query?query=` with `query_range?start=<from>&end=<to>&step=300&query=` and read
`.data.result[].values[]`.

- On node1, `/storage` is a folder on `/`, so only `/` is listed; it holds the RustFS buckets (Longhorn
  and Velero backups, Loki, Tempo). Above 80% it is urgent: no eviction there, the disk fills until
  Vault and RustFS stop. Runbook `CLUSTER-012` step 7 has the commands for a person to run on node1.
- Cluster nodes: k3s evicts at 95%. On node-esp-1/2 container images are on `/storage` (bind mount
  since 2026-11-15), so their `/` holds only the OS and logs.

A reachable Vault can still be sealed. Check its health endpoint from the runner:

```bash
./ansible-runner/ansible-runner.sh bash -lc 'curl -sS -o /dev/null -w "%{http_code}\n" -k https://vault.homelab.marmilan.com:8200/v1/sys/health'
```

For Vault, `503` means sealed, `200`/`429` mean it is up. A sealed or unreachable Vault shows up
in the cluster as ClusterSecretStore `vault-backend` not ready and `external-secrets-config`
blocking most Kustomizations (`kubectl get clustersecretstore vault-backend`).

## Known failure modes in this cluster

| Symptom | Likely cause | Runbook |
| --- | --- | --- |
| API server unreachable, all nodes NotReady | etcd quorum loss or kube-vip endpoint | `CLUSTER-014` |
| API `ServiceUnavailable`; a node answers TCP 22 but never sends a banner | Control-plane node hung at userspace level (often under-voltage) | `CLUSTER-014` |
| `ping` to `10.0.0.x` fails, everything "looks down" | Gateway rejects IPv4 ICMP by design — not a fault | `CLUSTER-014` |
| Kustomization stuck `False`, no new revision | Git source cannot fetch (auth, branch, network) | `GITOPS-001` |
| One Kustomization `False`, others fine | Manifest/patch error or missing dependency | `GITOPS-002` |
| HelmRelease `False`, chart or values error | Chart version, schema change, stuck release | `GITOPS-003` |
| Pods `ContainerCreating`, PVC pending | Longhorn replica degradation or disk pressure | `CLUSTER-012` |
| App logs `connection refused` to Vault | Vault sealed or auth backend issue | `VAULT-001`, `VAULT-004` |
| Most Kustomizations blocked on `external-secrets-config`, store `InvalidProviderConfig` | Vault certificate expired or Vault sealed | `NET-009`, `VAULT-001` |
| CNPG `ContinuousArchiving=False`, `barman-cloud-wal-archive` exit 4 | RustFS certificate expired or RustFS down | `NET-009`, `MINIO-001` |
| No ntfy messages, healthchecks.io alarm | Alert delivery broken | `OBS-002` |
| Certificate not issued, Challenge pending | IONOS credentials or DNS propagation | `NET-005` |
| Served cert does not match secret | Stale secret / wrong gateway listener | `NET-008` |
| Keycloak login broken, CNPG unhealthy | Database failover or config drift | `KEYCLOAK-006`, `KEYCLOAK-008` |
| S3 backups failing | RustFS outage or credentials | `MINIO-001`, `MINIO-003` |
| Longhorn backup `Error` with `NoSuchBucket`, other volumes fine, bucket exists | node1 disk saturated during the nightly backups, RustFS times out | `BACKUP-004` step 3a, `MINIO-001` |
| Elasticsearch red/yellow | Disk watermark, node loss, shard allocation | `ELASTIC-001` |

## Stop conditions

Hand off to the runbook as soon as the failing layer is clear. Escalate to the user immediately when:

- the API server or etcd is unavailable;
- a node shows `DiskPressure` and workloads are being evicted;
- Vault is sealed and dependent apps are down;
- certificates are expired or a private key may be compromised;
- the evidence suggests data loss or a compromised node.

## Output

Report only what is abnormal, in this shape:

```
Symptom:     <what the user sees>
Evidence:    <key output lines, with timestamps>
Layer:       <nodes | system | flux | helm | workloads | storage | gateway | observability | external>
Cause:       <cause, confidence high/medium/low, and the evidence behind it>
Checked:     <what was ruled out>
Not checked: <what was out of reach, with the command for a person>
Next:        <runbook ID and first step>
```

If everything is healthy, say so explicitly and list the checks that passed. Do not invent problems.
