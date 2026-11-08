# Runbook Map

Symptom-to-runbook index for triage. Canonical catalog: [`runbooks/README.md`](../../../runbooks/README.md).

## Alerts

<a id="alerts"></a>
Alert name to runbook. Alerts defined in this repository also carry the runbook ID in a `runbook`
annotation and at the end of their description, so it appears in the ntfy message.

| Alert | Runbook | Notes |
| --- | --- | --- |
| `TLSCertificateExpiringSoon`, `TLSCertificateExpiringCritical`, `TLSCertificateExpired` | `NET-009` | External Let's Encrypt certificates (Vault, RustFS, gateway). Label `target` names the endpoint |
| `VaultSealed` | `VAULT-001` | Vault answers TLS but `/v1/sys/health` is not 200 (503 sealed). Unseal on node1 |
| `ClusterSecretStoreNotReady`, `ExternalSecretNotReady` | `VAULT-006` | Store not ready: check Vault (sealed, certificate) first. One ExternalSecret: usually a missing Vault key |
| `ExternalEndpointDown` | `VAULT-001` (target `vault`), `MINIO-001` (`object-store`), `NET-009` | Check the certificate first: an expired one also fails the probe |
| `CertManagerCertificateNotReady` | `NET-005` | In-cluster certificate issuance failing |
| `CertManagerCertificateRenewalOverdue`, `CertManagerCertificateExpiringCritical` | `NET-007` | cert-manager missed its renewal time |
| `Watchdog` missing, healthchecks.io alarm, no ntfy messages | `OBS-002` | `Watchdog` firing is normal |
| `FluxSourceNotReady` | `GITOPS-001` | |
| `FluxKustomizationNotReady` | `GITOPS-002` | If many are not ready, look for the one they depend on (often `external-secrets-config` → Vault) |
| `FluxHelmReleaseNotReady` | `GITOPS-003` | |
| `FluxResourceSuspended` | `GITOPS-004` | |
| `TerraformStateLocked`, `TerraformNotReady` | `GITOPS-007` | Stuck OpenTofu state lock after a runner pod died; the alert shows the lock ID. `elastic-stack-config` / `keycloak-config` go not ready with it |
| `KubeAPIDown`, `KubeNodeUnreachable` | `CLUSTER-014` | On a Pi node, check under-voltage first: `sudo vcgencmd get_throttled` |
| `RaspberryPiUnderVoltage`, `RaspberryPiThrottled`, `RaspberryPiThrottleMetricsMissing` | `CLUSTER-016` | Usually a loose or weak power cable. Linux tools show the normal CPU frequency; only `vcgencmd` shows the real one |
| `KubeNodeNotReady`, `KubeletDown` | `CLUSTER-011`, `CLUSTER-014` | |
| `NodeRootDiskFillingUp`, `KubeNodeDiskPressure` | `CLUSTER-012` | Usually the systemd journal or container images on the root disk. Image GC starts at 70%, eviction at 85% |
| `NodeFilesystemAlmostOutOfSpace`, `NodeFilesystemSpaceFillingUp` | `CLUSTER-012` | |
| `KubePersistentVolumeFillingUp` | `OBS-004` for Loki, otherwise none yet | StatefulSet volume sizes need the PVC patched and the StatefulSet orphan-deleted |
| `KubePodCrashLooping`, `KubePodNotReady`, `KubeDeploymentReplicasMismatch`, `KubeStatefulSetReplicasMismatch` | sweep step 6, then `GITOPS-003` if the workload belongs to a HelmRelease | |
| `K3sUpgradePlanStuck`, `K3sNodeVersionDrift` | `CLUSTER-015` | A failed upgrade job is never retried. A node can also be marked done but still run the old version until k3s is restarted |
| `KubeVersionMismatch` | `CLUSTER-015` | Normal for about an hour during every k3s upgrade; act only if it lasts longer |
| `KubeJobFailed` | none yet | Old failed jobs keep firing until deleted |
| `VeleroBackupFailed`, `VeleroNoRecentBackup` | `BACKUP-004` | Nightly `full` schedule at 02:00. Check the BackupStorageLocation (RustFS) first |
| `LonghornVolumeDegraded`, `LonghornVolumeFaulted` | `LONGHORN-001` | Degraded is normal for a while after a node reboot (replica rebuild) |
| `CNPGWALArchivingFailing`, `CNPGNoRecentBackup` | `PG-001` | Keycloak Postgres to RustFS. An expired RustFS certificate is the usual cause |
| `ScrapeTargetDown` | `OBS-001` | `context deadline exceeded` is often a NetworkPolicy dropping Prometheus; node1 targets: check the exporter on node1 |

## Cluster-wide

### Bootstrap and recovery — `runbooks/cluster/bootstrap-recovery.md`

| ID | Use when |
| --- | --- |
| `CLUSTER-001` | Rebuilding the cluster from zero (new hardware, clean OS, full reinstall) |
| `CLUSTER-002` | Recovering a lost cluster from Git and backups |

### Nodes and capacity — `runbooks/cluster/nodes-capacity.md`

| ID | Use when |
| --- | --- |
| `CLUSTER-010` | Replacing a failed node |
| `CLUSTER-011` | Planned drain, reboot, or maintenance |
| `CLUSTER-012` | `DiskPressure`, evictions, or a full node filesystem |
| `CLUSTER-014` | Cluster API unavailable; a node accepts TCP but never sends a banner; etcd reports no quorum |
| `CLUSTER-015` | A k3s upgrade stopped part-way: plan not complete, nodes on different versions, node left cordoned |
| `CLUSTER-016` | A Raspberry Pi reports under-voltage or a throttled CPU; a Pi is slow for no visible reason |

### GitOps and release — `runbooks/cluster/gitops-release.md`

| ID | Use when |
| --- | --- |
| `GITOPS-001` | Flux cannot fetch from Git; source `READY=False` |
| `GITOPS-002` | A Kustomization is stuck or not ready |
| `GITOPS-003` | A HelmRelease is stuck or not ready |
| `GITOPS-004` | You need to suspend and later resume reconciliation safely |
| `GITOPS-005` | Upgrading or rolling back Flux itself |
| `GITOPS-006` | Validating a branch against the live cluster |
| `GITOPS-007` | A tofu-controller Terraform resource is stuck or its state is locked |

### Security and access — `runbooks/cluster/security-access.md`

| ID | Use when |
| --- | --- |
| `SEC-001` | A credential leaked and must be rotated |
| `SEC-002` | A node is suspected compromised |
| `SEC-003` | A TLS private key may be compromised |

### Upgrades and change — `runbooks/cluster/change-management.md`

| ID | Use when |
| --- | --- |
| `CHANGE-001` | Before any risky change: go/no-go checklist |
| `CHANGE-002` | After a change: validation checklist |

### Backup and compliance — `runbooks/cluster/backup-compliance.md`

| ID | Use when |
| --- | --- |
| `BACKUP-001` | Restoring a single namespace with Velero |
| `BACKUP-002` | Full-cluster restore drill or recovery |
| `BACKUP-003` | Retention, cleanup, or storage pressure on backups |
| `BACKUP-004` | Nightly Velero backup failed, partially failed, or did not run |

### Operations and governance — `runbooks/cluster/operations-governance.md`

| ID | Use when |
| --- | --- |
| `OPS-001` | An incident needs command structure and coordination |
| `OPS-002` | Writing a postmortem and tracking follow-ups |

## Components

### Keycloak — `runbooks/components/keycloak.md`

| ID | Use when |
| --- | --- |
| `KEYCLOAK-001` | Wiping and recreating the Keycloak database |
| `KEYCLOAK-002` | Config drift; reconciling Keycloak from Git |
| `KEYCLOAK-003` | Restoring the Keycloak DB from a CNPG backup |
| `KEYCLOAK-004` | Rotating the Keycloak admin credentials |
| `KEYCLOAK-005` | Rotating OIDC client secrets (Grafana, Kiali, OAuth2-Proxy) |
| `KEYCLOAK-006` | Keycloak Flux Kustomization incident |
| `KEYCLOAK-007` | tofu-controller failure modes (stuck state lock: `GITOPS-007`) |
| `KEYCLOAK-008` | CNPG health and failover checks |
| `KEYCLOAK-009` | Namespace/service DNS debugging |
| `KEYCLOAK-010` | Planned upgrade of Keycloak, operator, or DB |
| `KEYCLOAK-011` | Emergency disable of SSO dependencies |
| `KEYCLOAK-012` | Safe decommission of the stack |
| `KEYCLOAK-013` | Post-incident validation |

### Vault — `runbooks/components/vault.md`

| ID | Use when |
| --- | --- |
| `VAULT-001` | Vault outage; sealed or unreachable |
| `VAULT-002` | Token, policy, or role rotation |
| `VAULT-003` | Backup and restore |
| `VAULT-004` | Auth backend troubleshooting (Kubernetes, AppRole) |
| `VAULT-005` | Seal migration and key rotation |
| `VAULT-006` | External Secrets not syncing (ClusterSecretStore or one ExternalSecret) |

### Longhorn storage — `runbooks/components/longhorn.md`

| ID | Use when |
| --- | --- |
| `LONGHORN-001` | A Longhorn volume is degraded or faulted |

### Data services — `runbooks/components/data-services.md`

| ID | Use when |
| --- | --- |
| `PG-001` | CNPG WAL archiving or base backups failing |

### S3 storage (RustFS) — `runbooks/components/s3-storage.md`

| ID | Use when |
| --- | --- |
| `MINIO-001` | S3 service degraded or unavailable |

`MINIO-*` IDs are historical; the deployed object store is RustFS.

### Elastic and logging — `runbooks/components/elastic-logging.md`

| ID | Use when |
| --- | --- |
| `ELASTIC-001` | Elasticsearch cluster red or yellow |

### Monitoring and tracing — `runbooks/components/observability.md`

| ID | Use when |
| --- | --- |
| `OBS-001` | Prometheus target down or scrape failing (`ScrapeTargetDown`) |
| `OBS-002` | Alert notifications not arriving (ntfy, healthchecks.io) |
| `OBS-004` | Loki ingestion or retention problems |

### Service mesh and ingress — `runbooks/components/networking-ingress.md`

| ID | Use when |
| --- | --- |
| `NET-004` | CoreDNS outage or resolution failures |
| `NET-005` | Certificate issuance failing (cert-manager) |
| `NET-006` | Inspecting served certificates and chain |
| `NET-007` | Renewal monitoring and forced reissuance |
| `NET-008` | TLS secret does not match the served certificate |
| `NET-009` | Renewing the external Let's Encrypt certificates (Vault, RustFS, gateway) |

## Backlog (no runbook yet)

These IDs are catalogued but not written. If a task falls into one, use the closest triage runbook and
flag the gap:

`CLUSTER-003`, `CLUSTER-013`, `SEC-004`, `SEC-005`, `CHANGE-003`, `CHANGE-004`, `AUDIT-001`,
`OPS-003`, `OPS-004`, `MINIO-002` … `MINIO-005`, `ELASTIC-002` … `ELASTIC-005`, `OBS-003`, `OBS-005`, `KAFKA-001`, `KAFKA-002`, `MONGO-001`, `NET-001` … `NET-003`.
