# S3 Storage (RustFS) Runbooks

> Runbook IDs retain the historical `MINIO-*` prefix for continuity.
> The object store actually deployed in this cluster is RustFS (S3-compatible).

## MINIO-001 MinIO Service Degradation Triage

<a id="runbook-minio-001"></a>
Runbook ID: `MINIO-001`
Owner: Platform Storage
Severity: `SEV-1` or `SEV-2`

Objective: Restore RustFS availability and S3 operations.

Background: RustFS runs outside the cluster, as the systemd service `rustfs` on node1 (data in
`/storage/rustfs` on the root disk, API `https://object-store.homelab.marmilan.com:9091`). It is installed by
`make deploy-rustfs` (role `ricsanfre.rustfs`, version `rustfs_server_version` in `ansible/vars/picluster.yml`).
Its logs go to `/var/log/rustfs/` at level `error` (`/etc/rustfs/rustfs.conf`), **not** to the journal.

Procedure (on node1):

1. Service, version and disk:

```bash
systemctl status rustfs --no-pager | head -5
systemctl show rustfs -p ActiveEnterTimestamp,NRestarts
/usr/local/bin/rustfs --version | head -1   # must match rustfs_server_version in git
df -h /
```

2. Logs around the time of the client error:

```bash
sudo ls -la /var/log/rustfs/
sudo sh -c 'cat /var/log/rustfs/*' | grep "<YYYY-MM-DDTHH:MM>" | head -20
```

3. Client view: `rc ls picluster/` lists the buckets (`k3s-barman`, `k3s-loki`, `k3s-longhorn`, `k3s-tempo`,
   `k3s-velero`, `restic`).
4. TLS: an expired certificate fails every client, see `NET-009`.
5. A client reports `NoSuchBucket` but step 3 lists the bucket: RustFS answered a wrong error for a short
   time (seen 2026-11-21/22 on a long Longhorn upload, node1 still on `1.0.0-beta.7` while git said `1.0.4`).
   Do not recreate the bucket. Bring RustFS to the git version (`make deploy-rustfs` on pimaster, by day)
   and retry the client (Longhorn/Velero: `BACKUP-004` step 3a).
6. Only if the bucket is really missing: recreate it with `terraform/minio` (needs an explicit `tofu apply`).

Verify:

- `rc ls picluster/` works and the blackbox `object-store` probe is up (no `ExternalEndpointDown`).
- Backup systems and S3 clients recover (Velero `BackupStorageLocation` Available, Longhorn backup target
  `available=true`, CNPG `ContinuousArchiving=True`).

Rollback:

1. Set `rustfs_server_version` back to the previous release in git and run `make deploy-rustfs` again.
