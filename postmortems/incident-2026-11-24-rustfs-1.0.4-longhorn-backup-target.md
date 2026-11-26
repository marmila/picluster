# Incident: RustFS 1.0.4 made Longhorn's backup target unavailable, nightly volume backups failed
**Date:** 2026-11-24  
**Duration:** Longhorn backup target unavailable from 2026-11-23 06:46 UTC (RustFS upgrade) to 2026-11-24 16:34 UTC,
about 34 hours. Found at the morning check on 24 Nov, about 07:15 UTC.  
**Impact:** the nightly Velero backup `full-20261124020037` ended `PartiallyFailed` (30 errors, 1,428 warnings): all
12 Longhorn volume snapshots failed, so no volume data (Elasticsearch, Kafka ×3, Keycloak Postgres ×2, Loki ×2,
Grafana, Alertmanager, Freqtrade ×2) was backed up between 23 Nov 02:36 and 24 Nov 17:21 UTC. The Kubernetes
objects were backed up. No data lost; nothing had to be restored. RustFS restart and rollback: about 1 minute of S3
outage in total, by day.

---

## Summary

On 23 Nov RustFS on node1 was upgraded from `1.0.0-beta.7` to `1.0.4` (`make deploy-rustfs`, postmortem
2026-11-15 action 12: run the version git says). Three minutes before the new process started, Longhorn synced its
backup target for the last time.

On 1.0.4, Longhorn's `longhorn system-backup list s3://k3s-longhorn@eu-west-1/` took **127 to over 300 seconds**.
Longhorn runs that command on every backup target sync and gives up after about 2 minutes, so it marked the
target `Unavailable` and refused every snapshot backup: `rpc error: code = Aborted desc = backup target default is
not available`. The manager on node-esp-1 logged `Failed to get info from backup store` 1,438 times; RustFS logged the
client giving up as `TLS handshake failed ... Connection reset by peer` from 10.0.0.20 (node-esp-1).

Everything else on the S3 side was fast: `rc ls` of the same prefix 0.24 s, signed ListObjects V1 and V2 requests
from node2 0.1-0.2 s, `longhorn backup ls --volume-only` 1 s, TLS handshake 0.28 s, certificate valid. The slow step
is inside the client/server exchange of that one Longhorn command and was not narrowed down further. RustFS used
113% CPU while idle. A restart did not help; rolling back to `1.0.0-beta.7` did: 0 s, target available after 5
minutes, CPU 6.5%, and a manual backup backed up all 12 volumes.

---

## Timeline

Times are UTC.

| Time | Event |
|------|-------|
| 2026-11-23 06:46:41 | Last successful Longhorn backup target sync (beta.7) |
| 2026-11-23 06:49 | RustFS 1.0.4 starts (`make deploy-rustfs`; `.rustfs.sys` saved to `~/rustfs-sys-2026-11-23.tgz` first) |
| 2026-11-23 day | Upgrade checked with `rustfs --version` and `rc ls`: service active, 6 buckets. Longhorn not checked |
| 2026-11-23 → 24 | Longhorn retries the sync every few minutes, each time timing out; no alert |
| 2026-11-24 02:00:37 | `full-20261124020037` starts; all 12 VolumeSnapshots fail (`backup target default is not available`) → `PartiallyFailed` |
| 2026-11-24 02:00-05:00 | RustFS: **0** `Io error: timeout` (were 260 and ~1,000 the two nights before on beta.7) |
| ~07:15 | Morning check: backup `PartiallyFailed`, 30 errors. `velero` CLI missing on node2, kubectl used instead |
| ~07:25 | VolumeSnapshots show the cause; backup target `AVAILABLE=false`, condition `timeout executing ... system-backup list` |
| ~07:30 | Certificate fine (Let's Encrypt, valid to Feb 2027); `rc ls` of every prefix 0.2-0.3 s on node1 |
| 07:37 | Longhorn command run by hand in the node-esp-1 manager pod: 127 s; `backup ls --volume-only` 1 s; curl TLS 0.28 s |
| ~07:40 | Raw signed S3 list requests (V1 and V2, missing and existing prefix) from node2: 0.1-0.2 s |
| 07:40-07:50 | Same command with `--debug` on node-esp-1 and node-esp-2: both hang 300 s (not node-specific) |
| ~07:55 | RustFS restarted; command still 151 s |
| 16:29 | RustFS rolled back to `1.0.0-beta.7` (`deploy_rustfs.yml -e rustfs_server_version=1.0.0-beta.7`), CPU 6.5% |
| 16:30 | Command: 0 s |
| 16:34 | Backup target `AVAILABLE=true` |
| 17:19-17:21 | Manual backup `full-manual-bzwdh` Completed, 0 errors; 12 Longhorn backups Completed |
| ~18:00 | Pin pushed (`02da2901`): git `1.0.0-beta.7`, Renovate skips 1.0.0-1.0.4, runbook MINIO-001 step 7 |

---

## Root Causes

### Primary: a RustFS 1.0.4 regression for the Longhorn client

The only change between the last good sync and the first failure was the RustFS upgrade, and rolling it back fixed
the problem at once. Plain S3 listing was not slow, so the problem is specific to what the Longhorn engine binary
(v1.13.0, AWS SDK) sends for `system-backup list`. RustFS's own logs showed no error at the time of the hand-run
command. Not narrowed down: retries inside the SDK, a request type the tests did not reproduce, or the busy RustFS
process (113% CPU idle; the scanner kept failing on `buckets/.usage.v2.json`).

### Contributing: the upgrade was checked from the server side only

After the 23 Nov upgrade, the check was `rustfs --version` and `rc ls` on node1. No client was tested: Longhorn's
target state, a Velero backup or a CNPG WAL push would each have shown it within minutes.

### Contributing: no alert for an unavailable Longhorn backup target

The target was unavailable for about 19 hours before the backup ran, with Longhorn logging an error every few
minutes. The only signal was `VeleroBackupFailed` after the nightly backup, which is a warning and fires only once a
backup has already failed.

### Contributing: an upgrade postponed for three weeks

Renovate set 1.0.4 on 1 Nov, but `make deploy-rustfs` was run only on 23 Nov (postmortem 2026-11-15 action 12). The
jump covered every release from beta.7 to 1.0.4, so any regression in between arrived at once and in the same week as
the disk incident.

---

## What went well

- The morning backup check caught it the first night, before a second backup failed.
- `.rustfs.sys` had been saved before the upgrade, and the playbook takes the version as a variable: the rollback
  was one command and did not need the saved state.
- The diagnosis ruled things out fast, each with one command: certificate, network/TLS from the node, plain S3
  listing (`rc`, signed curl V1/V2), node-specific (two managers), restart.
- Running Longhorn's own binary inside the manager pod reproduced the failure exactly and gave a clear before/after
  test (127-300 s → 0 s).

## What went poorly

- The `velero` CLI is not on node2, so the first diagnostic command failed.
- About 9 hours between finding the cause and rolling back (user away during the day). Volume backups were
  missing for about 39 hours in total.
- The RustFS log grep around the hand-run command found nothing: RustFS does not log slow requests.

---

## Actions to prevent recurrence

| # | Action | Status |
|---|--------|--------|
| 1 | Alert when the Longhorn backup target is unavailable for more than 30 minutes (Longhorn metric if one exists, otherwise a small check job), warning severity, runbook MINIO-001 step 7 | Open |
| 2 | Pin RustFS to `1.0.0-beta.7` in git; Renovate skips 1.0.0-1.0.4 (`.github/renovate/automerge.json5`) | Done 2026-11-24 (`02da2901`) |
| 3 | Test RustFS upgrades from the clients: by day, right after `make deploy-rustfs` run the Longhorn timing check (MINIO-001 step 7), check the backup target `AVAILABLE=true`, run a manual Velero backup | Done 2026-11-24: runbook MINIO-001 step 7, ops checklist |
| 4 | Deploy RustFS bumps soon after Renovate merges them, one version at a time, instead of letting them pile up | Partly done 2026-11-24: a RustFS bump is its own Renovate PR, out of the weekly bundle, never automerged (merge after the step 7 test). Deploying soon after is still manual (ops checklist "RustFS bumps are not applied by Flux") |
| 5 | Report to RustFS upstream: `longhorn system-backup list` 127-300 s on 1.0.4, fast on beta.7, with the timings above | Done 2026-11-26: [rustfs/rustfs#9659](https://github.com/rustfs/rustfs/issues/9659). Add the 1.0.7 test result there |
| 6 | Clean up the beta.7 scanner error `Scanner stopped because the persisted usage floor could not be loaded` (`buckets/.usage.v2.json` written by 1.0.4); only RustFS's own usage statistics | Open, low |
| 7 | Install the `velero` CLI on node2 (or use the kubectl commands in BACKUP-004) | Open, low |
| 8 | Postmortem 2026-11-15 action 11 (separate disk for node1): 1.0.4 had 0 backup-window timeouts, but it is rolled back; decide from the beta.7 nights from 25 Nov | Open |

## Quick health check

node2:

```bash
kubectl -n longhorn-system get backuptargets.longhorn.io default -o custom-columns=AVAILABLE:.status.available,LASTSYNC:.status.lastSyncedAt
kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors | tail -3
kubectl get volumesnapshots -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyToUse | grep -v true
```

node1:

```bash
rustfs --version | head -1          # 1.0.0-beta.7 until a newer version passes MINIO-001 step 7
```

Related: [postmortem 2026-11-15](incident-2026-11-15-node1-disk-rustfs-loki-orphans.md) (actions 11, 12),
runbook MINIO-001 ([s3-storage.md](../runbooks/components/s3-storage.md)) step 7,
[ops checklist](../homelab-docs/ops-checklist.md) "24 Nov: RustFS 1.0.4 broke the Longhorn backup target".
