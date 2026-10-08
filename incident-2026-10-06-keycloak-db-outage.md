# Incident: Keycloak Database Outage (node1 disk full)
**Date:** 2026-10-06 → 2026-10-08  
**Duration:** Keycloak down for at least 25 hours (reported 2026-10-06 ~17:00 UTC, back 2026-10-07 ~18:15 UTC). The primary had already restarted 372 times when reported, so the real start is earlier and was not established.  
**Impact:** Keycloak unavailable, so SSO logins for cluster services failed. No volume backups succeeded for about ten days. All existing Longhorn volume backups were deleted on purpose during recovery. No database data was lost.

---

## Summary

The disk on node1 filled up. RustFS, the S3 store for all cluster backups, keeps its data on node1's root filesystem, and the Longhorn backup bucket had grown to 191G of the 220G disk. Once RustFS could no longer accept uploads, Postgres WAL archiving for the Keycloak database failed, the primary kept every WAL segment, and its 5Gi volume filled. CloudNativePG refuses to start Postgres with a full WAL disk, so the database crash-looped and Keycloak went down.

Recovery took more than a day because three independent faults blocked the obvious fix (growing the volume): the CNPG operator did not resize the PVCs, Longhorn could not finish an online expansion on either x86 node because of a stale host PID, and Longhorn could not delete backups from a full disk. It was resolved by restarting the Longhorn instance-manager on node-esp-1, freeing reserved disk blocks on node1, and finally wiping the Longhorn backup bucket.

---

## Timeline

Times are UTC. Entries marked "inferred" were reconstructed from object ages and logs, not observed.

| Time | Event |
|------|-------|
| 2026-09-26/27 | Cluster comes back from the ungraceful shutdown (UPS failure). RustFS, Longhorn instance-managers and the Postgres pods all date from this restart |
| 2026-09-27/28 | Last Longhorn volume backups that completed |
| ~2026-09-28 onward | node1 disk full; nightly Velero backups fail (inferred; the three visible runs of 10-05, 10-06, 10-07 are all `Failed`) |
| before 2026-10-06 | Keycloak primary volume fills with WAL; `postgres-keycloak-2` starts crash-looping |
| 2026-10-06 ~17:00 | Outage reported. Primary at 372 restarts, replica waiting for primary |
| 2026-10-06 ~17:30 | Diagnosed: `Not enough WAL disk space`, archiving failing with `barman-cloud-wal-archive: exit status 4` |
| 2026-10-06 evening | `storage.size` raised 5Gi → 10Gi in git (commit `33a5c36e`) |
| 2026-10-07 05:10 | Cluster spec shows 10Gi but the CNPG operator does not resize the PVCs |
| 2026-10-07 05:34 | PVCs patched to 10Gi by hand; Longhorn expansion starts and never completes |
| 2026-10-07 05:58 | Cause found: `nsenter: cannot open /host/proc/871/ns/mnt` during the iSCSI rescan |
| 2026-10-07 ~07:00 | Postgres pods deleted to force a new engine; no effect, volumes never detached |
| 2026-10-07 17:00 | Offline expansion attempted with the operator scaled to 0; volumes stay attached |
| 2026-10-07 17:38 | Longhorn instance-manager on node-esp-1 restarted |
| 2026-10-07 17:42 | Primary volume expands to 10Gi; Postgres starts |
| 2026-10-07 17:47 | Real root cause found: RustFS returns `No space left on device` |
| 2026-10-07 ~18:15 | Keycloak pods ready |
| 2026-10-07 ~19:07 | Longhorn backups deleted through Longhorn; nothing is freed because deletes need a write |
| 2026-10-07 ~20:30 | ext4 reserve on node1 lowered 5% → 1%; RustFS can write again |
| 2026-10-07 20:36 | WAL archiving succeeds again |
| 2026-10-07 20:40 | Primary found to be OOM-killed repeatedly; Velero schedule paused; unfinished backups cancelled |
| 2026-10-07 ~21:00 | Longhorn backup bucket wiped directly on node1 |
| 2026-10-07 21:07 | Last OOM kill of the primary (11 in total); none since the WAL queue drained |
| 2026-10-08 morning | node1 at 18% used, 180G free. WAL queue empty, archiving healthy (379 archived). Primary volume at 7% |
| 2026-10-08 morning | Velero schedule found un-paused: Flux had reverted the manual pause. Dangling Longhorn Backup and VolumeSnapshot objects cleaned up, including any created by the 02:00 run |

---

## Root Causes

### Primary: node1 disk filled by Longhorn volume backups

RustFS stores everything under `/storage/rustfs`, which is a directory on node1's only disk (`/dev/sda2`, 220G), shared with the OS, Vault and DNS. The `k3s-longhorn` bucket held 191G; all other buckets together were under 5G.

Velero runs a full backup daily at 02:00 with a 72h TTL and backs up volumes through Longhorn CSI snapshots (`velero-longhorn-backup-vsc`, type `bak`). That includes the 50G Prometheus and 50G Elasticsearch volumes. The bucket contained about 60 backups, several per volume, including three of Elasticsearch (~29G each) and two of Prometheus (~52G each).

**Not established:** why backups older than the 72h TTL were still in the bucket. Longhorn itself only listed 14 of them until the bucket became readable again. Either Velero's expiry was not removing the Longhorn backups, or the removals started failing once the disk was full.

**Fix applied:** bucket emptied by hand on node1. Velero schedule paused. No lasting fix yet.

### Primary: nothing alerted on the full disk

node1 sat at 100% for about ten days. Every nightly backup failed in that time. Neither condition raised an alert that was acted on, so the first visible symptom was Keycloak going down.

**No fix yet.**

### Contributing: WAL archiving failure fills the database volume

With archiving configured, Postgres keeps WAL until it is archived. A broken archive target therefore turns into a full data volume, and CNPG then refuses to start the instance. A 5Gi volume left little margin.

The Keycloak cluster also has no `ScheduledBackup`, so the archived WAL has no base backup to go with it and cannot be used for a restore on its own.

**Fix applied:** volume grown to 10Gi (commit `33a5c36e`). This buys time but does not remove the failure mode.

### Contributing: Longhorn instance-manager held a stale host PID

On node-esp-1 and node-esp-2 the instance-manager pods had been running since 26 September. For host operations they enter the host namespaces through a host process ID captured earlier (871 and 869). `iscsid` and `k3s-agent` were later restarted on those nodes, so those PIDs no longer existed. Volume expansion grew the data but failed the iSCSI rescan every 5 seconds without recording an error on the Longhorn objects; it was only visible in the instance-manager pod log.

Longhorn's expansion ticket also kept each volume attached to its node, so the volume could not be detached to try an offline expansion.

**Fix applied:** instance-manager restarted on node-esp-1. **Still pending on node-esp-2.**

### Contributing: CNPG operator did not resize the PVCs

After the Cluster spec changed to 10Gi, the operator ended every reconcile at "Insufficient disk space detected ... PostgreSQL cannot proceed until the PVC group is enlarged" and never patched the PVCs. Whether this is intended behaviour in CNPG 1.30.0 or a bug was not investigated. The operator pod was also failing its own probes intermittently on node6.

**Workaround applied:** PVCs patched by hand.

### Contributing: a full S3 disk cannot clean itself up

Longhorn writes a lock file to the bucket before deleting a backup. With zero free bytes that write failed, so deleting backups through Longhorn freed nothing. ext4 reserves 5% of the disk for root, which is why `df` showed 211G used of 220G with 0 available.

**Workaround applied:** reserve lowered to 1% (`tune2fs -m 1 /dev/sda2`).

### Secondary: primary OOM-killed while draining the WAL backlog

After recovery the primary was killed with `OOMKilled` 11 times. It has a 512Mi limit and `wal.maxParallel: 8`, so up to eight archive processes ran alongside Postgres while about 300 queued segments were uploaded. The kills stopped at 21:07 on 10-07, when the queue had drained, which fits this explanation; memory use was not measured directly.

**No fix yet.** It will recur whenever a WAL backlog builds up.

---

## What went well

- No database data was lost. Postgres pods were deleted several times but no PVC was removed, and all Longhorn volumes were healthy before the instance-manager restart.
- Keycloak recovered without intervention once the primary accepted connections.
- Each blocker left a clear error once the right log was found.

## What went poorly

- The first day was spent on the symptom (the full database volume) because the archive error text is only logged while Postgres is running. The real cause was not visible until the volume had been grown.
- An early attempt assumed deleting the pods would detach the volumes. It did not, and half a day passed before that was noticed.
- A command block chained with `;` kept running after a missing tool (`flux`) failed, and scaled the operator down earlier than intended.
- Recovery ended with all Longhorn volume backups deleted and backups switched off.

---

## Actions to prevent recurrence

| # | Action | Addresses | Where | Priority |
|---|--------|-----------|-------|----------|
| 1 | Alert on node1 filesystem usage (warn ~75%, critical ~90%) | Undetected full disk | Prometheus rules; needs node1 to be scraped | High |
| 2 | Alert on failed Velero backups and on no successful backup in 48h | Ten days of silent backup failure | Prometheus rules (Velero metrics) | High |
| 3 | Alert on CNPG WAL archiving failing and on WAL volume usage | Archive failure turning into an outage | Prometheus rules (CNPG metrics) | High |
| 4 | Exclude the Prometheus and Elasticsearch volumes from Velero volume backups | 100G of re-creatable data dominating the backup store | Velero schedule or PVC labels in `kubernetes/` | High, before resuming Velero |
| 5 | Give RustFS its own disk or partition, sized for the backup set | A backup bucket able to fill the OS disk of the host running Vault and DNS | node1 hardware + `ansible/` | Medium |
| 6 | Find out why expired backups were not pruned from the Longhorn bucket | Unbounded bucket growth | Velero + Longhorn investigation | Medium |
| 7 | Lower `wal.maxParallel` from 8 to 2 for `postgres-keycloak` | OOM kills during backlog drain | `kubernetes/platform/keycloak/database/base/postgres-cluster.yaml` | Medium |
| 8 | Add a `ScheduledBackup` for `postgres-keycloak` | WAL archive unusable without a base backup; no WAL pruning | Same directory | Medium |
| 9 | Restart Longhorn instance-managers after `iscsid` or `k3s-agent` restarts on a node, and note it in the runbook | Stale host PID breaking expansion | Runbook / `docs/` | Medium |
| 10 | Check the e-commerce Postgres cluster for the same archive and backup setup | Same failure mode on another database | `kubernetes/apps/e-commerce/config/databases/` | Low |
| 11 | Investigate the CNPG operator's failing probes on node6 and the missing PVC resize | Operator not acting on spec changes | CNPG operator | Low |

Items 1 to 3 are the ones that would have turned this into a non-event: any of them fires days before Keycloak goes down.

---

## Outstanding recovery work

These are leftovers from the recovery itself, separate from prevention.

1. **Dangling backup objects: done 2026-10-08.** No Longhorn Backup objects or VolumeSnapshots remain. One VolumeSnapshotContent is left over and should be checked.

2. **Replica `postgres-keycloak-1` is still `0/1`** twelve hours after the primary recovered. Postgres is not running in the pod and the cause has not been found yet. The cluster reports "Instance Status Extraction Error: HTTP communication issue". The primary is healthy and its WAL queue is empty, so Keycloak runs without redundancy for now.

3. **Two Longhorn volumes are still `degraded`** (11 healthy). Which two, and why they have not rebuilt, is not yet known.

4. **Restart the instance-manager on node-esp-2** once item 3 is clean. The replica's PVC is still 5Gi with a resize stuck in a retry loop. This briefly interrupts Elasticsearch, Kafka broker 0, Alertmanager and `postgres-keycloak-1`.

   ```bash
   kubectl -n longhorn-system get pods -l longhorn.io/component=instance-manager -o wide | grep node-esp-2
   kubectl -n longhorn-system delete pod <instance-manager-pod-on-node-esp-2>
   ```

5. **Velero is running again, unchanged.** The manual pause was reverted by Flux, because the schedule is a plain manifest in `kubernetes/platform/velero/config/base/backup-schedule.yaml`. It backs up every namespace, including the two 50G volumes, every night at 02:00. With 180G free there is room for roughly two full generations, so action 4 has to land in git within a day or two. A pause also has to be made in git (`spec.paused: true`) to stick.

6. **Restore the ext4 reserve on node1:** `sudo tune2fs -m 5 /dev/sda2`.

7. **Explain node1's disk usage outside the buckets.** The visible buckets total about 6G, but the disk shows 38G used; before the incident everything outside RustFS was about 14G. Check `/storage/rustfs/.rustfs.sys` and the largest directories on `/`.

## Changes made during the incident

**Git:** commit `33a5c36e`, `storage.size` 5Gi → 10Gi in `kubernetes/platform/keycloak/database/base/postgres-cluster.yaml`.

**Cluster, by hand**

- PVCs `postgres-keycloak-1` and `postgres-keycloak-2` patched to request 10Gi; only the second has expanded.
- Longhorn instance-manager pod on node-esp-1 deleted and recreated.
- CNPG operator scaled to 0 and its HelmRelease suspended for a few minutes, then both restored.
- Postgres pods deleted several times (pods only).
- All Longhorn Backup objects for Prometheus and Elasticsearch, all `Error` and unfinished backups, and 17 not-ready Velero VolumeSnapshots deleted.
- Velero schedule `full` paused; Flux reverted this within hours.
- 2026-10-08: all remaining Longhorn Backup objects and Velero VolumeSnapshots deleted.

**node1**

- ext4 reserved blocks lowered from 5% to 1%.
- Contents of `/storage/rustfs/k3s-longhorn` removed with RustFS stopped.

## Quick health check

On node2:

```bash
D=databases; N=longhorn-system; \
kubectl -n $D get pods -l cnpg.io/cluster=postgres-keycloak; kubectl -n $D get cluster postgres-keycloak; kubectl -n keycloak get pods --no-headers; \
kubectl -n $D get pod postgres-keycloak-2 -o jsonpath='{range .status.containerStatuses[*]}restarts={.restartCount} lastReason={.lastState.terminated.reason} finished={.lastState.terminated.finishedAt}{"\n"}{end}'; \
kubectl -n $D exec postgres-keycloak-2 -c postgres -- psql -U postgres -Atc "select 'archived='||archived_count||' failed='||failed_count||' last_ok='||coalesce(last_archived_time::text,'never')||' last_fail='||coalesce(last_failed_time::text,'never') from pg_stat_archiver"; \
kubectl -n $D exec postgres-keycloak-2 -c postgres -- sh -c 'ls /var/lib/postgresql/data/pgdata/pg_wal/archive_status | grep -c ready; df -h /var/lib/postgresql/data | tail -1'; \
kubectl -n $N get volumes.longhorn.io --no-headers -o custom-columns='R:.status.robustness' | sort | uniq -c; \
kubectl -n velero get schedules.velero.io -o custom-columns='NAME:.metadata.name,PAUSED:.spec.paused'
```

On node1: `df -h /`.
