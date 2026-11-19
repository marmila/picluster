# Incident: node1 root disk at 86%, filled by orphaned Loki data in RustFS and Prometheus backups
**Date:** 2026-11-15  
**Duration:** Disk growing for weeks; `NodeRootDiskFillingUp` on node1 from 2026-11-14 (80.8%). Investigated and fixed
on 2026-11-15, morning to early afternoon.  
**Impact:** None for users. node1 (Vault, RustFS, DNS) was at 86% with a "full within 24 h" prediction. A full disk
would have stopped Vault and RustFS: external-secrets, Velero, CNPG (barman) and Longhorn backups, Loki and Tempo
storage. The 02:00 Velero backup the same night was `PartiallyFailed` (unrelated transient error, see below).

---

## Summary

node1 has a single 220 GB disk. RustFS stores its data in `/storage/rustfs` (`rustfs_server_datadirs`,
`ansible/vars/picluster.yml`), and `/storage` is a plain folder on the root filesystem, not a separate disk. Every
backup and all Loki and Tempo data therefore land on the root disk. Of 186 GB used, about 174 GB was RustFS:

| Bucket | Size | Content |
|---|---|---|
| `k3s-longhorn` | 97 GB | Longhorn volume backups (Velero CSI snapshots, 3 per volume) |
| `k3s-loki` | 72 GB | Loki chunks and index |
| `k3s-velero` | 3.2 GB | Velero manifests |
| `k3s-tempo`, `k3s-barman`, `restic`, `.rustfs.sys` | about 1.7 GB | |

Two causes made up most of it:

1. **70 GB of orphaned Loki data.** Loki writes about 0.15 GB of chunks a day. From 8 to 25 October it wrote about
   4 GB a day: `loki-write` was in a crash loop (OOMKilled and CPU-throttled, fixed on 2026-11-05/06 in `c1ab56fc` and
   `f562d1b3`). Each restart replayed the WAL and uploaded the same chunks again under the same keys. RustFS kept a
   separate data folder for every upload of an object (`<key>/<uuid>/part.1`). When Loki's retention later deleted
   the object, RustFS removed its `xl.meta` and the current data, but not the older copies. Those copies were
   invisible to S3 (`rc object stat` returns "Not found"), so neither Loki nor any S3 client could delete them:
   165,322 `part` files in 136 object folders, up to 10 copies each.
2. **Prometheus in the nightly Velero backup.** The Prometheus volume backup was 53 GB and ran until about 03:27, most
   of the 1 h 30 backup window. Prometheus rewrites its blocks, so each incremental Longhorn backup is close to a full
   one. With 3 restore points kept (72 h TTL), that is a large share of `k3s-longhorn`.

Loki retention itself works: the index has 8 daily tables (7 days plus today), and the compactor marks and deletes
expired chunks. Longhorn backup retention also works (exactly 3 per volume).

---

## Timeline

Times are UTC.

| Time | Event |
|------|-------|
| 2026-10-08 to 10-25 | `loki-write` crash loop: about 4 GB/day of chunk uploads instead of 0.15 GB. Alertmanager still routed everything to `null`, so nobody was notified |
| 2026-10-26 to 11-04 | Loki ingests nothing (write pod never Ready) |
| 2026-11-05/06 | `loki-write` CPU, memory and volume fixed. WAL backlog flushed (3.8 GB) |
| 2026-11-06 | Loki retention deletes the October objects; the extra data copies stay behind (folder dates) |
| 2026-11-14 | `NodeRootDiskFillingUp` on node1 at 80.8%, noted in the backlog |
| 2026-11-15 02:00-03:32 | Velero `full-20261115020033` `PartiallyFailed`: 1 error, `connection reset by peer` to the API server while listing pods for PVC `databases/postgres-keycloak-1`. Transient; the rest of the 3,800 items were backed up |
| 2026-11-15 morning | Triage agent report: Velero failed, node-esp-1 at 88.8%, node1 at 85.3% "out of space within 24 h". It could not inspect node1 (no host access) and could not read Leases (missing RBAC) |
| 2026-11-15 | `df` on node1: 186 of 220 GB, `/storage` not a separate mount. Non-RustFS usage only 12 GB |
| 2026-11-15 | Longhorn backups checked: 3 per volume, Prometheus 53 GB the largest |
| 2026-11-15 | Prometheus PVC labelled `velero.io/exclude-from-backup=true` by hand; same label in the `volumeClaimTemplate` and Lease read for the triage agent pushed (`a939279d`) |
| 2026-11-15 | Bucket sizes: `k3s-loki` 72 GB. Data older than 8 days: 74.1 GB, all from October and 5-6 November; last 8 days only 1.2 GB |
| 2026-11-15 | 313 old objects (with `xl.meta`) deleted through the S3 API with `rc rm`: no space freed. A sample object folder showed 10 data copies from 2026-10-20 01:29-01:35 and no `xl.meta` |
| 2026-11-15 | The 136 object folders without `xl.meta` and with data older than 2026-11-07 removed on disk (5 first as a test, Loki checked, then the rest) |
| 2026-11-15 | node1 at 53% (116 of 220 GB, 103 GB free). No Loki errors |

---

## Root Causes

### Primary: RustFS left superseded data copies behind

Repeated uploads of the same key during the crash loop left several data folders per object. Whether RustFS keeps
the previous copy on overwrite, or the copies were uploads interrupted by the crashing client and never cleaned up,
is not confirmed. Either way, once the object was deleted, nothing referenced the copies and no S3 operation could
reach them.

**Fix applied:** removed on disk, only object folders under `k3s-loki/fake/` with no `xl.meta` and data older than
2026-11-07 (RustFS treats them as non-existent). Procedure under "Cleanup procedure" below.

### Primary: the Loki crash loop ran for about three weeks unnoticed

The write pod crash-looped from 8 October and was only fixed on 5 November. Alert notifications were not connected
to ntfy yet (all routes went to `null`), so `KubePodCrashLooping` reached nobody.

**Fixed before this incident:** `loki-write` resources (`c1ab56fc`, `f562d1b3`), ntfy and healthchecks.io
notifications (OBS-002).

### Contributing: Prometheus was backed up every night

Metrics are disposable, but the Prometheus volume was the largest backup and changed almost completely every day.

**Fix applied:** `velero.io/exclude-from-backup=true` on the live PVC and in the kube-prometheus-stack
`volumeClaimTemplate` (`a939279d`). BACKUP-004 explains it. The three existing Prometheus backups expire by
2026-11-18.

### Contributing: RustFS shares node1's root disk

`/storage` on node1 is a folder on `/`. Anything that grows in a bucket fills the disk that Vault and the OS need.

**No change for now.** After the cleanup the disk is at 53%, and lower once the Prometheus backups expire. Revisit a
separate disk for `/storage` if it goes above about 70% again.

---

## What went well

- Measuring with `du --exclude=/storage` showed at once that RustFS used about 174 of 186 GB.
- Per-bucket, then per-day sizes pointed straight at October and matched the known Loki crash loop.
- Deleting through the S3 API first, and checking that the space did not come back, exposed the invisible copies
  before anything was removed on disk.
- The disk cleanup was tested on 5 folders, with Loki checked, before the rest.

## What went poorly

- `NodeRootDiskFillingUp` on node1 fired on 2026-11-14 and was put on the backlog without a look at what was growing.
- The step that listed old objects returned 313 lines where hundreds of thousands were expected; the deletion went
  ahead instead of stopping on the mismatch. Harmless here (the objects were unqueryable), but the wrong check.
- Several commands failed on the first try:
  - `kubectl get backups` resolves to a non-Velero CRD; use `backups.velero.io`.
  - node2 has no `velero` CLI; use `kubectl -n velero exec deploy/velero -c velero -- /velero ...`.
  - `sudo du /storage/rustfs/*` expands the glob as the normal user, who cannot read `/storage` (`0750 rustfs`), so
    use `sudo sh -c '...'`.
  - `sudo -v` asks for a password on nodes with passwordless sudo.
- The triage agent could not look at node1 and repeated two runbook statements that no longer held: "move
  node-esp-2 first", and DiskPressure at 85% (k3s actually evicts at 95%, `configz` checked; CLUSTER-012,
  alerting.md and the `NodeRootDiskFillingUp` description corrected).

---

## Actions to prevent recurrence

| # | Action | Status |
|---|---|---|
| 1 | Exclude Prometheus from Velero backups | Done (`a939279d`). Verified 2026-11-16: no new `pvc-e1c0c8e4` backup after 2026-11-15T03:27; 2026-11-19: `k3s-longhorn` 97 → 67 GB, node1 `/` at 40% |
| 2 | Remove the orphaned Loki data copies | Done: node1 86% → 53% |
| 3 | Triage agent can read Leases (tofu-controller locks) | Done (`a939279d`) |
| 4 | Verify Loki retention deletes current chunks: on 2026-11-17 no objects older than 2026-11-09 in `k3s-loki/fake` | Done 2026-11-19: no objects left from 2026-11-09 to 11-12, compactor marks and deletes on schedule. 99 objects (412 KB) from 2026-09-26 remain: chunks written during the ungraceful shutdown that never reached the index, so retention cannot see them. Left in place (negligible) |
| 5 | Check live objects (with `xl.meta`) for extra data copies, and size them | Done 2026-11-19: 4 objects in `k3s-loki/fake`, negligible. Other buckets: longhorn, tempo, barman clean; `k3s-velero` had 95 archives of expired backups (10 Aug to 16 Nov, 3.2 GB) with data but no `xl.meta`, the same bug; 94 removed on disk, node1 39% → 37% |
| 6 | Add the orphaned-copies check and cleanup to OBS-004 (Loki retention), and a node1 / RustFS section to CLUSTER-012 | Done: OBS-004 step 6, CLUSTER-012 step 7 |
| 7 | Watch bucket growth: a daily per-bucket size on node1 (node-exporter textfile collector) with an alert on fast growth | Open, proposal |
| 8 | Triage agent: query `node_filesystem_*` in Prometheus for external hosts such as node1; use `backups.velero.io` and `kubectl exec` for Velero | Done (`d4bb25f7`, `cluster-triage` steps 7 and 10; query tested) |
| 9 | Treat `NodeRootDiskFillingUp` on node1 as urgent: Vault and RustFS depend on it | Done: CLUSTER-012 step 7 |
| 10 | Report the leftover data copies to RustFS upstream, with the folder layout as evidence | Open, optional. More evidence 2026-11-19: Velero's deletes of its large backup archives leave the data the same way |
| 11 | Separate disk for `/storage` on node1 | Not needed now; revisit above about 70% |

## Open questions

- Does RustFS keep the previous data copy on every overwrite, or only for interrupted uploads? A test upload of the
  same key twice to a scratch bucket would tell.
- Are there leftover copies in other buckets (`k3s-longhorn`, `k3s-tempo`)? The same check (data folders in objects
  without `xl.meta`) applies.

---

## Cleanup procedure

On node1. Read-only first: list object folders without `xl.meta` whose data is older than the Loki retention, check
the paths and the size.

```bash
sudo sh -c 'find /storage/rustfs/k3s-loki/fake -mindepth 3 -maxdepth 3 -type d ! -newermt <YYYY-MM-DD> -printf "%h\n" | sort -u | while read o; do [ -e "$o/xl.meta" ] || echo "$o"; done' > ~/loki-dead-objects.txt
wc -l < ~/loki-dead-objects.txt
grep -vc '^/storage/rustfs/k3s-loki/fake/[0-9a-f]\{16\}/' ~/loki-dead-objects.txt   # must be 0
sudo xargs -d '\n' -a ~/loki-dead-objects.txt du -sc | tail -1
```

Remove a few, check Loki logs for errors, then the rest (in tmux). Each folder is checked again for `xl.meta` right
before removal:

```bash
sudo sh -c 'while read o; do [ -e "$o/xl.meta" ] || rm -rf -- "$o"; done' < ~/loki-dead-objects.txt
df -h /
```

## Quick health check

On node1:

```bash
df -h /
sudo sh -c 'cd /storage/rustfs/k3s-loki && find fake -name xl.meta ! -newermt "$(date -d "-9 days" +%F)" | wc -l'
```

On node2:

```bash
kubectl -n loki logs loki-backend-0 -c loki --since=1h | grep -i "level=error" | tail -5
kubectl -n longhorn-system get backups.longhorn.io -o custom-columns=VOL:.status.volumeName,CREATED:.status.backupCreatedAt | grep pvc-e1c0c8e4
```

Healthy: node1 below about 60%, close to 0 Loki objects older than 9 days, no Loki errors, no Prometheus backup newer
than 2026-11-15.
