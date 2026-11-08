# Data Services Runbooks

## PG-001 CloudNativePG WAL Archiving or Backup Failure

<a id="runbook-pg-001"></a>
Runbook ID: `PG-001`
Owner: Platform
Severity: `SEV-2`

Objective: Get a CloudNativePG cluster archiving WAL and taking base backups to object storage again.
Written for `postgres-keycloak` (namespace `databases`); the same steps apply to any CNPG cluster.

Alerts: `CNPGWALArchivingFailing` (critical, the last WAL archive attempt failed and none has succeeded since,
for 15 minutes), `CNPGNoRecentBackup` (warning, no base backup in 26 hours).

Background: WAL files (the database change log) and daily base backups (02:30) go to
`s3://k3s-barman/postgres-keycloak` on RustFS (node1). Without them, Keycloak can only be restored from the
nightly Velero backup, and WAL that cannot be archived piles up on the database volume until it is full. On
2026-11-07 an expired RustFS certificate stopped archiving without any alert.

Procedure:

1. Check the cluster and the archive status (on node2):

```bash
kubectl -n databases get cluster.postgresql.cnpg.io postgres-keycloak -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl -n databases get backups.postgresql.cnpg.io --sort-by=.metadata.creationTimestamp | tail -5
kubectl -n databases logs -l cnpg.io/cluster=postgres-keycloak,role=primary --since=1h | grep -iE "archive|barman|s3|x509|error" | tail -20
```

2. Match the error:

| Error in the logs | Meaning | Go to |
| --- | --- | --- |
| `x509`, `certificate has expired` | RustFS certificate | `NET-009` |
| `connection refused`, timeout | RustFS down | `MINIO-001` |
| `AccessDenied`, `InvalidAccessKeyId` | Wrong credentials in `postgres-keycloak-s3-secret` | Step 3 |
| `NoSuchBucket` | Bucket `k3s-barman` missing | Recreate it with `terraform/minio` |

3. Credentials: check the Secret is synced from Vault (`VAULT-006`):

```bash
kubectl -n databases get externalsecret
kubectl -n databases get secret postgres-keycloak-s3-secret
```

4. Once object storage works, archiving resumes by itself (failed WAL files are retried). Check that
   `ContinuousArchiving` is `True` in step 1. Then take a base backup now:

```bash
kubectl -n databases create -f - <<'YAML'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  generateName: postgres-keycloak-manual-
spec:
  method: barmanObjectStore
  cluster:
    name: postgres-keycloak
YAML
kubectl -n databases get backups.postgresql.cnpg.io -w
```

5. If the database volume is filling up with WAL in the meantime, grow the PVC or fix archiving first. Do not
   delete WAL files by hand.

Verify:

- Condition `ContinuousArchiving=True`, the latest Backup `completed`.
- `CNPGWALArchivingFailing` and `CNPGNoRecentBackup` resolve.

Rollback:

1. Nothing to roll back: these steps only restore archiving. To restore data, use `KEYCLOAK-003`.

References:

- `kubernetes/platform/keycloak/database/base/postgres-cluster.yaml`
- `kubernetes/platform/keycloak/database/overlays/prod/postgres-alert-rules.yaml`
- `KEYCLOAK-008` (CNPG health and failover), `KEYCLOAK-003` (restore from backup)
- `postmortems/incident-2026-11-07-letsencrypt-certificates-expired.md`
