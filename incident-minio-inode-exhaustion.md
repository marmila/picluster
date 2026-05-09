# Incident: MinIO Inode Exhaustion → Full Platform Outage

**Date:** 2026-04-15 / 2026-04-16
**Status:** Resolved
**Severity:** Critical — full observability stack outage (Loki, Tempo, MinIO)
**Duration:** ~10 hours

---

## Affected Components

| Component | Symptom |
|---|---|
| MinIO (minio-0/1/2) | `CrashLoopBackOff` / "drive not found" — could not initialize |
| Loki write pods | `CrashLoopBackOff` — WAL disk full (`no space left on device`) |
| Tempo | `CrashLoopBackOff` — `ListObjects on k3s-tempo: Server not initialized yet` |

---

## Timeline

1. OS package upgrade + node reboot on cluster nodes (`node-esp-1`, `node-esp-2`)
2. MinIO StatefulSet pods restarted → inode exhaustion on all 3 PVCs prevented MinIO from initializing
3. MinIO reported `drive not found` for all peers (root cause: 100% inode usage, not connectivity)
4. Loki write pods could not flush WAL to MinIO → local WAL grew until PVC disk was full
5. Loki write pods entered `CrashLoopBackOff` (`no space left on device` on `/var/loki`)
6. Tempo pods entered `CrashLoopBackOff` (could not reach MinIO S3 backend)

---

## Root Cause

**Inode exhaustion on all 3 MinIO PVCs (10Gi Longhorn volumes, ext4).**

MinIO stores each object as a directory + `xl.meta` + `part.1` files, consuming ~3 inodes per object. Over time, Loki chunk accumulation (no retention/compactor configured) and Tempo trace storage filled all 655,360 available inodes on each 10Gi volume.

The node reboot after OS upgrade triggered a simultaneous restart of all 3 MinIO pods. MinIO distributed mode requires all nodes to initialize together — since none could write (inode exhaustion), the cluster could never form quorum, causing the persistent `drive not found` loop.

**Important:** disk space was only 29% used — standard `df -h` monitoring would not have caught this. Only `df -i` reveals inode exhaustion.

### Why the Loki WAL filled up

With MinIO down, Loki's write pods could not flush their WAL (Write-Ahead Log) to S3. The WAL accumulated on the local PVC (2Gi) until it was 100% full, preventing Loki from starting. The WAL contained TSDB index data only — actual log chunks are in MinIO/S3.

---

## Diagnosis Commands

### Check inode usage (the key diagnostic)
```bash
# Check inodes on MinIO PVCs — look for IUse% at 100%
kubectl exec -n minio minio-0 -- df -i /export
kubectl exec -n minio minio-1 -- df -i /export
kubectl exec -n minio minio-2 -- df -i /export
```

### Confirm MinIO drive paths and startup command
```bash
kubectl get pod -n minio minio-0 -o jsonpath='{.spec.containers[0].args}'
```

### Check Loki WAL disk usage
```bash
# Use debug container since Loki image is distroless
kubectl debug -it -n loki loki-write-0 --image=busybox --target=loki -- sh
# Inside:
df -h /var/loki
du -sh /var/loki/wal/*
```

### Check MinIO PVC status
```bash
kubectl get pvc -n minio
kubectl exec -n minio minio-0 -- df -h /export
kubectl exec -n minio minio-0 -- ls -la /export
```

---

## Resolution

### Step 1 — Free Loki WAL disk space

Scale down Loki write pods and use a busybox pod to clean WAL:

```bash
kubectl scale statefulset loki-write -n loki --replicas=0

# Repeat for data-loki-write-0 and data-loki-write-1
kubectl run -n loki loki-cleanup --image=busybox --restart=Never \
  --overrides='{
    "spec": {
      "volumes": [{"name":"data","persistentVolumeClaim":{"claimName":"data-loki-write-1"}}],
      "containers": [{
        "name": "cleanup",
        "image": "busybox",
        "command": ["sh"],
        "stdin": true,
        "tty": true,
        "volumeMounts": [{"name":"data","mountPath":"/var/loki"}]
      }]
    }
  }'

kubectl wait --for=condition=Ready pod/loki-cleanup -n loki --timeout=60s
kubectl exec -it -n loki loki-cleanup -- sh
```

Inside the shell:
```sh
# Safe to delete — incomplete checkpoint temp files
rm -rf /var/loki/tsdb-shipper-active/scratch/
find /var/loki -name "*.temp" -delete
rm -rf /var/loki/wal/checkpoint.*.tmp

# WAL segments contain TSDB index only (actual logs are in MinIO/S3)
# Safe to delete — Loki will rebuild index from MinIO on restart
rm /var/loki/wal/0*

df -h /var/loki
exit
```

Clean up and restore:
```bash
kubectl delete pod -n loki loki-cleanup
# Repeat above for data-loki-write-0
kubectl scale statefulset loki-write -n loki --replicas=2
```

### Step 2 — Free MinIO inodes

Scale down MinIO and create cleanup pods for all 3 PVCs:

```bash
kubectl scale statefulset minio -n minio --replicas=0

# Create all 3 cleanup pods
kubectl run -n minio minio-cleanup-0 --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"export-minio-0"}}],"containers":[{"name":"cleanup","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/export"}]}]}}'

kubectl run -n minio minio-cleanup-1 --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"export-minio-1"}}],"containers":[{"name":"cleanup","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/export"}]}]}}'

kubectl run -n minio minio-cleanup-2 --image=busybox --restart=Never \
  --overrides='{"spec":{"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"export-minio-2"}}],"containers":[{"name":"cleanup","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"data","mountPath":"/export"}]}]}}'

kubectl wait --for=condition=Ready pod/minio-cleanup-0 pod/minio-cleanup-1 pod/minio-cleanup-2 -n minio --timeout=60s
```

Run cleanup on all 3 nodes (use `find` not glob — glob fails with hundreds of thousands of files):

```bash
for pod in minio-cleanup-0 minio-cleanup-1 minio-cleanup-2; do
  echo "=== Cleaning $pod ==="
  kubectl exec -n minio $pod -- sh -c "
    echo 'Before:' && df -i /export | tail -1
    find /export/k3s-loki/fake/ -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    find /export/k3s-loki/index/ -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    find /export/k3s-tempo/ -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} +
    echo 'After:' && df -i /export | tail -1
  "
done
```

> **Note:** This deletes all Loki chunk data and Tempo traces stored in MinIO. Historical logs will be lost. This is acceptable for recovery — Loki will resume writing new chunks once MinIO is back.
> **Note:** Each node takes 5–15 minutes to complete deletion. Do not interrupt.

Restore MinIO:
```bash
kubectl delete pod -n minio minio-cleanup-0 minio-cleanup-1 minio-cleanup-2
kubectl scale statefulset minio -n minio --replicas=3
kubectl get pods -n minio -w

# Confirm MinIO initialized (look for "S3-API:" line)
kubectl logs -n minio minio-0 --tail=20 -f
```

Once MinIO is up, Loki and Tempo recover automatically on the next CrashLoop backoff cycle.

---

## Prevention

### 1. Configure Loki retention and compactor (prevents WAL/chunk buildup)

In [kubernetes/platform/loki/app/base/values.yaml](kubernetes/platform/loki/app/base/values.yaml), add under `loki:`:

```yaml
loki:
  limits_config:
    retention_period: 7d

  compactor:
    working_directory: /var/loki/compactor
    delete_request_store: s3
    retention_enabled: true
    compaction_interval: 10m

  ingester:
    chunk_idle_period: 30m
    max_chunk_age: 1h
    chunk_retain_period: 1m
    wal:
      flush_on_shutdown: true
```

### 2. Reduce Elasticsearch ILM retention (prevents ES volume filling)

In [terraform/elastic/resources/policies/7-days-retention.json](terraform/elastic/resources/policies/7-days-retention.json), reduce rollover and delete thresholds:

```json
{
  "policy": {
    "phases": {
      "hot": {
        "min_age": "0ms",
        "actions": { "rollover": { "max_size": "3gb", "max_age": "2d" } }
      },
      "warm": {
        "min_age": "1d",
        "actions": { "shrink": { "number_of_shards": 1 }, "forcemerge": { "max_num_segments": 1 } }
      },
      "delete": {
        "min_age": "5d",
        "actions": { "delete": { "delete_searchable_snapshot": true } }
      }
    }
  }
}
```

### 3. Add inode monitoring alerts

Standard disk space alerts miss inode exhaustion. Add a Prometheus alert for inode usage:

```yaml
# Add to kube-prometheus-stack alerts
- alert: VolumeInodeUsageCritical
  expr: |
    kubelet_volume_stats_inodes_free / kubelet_volume_stats_inodes < 0.10
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Volume inode usage above 90% on {{ $labels.persistentvolumeclaim }}"
    description: "PVC {{ $labels.persistentvolumeclaim }} in namespace {{ $labels.namespace }} has less than 10% inodes free."
```

### 4. Increase MinIO PVC size

The current 10Gi ext4 volume provides only 655,360 inodes. Increasing to 20Gi or 30Gi would approximately double the inode count and provide more headroom.

---

## Lessons Learned

- **`df -h` is not enough** — always check `df -i` for inode usage on storage-heavy workloads like MinIO
- **MinIO inode exhaustion manifests as "drive not found"** — not an obvious disk-full error
- **Loki without compactor/retention will fill MinIO indefinitely** — compactor must be explicitly enabled with `retention_enabled: true`
- **MinIO distributed mode requires all nodes simultaneously** — a single inode-exhausted node blocks the entire cluster from forming quorum
- **Use `find -exec rm -rf {} +` not glob `*`** — shell glob expansion fails silently with hundreds of thousands of files
- **SSH-dependent long-running cleanup operations** — consider using `kubectl exec` with `nohup` or running cleanup jobs as Kubernetes Jobs to survive SSH disconnections
