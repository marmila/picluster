# Longhorn Volume Degradation Incident — Postmortem

**Period:** July 10–21, 2026  
**Impact:** 15+ Longhorn volumes in `TooManySnapshots` / degraded state; cluster storage unreliable for ~11 days  
**Resolution:** All volumes healthy except `pvc-a121` (valkey, ecommerce app not in use)

---

## Timeline

| Date | Event |
|------|-------|
| Jul 10 | Velero schedule `full` starts misfiring every ~10–12 minutes |
| Jul 10–16 | ~2681 Velero backups created; each backup creates a VolumeSnapshot → Longhorn engine snapshot; snapshots accumulate on all volumes |
| Jul 16 | Volumes start hitting Longhorn's hard limit of 250 snapshots → `TooManySnapshots` condition |
| Jul 17 | Investigation begins; `deletionPolicy: Retain` identified and fixed |
| Jul 17 | Velero schedule cron fixed; misfiring stops |
| Jul 17–18 | Manual snapshot purge via Longhorn HTTP API for worst-hit volumes (161–162 snapshots each) |
| Jul 18–19 | node5 rebooted due to instability; all node5 replicas go stopped; additional volumes degrade |
| Jul 19–21 | Replica rebuild queue works through backlog; volumes progressively recover |
| Jul 21 | Last 3 degraded volumes fixed via Longhorn API `replicaRemove`; rebuild queue clears |

---

## Root Cause #1 — VolumeSnapshotClass `deletionPolicy: Retain`

**File:** `kubernetes/platform/velero/config/base/longhorn-volume-snapshot-class.yaml`

Velero uses a `VolumeSnapshotClass` to instruct the CSI driver (Longhorn) to create engine-level snapshots during backups. The class had `deletionPolicy: Retain`:

```yaml
deletionPolicy: Retain   # WRONG — snapshots survive forever
```

With `Retain`, when Velero deleted a `VolumeSnapshotContent` object (e.g., after TTL expiry or backup deletion), the CSI driver was **not** told to delete the underlying engine snapshot. Snapshots accumulated on every volume indefinitely.

**Fix (commit `4bc0be9a`):** Changed to `deletionPolicy: Delete` so the Longhorn engine snapshot is deleted when the VolumeSnapshotContent is removed.

---

## Root Cause #2 — Velero Schedule Cron `0 0 31 2 *`

**File:** `kubernetes/platform/velero/config/base/backup-schedule.yaml`

The cron expression `0 0 31 2 *` means "February 31st at midnight" — a date that never exists. The Velero schedule controller interpreted this as a perpetually overdue job and triggered it every ~10–12 minutes for 7 days (July 10–16), creating ~2681 backups instead of the intended single weekly backup.

Each backup created one VolumeSnapshot per PVC → one engine snapshot per volume. With `deletionPolicy: Retain`, none were cleaned up.

**Fix (commit `ae835f78`):** Changed schedule to `"0 2 * * *"` (daily at 2am).

---

## Snapshot Accumulation — How It Works

```
Velero backup runs
  └─► creates VolumeSnapshot CRD
        └─► Longhorn CSI driver creates engine snapshot (counted toward 250 limit)
              └─► with deletionPolicy: Retain, deleting the VolumeSnapshot does NOT delete the engine snapshot
```

Longhorn enforces a hard limit of **250 snapshots per volume** (`snapshot-max-count` setting, cannot be raised above 250). Once a volume hits 250, it enters `TooManySnapshots` condition and goes degraded.

---

## Manual Snapshot Cleanup

With snapshots already accumulated, fixing the root causes alone was not enough. The existing engine snapshots had to be removed manually via the **Longhorn HTTP API** (not via CRD deletion — deleting `snapshots.longhorn.io` CRDs does nothing; Longhorn recreates them from engine state).

**API endpoints used:**

```
POST /v1/volumes/{name}?action=snapshotDelete   # marks snapshot removed=true
POST /v1/volumes/{name}?action=snapshotPurge    # actually removes from engine (sync, can take minutes)
```

Key lessons from the cleanup process:

- `snapshotDelete` returns HTTP 500 if the engine cannot reach a stopped replica (i/o timeout). Workaround: delete the stopped replica CRD so the engine drops it from its active set, then retry.
- `snapshotPurge` is synchronous and long-running for volumes with 150+ snapshots. Requires `timeout=None` in Python `requests` calls.
- CRD count (`kubectl get snapshots.longhorn.io`) dropped from **671 → 79** as purges completed over ~3 days. The 79 remaining are legitimate (3 daily Velero backups × ~17 volumes + system snapshots).

---

## node5 Reboot and Replica Rebuild Cascade

During troubleshooting, node5 became unstable (high load, SSH hanging). After reboot, the Longhorn instance manager on node5 restarted, which caused **all node5 replicas to transition to `stopped` state** simultaneously. This temporarily degraded additional volumes that had previously recovered.

After reboot, node5's disk and instance manager were healthy:
- Disk: Ready, Schedulable, ~400GB available
- Instance manager pod: running, processing rebuild queue

Longhorn rebuilt replicas sequentially on each node (`concurrentReplicaRebuildPerNodeLimit`). With ~17 volumes needing node5 replicas rebuilt, this took 12–24 hours to fully drain the queue.

---

## Final Fix — `replicaRemove` via Longhorn API

Three volumes remained degraded after the queue drained because their stopped replicas were still registered in the **engine's active replica set** (not just as CRDs). This meant the engine was continuously attempting to sync to an unreachable replica, holding the volume in degraded state.

Simply deleting the replica CRDs didn't help — Longhorn recreates them from engine state. Reducing `numberOfReplicas` spec didn't help either, because the engine couldn't evict the stopped replica without communicating with it (i/o timeout).

**Solution:** Call `replicaRemove` directly on the volume via the Longhorn HTTP API. This tells the engine to drop the replica from its active set without needing to communicate with the replica process.

```python
import requests
BASE = "http://<longhorn-service-clusterip>/v1"

resp = requests.post(
    f"{BASE}/volumes/{volume_name}?action=replicaRemove",
    json={"name": replica_name}
)
# Returns 200 immediately; engine drops replica, volume reschedules rebuild
```

After `replicaRemove`, Longhorn scheduled fresh replica rebuilds on available nodes, completing the recovery.

---

## What Longhorn CRD Deletion Does (and Doesn't Do)

This was a key source of confusion during the incident:

| Action | Effect |
|--------|--------|
| `kubectl delete snapshots.longhorn.io <name>` | Longhorn **recreates** it from engine state. Has no effect on actual engine snapshot. |
| `snapshotDelete` API + `snapshotPurge` API | Actually removes the engine snapshot. CRD count drops after purge. |
| `kubectl delete replicas.longhorn.io <name>` | Longhorn may recreate it if engine still holds the replica in its active set. |
| `replicaRemove` API | Tells the engine to drop the replica. CRD is deleted and **not** recreated. |

---

## Key Settings Changed

| Setting | Before | After | Why |
|---------|--------|-------|-----|
| `VolumeSnapshotClass.deletionPolicy` | `Retain` | `Delete` | Prevent snapshot accumulation on backup deletion |
| Velero schedule cron | `0 0 31 2 *` | `0 2 * * *` | Fix misfiring schedule (Feb 31 doesn't exist) |

---

## Cleanup Still Pending

- [ ] Delete the 2681 Longhorn backup objects from S3 (left by the misfiring schedule)
- [ ] Delete old Velero backups from S3 (hundreds from Jul 10–16 misfiring period)
- [ ] Restore `pvc-a121bbb4` (valkey/ecommerce) from Velero backup when ecommerce app is needed again — all 3 replicas are stopped, volume in `unknown` state

---

## Lessons Learned

1. **Always set `deletionPolicy: Delete`** on VolumeSnapshotClass for Velero + Longhorn. `Retain` is only appropriate if you need to keep engine snapshots independently of Velero backup lifecycle.
2. **Validate cron expressions** before deploying schedules. `0 0 31 2 *` is syntactically valid but semantically broken.
3. **Longhorn CRD operations ≠ engine operations.** For snapshots and replicas, always use the Longhorn HTTP API (`/v1/volumes/{name}?action=...`) for actual cleanup. CRD deletes are often silently undone by the controller.
4. **`snapshotPurge` is synchronous and slow** for large snapshot counts. Use `timeout=None` in HTTP clients.
5. **`replicaRemove` API is the correct way** to evict a stuck stopped replica from a volume engine when it won't self-heal.
