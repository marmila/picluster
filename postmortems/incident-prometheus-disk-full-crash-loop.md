# Incident Report: Prometheus Disk Full / CrashLoop on Cluster Restart

**Date:** 2026-06-02  
**Duration:** ~1h  
**Severity:** High — metrics collection and alerting fully unavailable  
**Status:** Resolved

---

## Summary

After a messy restart of the k3s homelab cluster, Prometheus entered a crash loop and never recovered. The root cause was a misconfiguration: `retentionSize` was set to `50GB` while the Prometheus PVC was only `10Gi`. The disk filled up over time and on restart, while replaying WAL segments, Prometheus exhausted the remaining space and panicked. Cleanup of the WAL introduced a second failure (missing WAL segment), requiring a full WAL wipe to recover.

---

## Root Cause

Two compounding issues:

1. **PVC undersized vs retentionSize**: `retentionSize: 50GB` was configured against a `10Gi` PVC. Prometheus will grow TSDB data until it hits `retentionSize`, so it was always going to fill the disk. The cluster has ~430k active time series (high for a homelab), which requires ~25-30GB for 14 days of retention.

2. **WAL replay writes disk during startup**: On restart, Prometheus replays WAL segments and writes mmap chunk files. With the disk already full, this triggered a Go panic during replay:
   ```
   panic: preallocate: no space left on device
   ```

---

## Timeline

### 1. Prometheus CrashLoopBackOff — "no space left on device"

**Symptom**: Pod restarting continuously. Logs show healthy block scans and WAL replay then:
```
WAL segment loaded segment=286 maxSegment=314 duration=3.431748944s
panic: preallocate: no space left on device
```

**Cause**: Disk exhausted (10Gi PVC, ~10G used). WAL replay tried to preallocate mmap chunk files and ran out of space.

**Fix attempt**: Scale down operator + StatefulSet to release the RWO PVC, mount a debug pod, free space by deleting the chunk snapshot and old WAL segments.

```bash
kubectl scale deployment -n kube-prom-stack kube-prometheus-stack-operator --replicas=0
kubectl scale statefulset -n kube-prom-stack prometheus-kube-prometheus-stack --replicas=0
```

> Note: `kubectl exec` against the crash-looping pod fails with `container not found` — the container is dead between restarts. The debug pod approach is required.
> Note: the debug pod `--overrides` must specify the correct PVC name (`prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-0`) and use the `prometheus-db` subpath (`/prometheus/prometheus-db/` is where TSDB data lives inside the PVC).

---

### 2. Prometheus fails to start — "missing WAL segment 286"

**Symptom**: After freeing ~1.5G of disk space, Prometheus starts but immediately shuts down:
```
Fatal error: opening storage failed: repair corrupted WAL: cannot handle error:
open WAL segment: 286: open /prometheus/wal/00000286: no such file or directory
```

**Cause**: WAL segment 286 was deleted during cleanup (it was the oldest non-checkpointed segment). Prometheus tried to repair the WAL from the checkpoint but the referenced segment was gone — unrecoverable without a full WAL wipe.

**Fix**: Wipe WAL, wbl, and chunk snapshot entirely. Historical TSDB blocks (all compacted, all healthy) are unaffected. Only ~2h of recent uncompacted data is lost.

```bash
# Inside debug pod (PVC mounted at /prometheus):
rm -rf /prometheus/prometheus-db/wal
rm -rf /prometheus/prometheus-db/wbl
rm -rf /prometheus/prometheus-db/chunk_snapshot*
```

Then restore:
```bash
kubectl scale statefulset -n kube-prom-stack prometheus-kube-prometheus-stack --replicas=1
kubectl scale deployment -n kube-prom-stack kube-prometheus-stack-operator --replicas=1
```

---

## Permanent Fix

Updated `kubernetes/platform/kube-prometheus-stack/app/base/values.yaml`:

| Field | Before | After |
|---|---|---|
| `storageSpec.storage` | `10Gi` | `50Gi` |
| `retentionSize` | `50GB` | `40GB` |

`retentionSize` must always be ~80% of the PVC size to leave headroom for WAL and temp writes.

Patched the live PVC without downtime (Longhorn supports online expansion):
```bash
kubectl patch pvc prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-0 \
  -n kube-prom-stack \
  --type merge \
  -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'
```

---

## Lessons Learned

- `retentionSize` must always be less than the PVC size — setting it larger than the volume is a silent misconfiguration that guarantees eventual disk exhaustion
- A crash-looping pod cannot be `exec`'d into; scale to 0 via the StatefulSet and use a debug pod to access RWO PVCs
- Deleting individual WAL segments is dangerous — if the checkpoint references a deleted segment, Prometheus cannot repair the WAL. Either delete all WAL or none of it
- 430k active series is high for a homelab — worth investigating high-cardinality exporters to reduce long-term storage pressure
