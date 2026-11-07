# Incident: Vault and RustFS Let's Encrypt certificates expired
**Date:** 2026-11-07  
**Duration:** RustFS certificate expired 08:57 UTC and Vault's 09:02 UTC. Noticed about 11:30 UTC, Vault renewed about 11:50 UTC, RustFS about 12:30 UTC, all Flux Kustomizations ready again about 13:15 UTC. Vault was unusable for the cluster for about 2h45m. The OpenWrt gateway certificate had been expired since 2026-10-31 15:54 UTC without anyone noticing.  
**Impact:** External Secrets could not read from Vault, so `external-secrets-config` failed and blocked about ten dependent Flux Kustomizations (Loki, Cilium, cert-manager config, Velero, ThreatMap and others). Nothing new could deploy, including the Alertmanager notifications merged that morning. The Keycloak database could not archive its WAL to S3, its replica kept restarting, and the primary was OOM-killed once while uploading the backlog. Running workloads kept serving with their existing Kubernetes secrets. No data was lost.

---

## Summary

The Vault and RustFS (object-store) TLS certificates are Let's Encrypt certificates, valid for 90 days. Ansible's `deploy_vault.yml` and `deploy_rustfs.yml` request them with certbot, but only when those playbooks run. The last run was the cluster rebuild on about 2026-08-09, and nothing renews them in between. Both certificates were issued the same day and expired five minutes apart.

Everything that checks certificates then failed. External Secrets could not create a Vault client (`InvalidProviderConfig unable to create client`), and CNPG's `barman-cloud-wal-archive` could not upload to S3 (exit status 4).

No alert fired. Alertmanager notifications (ntfy, healthchecks.io) had been merged to master that morning as PR #956, but Flux could not deploy them because the Vault outage blocked the chain they depend on. There were also no rules for certificate expiry.

Running `make deploy-vault` and `make deploy-rustfs` renewed the certificates. The cluster recovered on its own after that, apart from three unrelated things that had queued up behind the outage (see Contributing). The gateway certificate, issued the same way by `make openwrt-certbot-tls`, turned out to have expired a week earlier and was renewed too.

---

## Timeline

Times are UTC. "~" marks times reconstructed from command output, not observed directly.

| Time | Event |
|---|---|
| ~2026-08-02 | OpenWrt gateway certificate issued (`make openwrt-certbot-tls`) |
| ~2026-08-09 | Cluster rebuild. `deploy_vault.yml` and `deploy_rustfs.yml` issue the Vault and RustFS certificates |
| 2026-10-31 15:54 | Gateway certificate expires. Only the router's web UI uses it, so nothing breaks |
| 2026-11-07 08:57:28 | RustFS (`object-store.homelab.marmilan.com:9091`) certificate expires. CNPG WAL archiving for `postgres-keycloak` starts failing |
| 2026-11-07 09:02:55 | Vault (`vault.homelab.marmilan.com:8200`) certificate expires. ClusterSecretStore `vault-backend` goes `InvalidProviderConfig` |
| ~09:10 onward | `external-secrets-config` health check times out. About ten Kustomizations report "dependency 'flux-system/external-secrets-config' is not ready" |
| ~11:10 | PR #956 (Alertmanager notifications) merged and Flux switched back to master. The alerting changes do not deploy: `kube-prometheus-stack-app` is blocked behind `longhorn-app`, which is blocked behind `external-secrets-config` |
| ~11:20 | Check shows `oauth2-alertmanager-externalsecret` in `SecretSyncedError` for 121 minutes and the store not ready |
| 11:32 | `vault read` on node1 fails: `x509: certificate has expired ... current time 2026-11-07T11:32:27Z is after 2026-11-07T09:02:55Z` |
| ~11:40–11:50 | `make deploy-vault` on pimaster: new certificate, Vault restarted and unsealed by the role |
| ~11:55 | `vault-backend` ready again. Flux starts working through the blocked Kustomizations |
| ~12:00 | Two Kustomizations still red: `loki-app` (Loki HelmRelease failed) and `keycloak-database` (`postgres-keycloak` not ready, `ContinuousArchiving=False`) |
| ~12:05 | Loki fixed: StatefulSet orphan-deleted so the pending 5Gi volume change could apply (see Contributing) |
| ~12:15 | RustFS certificate confirmed expired (`notAfter=Nov 7 08:57:28 2026 GMT`) |
| ~12:30 | `make deploy-rustfs` on pimaster. WAL archiving resumes and the backlog starts uploading |
| 12:34:57 | `postgres-keycloak-2` (primary) OOMKilled at its 512Mi limit while archiving the backlog. It restarts and stays primary |
| ~12:45 | `postgres-keycloak-1` (replica) streaming and caught up. Cluster `ready 2/2` |
| ~13:15 | All Flux Kustomizations ready. Alertmanager notifications live: ntfy secret synced, receivers loaded, Watchdog rule present |
| afternoon | Gateway certificate found expired since 2026-10-31 and renewed with `make openwrt-certbot-tls` |

---

## Root Causes

### Primary: Let's Encrypt certificates are issued once and never renewed

The three certificates outside the cluster come from certbot runs inside Ansible playbooks:

| Endpoint | Issued by | Used by |
|---|---|---|
| `vault.homelab.marmilan.com:8200` | `deploy_vault.yml` (`make deploy-vault`) | External Secrets, Terraform, the `vault` CLI |
| `object-store.homelab.marmilan.com:9091` | `deploy_rustfs.yml` (`make deploy-rustfs`) | CNPG WAL archive and backups, Velero, Longhorn backups, Loki and Tempo storage |
| `gateway.homelab.marmilan.com:443` | `generate_gateway_tls_certificate.yml` (`make openwrt-certbot-tls`) | OpenWrt web UI only |

There is no certbot timer, cron job or renewal step anywhere, so the certificates expire 90 days after the last playbook run. Since all external services are deployed together during a rebuild, their certificates expire together.

**Fix applied:** all three renewed by hand. They expire again around early February 2027. **No automatic renewal yet.**

### Primary: nothing alerted on expiring certificates or on the outage

- No rule watched certificate expiry for any endpoint, inside or outside the cluster.
- Alertmanager still routed everything to the `null` receiver. The fix (PR #956) was merged that morning, but Flux could not deploy it because the outage blocked its dependency chain.

**Fix applied:**
- Alertmanager notifications are live (ntfy for warning/critical, healthchecks.io as dead-man's switch).
- PR #959 adds a blackbox exporter that probes the three external endpoints every minute, with `TLSCertificateExpiringSoon` (<14 days), `TLSCertificateExpiringCritical` (<3 days), `TLSCertificateExpired` and `ExternalEndpointDown`, plus cert-manager rules for in-cluster certificates (not ready, renewal overdue, <24h left).

### Contributing: one failing Kustomization blocks most of the cluster

`external-secrets-config` waits for the ClusterSecretStore to be healthy, and many Kustomizations depend on it directly or through others. When Vault became unreachable, about ten Kustomizations stopped reconciling. Running workloads were not affected, but no change could deploy, including the alerting fix.

**No change made.** This ordering is intended: apps should not deploy before their secrets can sync. A future "secret store not ready" alert will make it visible within minutes.

### Contributing: the Keycloak database could not absorb a WAL backlog

While RustFS was unreachable, `postgres-keycloak` kept its WAL locally (`ContinuousArchiving=False`, `barman-cloud-wal-archive: exit status 4`). The replica `postgres-keycloak-1` restarted three times. After the RustFS certificate was renewed, the primary uploaded about 3.5 hours of WAL at once and was OOM-killed at its 512Mi limit (12:34:57). The replica then caught up at its 500m CPU limit. The 2026-10-06 Keycloak database postmortem had already flagged this OOM failure mode as "will recur whenever a WAL backlog builds up".

**Fix applied:** limits raised to 1 CPU / 1Gi (commit `c68a7ccd`).

### Contributing: the Loki volume change was stuck behind the outage

The prod `loki-write` volume had been raised from 1Gi to 5Gi the day before (`f562d1b3`). `volumeClaimTemplates` cannot be changed on an existing StatefulSet, so every Helm upgrade of Loki failed once Flux reached it. This was not caused by the certificates, but it showed up as a second blocker during recovery.

**Fix applied:** PVC patched to 5Gi, `kubectl -n loki delete sts loki-write --cascade=orphan`, HelmRelease forced. Volume now 5Gi.

---

## What went well

- The cluster recovered on its own once the certificates were valid. No secret, volume or database had to be rebuilt.
- Running workloads kept their existing Kubernetes secrets, so users saw almost nothing apart from a short Keycloak blip during the database restart.
- `make deploy-vault` renewed the certificate, restarted Vault and unsealed it in one step.
- The CNPG replica caught up by streaming from the primary and did not need to be rebuilt.

## What went poorly

- The outage was found by chance, about 2.5 hours in, while checking why the alerting rollout had not applied.
- The first symptom looked like a problem with the new alerting change, not with Vault.
- The OOM failure mode from the October Keycloak incident recurred because its follow-up had not been done.
- Nobody knew which certificates were issued outside cert-manager, so the RustFS and gateway certificates were found one at a time instead of all at once.

---

## Actions to prevent recurrence

| # | Action | Status |
|---|---|---|
| 1 | Route Alertmanager alerts to ntfy and Watchdog to healthchecks.io | Done (PR #956) |
| 2 | Alert on external certificate expiry (14d / 3d / expired) and endpoint down, plus cert-manager certificate alerts | Done (PR #959) |
| 3 | Raise `postgres-keycloak` limits so a WAL backlog upload does not OOM the primary | Done (`c68a7ccd`) |
| 4 | Automatic renewal for the Vault, RustFS and gateway certificates (scheduled job on pimaster that renews, copies and restarts) | Open. Must be in place, or renewed by hand, before early February 2027 |
| 5 | Alert when a ClusterSecretStore or ExternalSecret is not ready, and when Vault is sealed (`/v1/sys/health`) | Open |
| 6 | Alert on failed backups (Velero, Longhorn) and on CNPG `ContinuousArchiving=False` | Open |
| 7 | Create the ntfy/healthchecks Vault secret from Ansible so a rebuild does not leave alerting silent | Done (PR #958) |

## Open questions

- Did Velero and Longhorn backups to RustFS fail between 08:57 and ~12:30? Not checked. The next scheduled runs should be confirmed as `Completed`.
- Did anything else, such as Loki or Tempo object storage, drop data while RustFS was unreachable? Loki-write buffers in its WAL, so probably not, but it was not verified.

---

## Changes made during the incident

**Git:**
- `c68a7ccd` `postgres-keycloak` limits 500m/512Mi → 1 CPU/1Gi
- PR #959: blackbox exporter and certificate alerts (after the incident)

**pimaster:**
- `make deploy-vault`, `make deploy-rustfs`, `make openwrt-certbot-tls`

**Cluster, by hand:**
- `kubectl annotate clustersecretstore vault-backend force-sync=...` and Flux reconcile annotations to speed up recovery
- Loki: PVC `data-loki-write-0` patched to 5Gi, StatefulSet `loki-write` orphan-deleted, HelmRelease `forceAt`

## Quick check

Days left on each external certificate (Prometheus):

```
(probe_ssl_earliest_cert_expiry - time()) / 86400
```

From any machine:

```bash
for h in vault.homelab.marmilan.com:8200 object-store.homelab.marmilan.com:9091 gateway.homelab.marmilan.com:443; do echo "== $h"; echo | openssl s_client -connect $h -servername ${h%:*} 2>/dev/null | openssl x509 -noout -enddate; done
```
