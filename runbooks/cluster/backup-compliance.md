# Backup and Compliance Runbooks

## BACKUP-001 Velero Namespace Restore Drill

<a id="runbook-backup-001"></a>
Runbook ID: `BACKUP-001`
Owner: Platform
Severity: `Maintenance`

Objective: Periodically validate namespace restore from Velero backups.

Preconditions:

- Valid recent backup exists.
- Target namespace for restore test agreed.

Procedure:

1. List backups and choose restore point.

## BACKUP-002 Velero Full-Cluster Restore Drill

<a id="runbook-backup-002"></a>
Runbook ID: `BACKUP-002`
Owner: Platform
Severity: `Maintenance`

Objective: Validate end-to-end disaster recovery readiness using full-cluster restore simulation.

Preconditions:

- Isolated test environment or dedicated recovery cluster.
- Recent backup and object store access validated.

Procedure:

1. Select backup snapshot and capture baseline metadata.

```bash
velero backup get
velero backup describe <backup-name> --details
```

2. Trigger full restore in test environment.

```bash
velero restore create restore-full-<test-id> --from-backup <backup-name>
```

3. Track restore progress and inspect warnings/errors.

```bash
velero restore get
velero restore describe restore-full-<test-id> --details
```

4. Validate core services (Flux, DNS, ingress, storage, observability).
5. Record RTO/RPO metrics and gaps.

Verify:

- Restore completed successfully.
- Core platform functionality passes smoke tests.
- Targeted stateful apps recover expected data.

Rollback:

1. Tear down test restore environment.
2. Keep logs/reports and open remediation tasks for failures.

## BACKUP-003 Backup Retention and Cleanup Execution

<a id="runbook-backup-003"></a>
Runbook ID: `BACKUP-003`
Owner: Platform
Severity: `Maintenance`

Objective: Enforce retention policy and prevent backup storage exhaustion.

Procedure:

1. Inventory current backup objects and sizes.

```bash
velero backup get
```

2. Compare current state against retention policy.
3. Delete expired backup objects in controlled batches.

```bash
velero backup delete <backup-name> --confirm
```

4. Verify backup storage health and free capacity.
5. Update policy docs if retention requirements changed.

Verify:

- Retention targets met.
- New backup jobs continue to succeed.

Rollback:

1. If accidental deletion occurs, escalate to object-storage versioning recovery (if enabled).
2. Temporarily pause cleanup automation until root cause is addressed.

## BACKUP-004 Velero Backup Failed or Missing

<a id="runbook-backup-004"></a>
Runbook ID: `BACKUP-004`
Owner: Platform
Severity: `SEV-2` (no backup in 25h), `SEV-3` (one failed or partial backup)

Objective: Find why the nightly Velero backup failed or did not run, and get a good backup again.

Alerts: `VeleroBackupFailed` (warning, a backup of a schedule failed or partially failed in the last 24
hours; resolves by itself after 24h), `VeleroNoRecentBackup` (critical, no successful backup of a schedule in
25 hours).

Background: Schedule `full` (`kubernetes/platform/velero/config/base/backup-schedule.yaml`) backs up all
namespaces daily at 02:00 to RustFS, with Longhorn volume snapshots (CSI). Common causes: RustFS down or its
certificate expired, Longhorn snapshot errors, a stuck volume snapshot, Velero pod restarted mid-backup.

Procedure:

1. List the recent backups and their state (on node2):

```bash
kubectl -n velero get backups.velero.io --sort-by=.metadata.creationTimestamp -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERRORS:.status.errors,WARNINGS:.status.warnings,STARTED:.status.startTimestamp | tail -5
kubectl -n velero get schedules.velero.io
kubectl -n velero get backupstoragelocations.velero.io
```

2. Match the case:

| What you see | Meaning | Go to |
| --- | --- | --- |
| BackupStorageLocation `Unavailable` | Velero cannot reach RustFS | `MINIO-001`, `NET-009` if the certificate expired |
| Last backup `PartiallyFailed` | Some items failed, often volume snapshots | Step 3 |
| Last backup `Failed` | The whole backup failed | Step 3 |
| No backup created since yesterday | Schedule paused or Velero not running | Step 4 |

3. Read the errors of the failed backup:

```bash
kubectl -n velero get backups.velero.io <backup> -o jsonpath='{.status.failureReason}{"\n"}'
kubectl -n velero logs deploy/velero --since=24h | grep -iE "error|fail" | grep <backup> | tail -20
kubectl get volumesnapshots -A | grep -v "true" | head
```

   Snapshot errors: check Longhorn volume health (`LONGHORN-001`) and the snapshot count per volume
   (`postmortems/longhorn-snapshot-incident-postmortem.md`).

4. Velero not running or schedule paused:

```bash
kubectl -n velero get pods
kubectl -n velero get schedules.velero.io full -o jsonpath='{.spec.paused}{" last: "}{.status.lastBackup}{"\n"}'
```

5. Once the cause is fixed, take a backup now instead of waiting for 02:00:

```bash
kubectl -n velero create -f - <<'YAML'
apiVersion: velero.io/v1
kind: Backup
metadata:
  generateName: full-manual-
  labels:
    velero.io/schedule-name: full
spec:
  includedNamespaces: ["*"]
  includeClusterResources: true
  ttl: 72h0m0s
YAML
```

   The `velero.io/schedule-name: full` label counts it for the schedule, so `VeleroNoRecentBackup` clears.

Verify:

- The newest backup is `Completed` with 0 errors.
- `VeleroNoRecentBackup` resolves; `VeleroBackupFailed` resolves 24 hours after the failure.

Rollback:

1. Delete a broken manual backup with `velero backup delete <backup>`. Do not use `kubectl delete` on the
   Backup object: it leaves the data in RustFS and Velero syncs the backup back.

References:

- `kubernetes/platform/velero/config/base/backup-schedule.yaml`
- `kubernetes/platform/velero/app/components/monitoring/velero-alert-rules.yaml`
- `BACKUP-003` for retention and storage cleanup
