# Service Mesh and Ingress Runbooks

## NET-004 CoreDNS Outage and Recovery

<a id="runbook-net-004"></a>
Runbook ID: `NET-004`
Owner: Platform Networking
Severity: `SEV-1` or `SEV-2`

Objective: Restore cluster DNS when service discovery fails.

Procedure:

1. Confirm DNS symptoms and CoreDNS pod status.

```bash
kubectl -n kube-system get pods -l k8s-app=kube-dns
kubectl -n kube-system logs deploy/coredns --tail=200
```

2. Validate CoreDNS service and endpoints.

```bash
kubectl -n kube-system get svc kube-dns
kubectl -n kube-system get endpoints kube-dns
```

3. Run in-cluster DNS test.

```bash
kubectl run -n default dns-test --rm -it --restart=Never --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local
```

4. If config drift is suspected, reconcile CoreDNS manifests.
5. If pod scheduling/resource issues exist, remediate node pressure/taints.

Verify:

- CoreDNS pods Ready.
- Service resolution works from test pod.
- Flux and controllers recover from DNS-related errors.

Rollback:

1. Revert last CoreDNS config change in Git.
2. Reconcile affected Kustomization and retest DNS.

## NET-005 TLS Certificate Issuance Failures (cert-manager)

<a id="runbook-net-005"></a>
Runbook ID: `NET-005`
Owner: Platform Networking
Severity: `SEV-2`

Objective: Recover certificate issuance/renewal when cert-manager requests fail.

Procedure:

1. Identify failed Certificate, CertificateRequest, Order, and Challenge resources.

```bash
kubectl get certificate,certificaterequest,order,challenge -A
kubectl describe certificate <name> -n <namespace>
```

2. Inspect cert-manager controller logs.

```bash
kubectl -n cert-manager logs deploy/cert-manager --tail=200
```

3. Validate issuer configuration and DNS/API credentials.
4. Fix issuer/secret/solver settings in Git and reconcile.
5. Re-trigger issuance by deleting failed challenge/order resources if needed.

Verify:

- Certificate condition `Ready=True`.
- Target ingress/workload presents valid certificate.

Rollback:

1. Revert issuer or solver changes.
2. Fall back to temporary internal certificate only for emergency continuity.

## NET-006 TLS Endpoint Certificate Inspection and Chain Validation

<a id="runbook-net-006"></a>
Runbook ID: `NET-006`
Owner: Platform Networking
Severity: `SEV-2`

Objective: Determine whether a TLS issue is caused by an expired certificate, incorrect Subject Alternative Name, missing intermediate CA, or the wrong certificate being served by the endpoint.

Preconditions:

- `openssl` available on the operator workstation.
- Target hostname and port identified.

Procedure:

1. Fetch the certificate chain currently served by the endpoint.

```bash
openssl s_client -connect <hostname>:443 -servername <hostname> -showcerts </dev/null
```

2. Inspect the leaf certificate validity window, issuer, and SAN entries.

```bash
openssl s_client -connect <hostname>:443 -servername <hostname> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName
```

3. Verify that the certificate chain validates for the expected hostname.

```bash
openssl s_client -connect <hostname>:443 -servername <hostname> -verify_return_error </dev/null
```

4. If the served certificate is unexpected, identify the backing Kubernetes Certificate and Secret.

```bash
kubectl get certificate -A
kubectl get ingress,httproute,gateway -A | grep -i <hostname>
```

5. Continue with the matching cert-manager or Secret runbook based on whether the issue is issuance, renewal, or wrong material being presented.

Verify:

- `notBefore` and `notAfter` are valid for the current time.
- SAN contains the requested hostname.
- `Verify return code: 0 (ok)` is returned for a healthy chain.

Rollback:

1. Revert the ingress, Gateway, or Secret reference change if the wrong certificate started serving after a recent deploy.
2. Move to `NET-005` or `NET-008` depending on whether the fault is issuance or certificate selection.

## NET-007 Certificate Renewal Monitoring and Forced Reissuance

<a id="runbook-net-007"></a>
Runbook ID: `NET-007`
Owner: Platform Networking
Severity: `Maintenance` or `SEV-2`

Objective: Confirm cert-manager is renewing certificates before expiry and trigger reissuance when a certificate is stale or a rotation must happen immediately.

Preconditions:

- `kubectl` access to the target cluster.
- Target certificate name and namespace identified.

Procedure:

1. Review cluster-wide certificate readiness and age.

```bash
kubectl get certificate -A
```

2. Watch cert-manager renewal events to confirm normal automatic rotation.

```bash
kubectl get events --all-namespaces --field-selector reason=Renewed
```

3. Inspect the target certificate status and recent cert-manager resources.

```bash
kubectl describe certificate <name> -n <namespace>
kubectl get certificaterequest,order,challenge -n <namespace>
```

4. If immediate reissuance is required, annotate the certificate.

```bash
kubectl annotate certificate <name> \
  -n <namespace> \
  cert-manager.io/issue-temporary-certificate="true"
```

5. Follow issuance progress and confirm the renewed certificate reaches the endpoint.

```bash
kubectl describe certificate <name> -n <namespace>
openssl s_client -connect <hostname>:443 -servername <hostname> </dev/null 2>/dev/null \
  | openssl x509 -noout -dates -serial
```

6. Alert `TLSCertificateExpiringSoon`, `TLSCertificateExpiringCritical` or `TLSCertificateExpired` with
   `target=web-grafana` means the certificate the Envoy gateway serves is old. Compare it with the Secret:

```bash
kubectl get certificate -n envoy-gateway-system pi-cluster-tls -o jsonpath='{.status.notAfter}{"\n"}'
openssl s_client -connect grafana.<domain>:443 -servername grafana.<domain> </dev/null 2>/dev/null \
  | openssl x509 -noout -enddate
```

   Same date: cert-manager did not renew, continue with steps 3–4. Secret newer than the served
   certificate: Envoy did not pick it up. Restart the controller, then the proxy if needed:
   `kubectl -n envoy-gateway-system rollout restart deploy/envoy-gateway`, then
   `kubectl -n envoy-gateway-system rollout restart deploy -l gateway.envoyproxy.io/owning-gateway-name`.

Verify:

- Renewal events appear for the target certificate.
- Certificate condition `Ready=True` after reissuance.
- Endpoint presents the updated serial number or validity window.

Rollback:

1. Remove the temporary annotation if the forced rotation needs to be backed out.

```bash
kubectl annotate certificate <name> -n <namespace> cert-manager.io/issue-temporary-certificate-
```

2. If reissuance still fails, continue with `NET-005` for issuer, solver, or challenge troubleshooting.

## NET-008 TLS Secret and Served Certificate Mismatch

<a id="runbook-net-008"></a>
Runbook ID: `NET-008`
Owner: Platform Networking
Severity: `SEV-2`

Objective: Diagnose cases where cert-manager reports a healthy certificate but the ingress or Gateway serves the wrong, old, or incomplete certificate.

Preconditions:

- `kubectl` and `openssl` available.
- Hostname, namespace, and expected TLS Secret identified.

Procedure:

1. Identify which Certificate and Secret should back the endpoint.

```bash
kubectl get certificate -A
kubectl describe certificate <name> -n <namespace>
kubectl get ingress,httproute,gateway -A | grep -i <hostname>
```

2. Inspect the Secret metadata and certificate material stored in Kubernetes.

```bash
kubectl get secret <secret-name> -n <namespace> -o yaml
kubectl get secret <secret-name> -n <namespace> -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -serial
```

3. Inspect the certificate currently served by the endpoint.

```bash
openssl s_client -connect <hostname>:443 -servername <hostname> </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -serial
```

4. Compare Secret and endpoint serial numbers, issuer, and validity dates.
5. If they differ, restart or reconcile the component serving TLS and verify it still references the intended Secret.

```bash
kubectl describe ingress <name> -n <namespace>
kubectl describe gateway <name> -n <namespace>
flux reconcile kustomization <kustomization-name> -n flux-system --with-source
```

Verify:

- Secret certificate serial matches the served endpoint certificate serial.
- Ingress, Gateway, or Route references the intended Secret name.
- Clients no longer receive the stale or wrong certificate.

Rollback:

1. Restore the previous Secret reference if a manifest change pointed the endpoint at the wrong TLS Secret.
2. If the Secret itself is wrong or stale, continue with `NET-007` for reissuance or `NET-005` for issuance failure triage.

## NET-009 External Let's Encrypt Certificate Renewal (Vault, RustFS, Gateway)

<a id="runbook-net-009"></a>
Runbook ID: `NET-009`
Owner: Platform Networking
Severity: `Maintenance` (alert warning) or `SEV-1` (certificate expired)

Objective: Renew the Let's Encrypt certificates of the services outside the cluster before they expire, or restore service after they have expired. These certificates are issued by certbot inside Ansible playbooks, not by cert-manager, and are **not renewed automatically**. They are valid for 90 days from the last playbook run.

| Endpoint | Renew with | Used by |
| --- | --- | --- |
| `vault.${CLUSTER_DOMAIN}:8200` | `make deploy-vault` | External Secrets, Terraform, `vault` CLI |
| `object-store.${CLUSTER_DOMAIN}:9091` | `make deploy-rustfs` | CNPG WAL archive/backups, Velero, Longhorn backups, Loki, Tempo |
| `gateway.${CLUSTER_DOMAIN}:443` | `make openwrt-certbot-tls` | OpenWrt web UI only |

Triggered by: `TLSCertificateExpiringSoon` (less than 14 days), `TLSCertificateExpiringCritical` (less than 3 days), `TLSCertificateExpired`, or `ExternalEndpointDown` when the cause is the certificate. The alert's `target` label names the endpoint.

Preconditions:

- Shell on the Ansible control node (pimaster) with the repository checked out and up to date (`git pull`).
- Ansible runner available (`make ansible-runner-setup` done once).
- `~/.secrets/ionos-credentials.ini` present (certbot uses the IONOS DNS-01 challenge).
- For the gateway: SSH access from pimaster to host `gateway`.

Procedure:

1. Check which certificates need renewal (from any host):

```bash
for h in vault.homelab.marmilan.com:8200 object-store.homelab.marmilan.com:9091 gateway.homelab.marmilan.com:443; do
  echo "== $h"
  echo | openssl s_client -connect "$h" -servername "${h%:*}" 2>/dev/null | openssl x509 -noout -enddate
done
```

   or in Prometheus: `(probe_ssl_earliest_cert_expiry - time()) / 86400` (days left per `target`).

2. On pimaster, from the repository root, run the target for each endpoint that needs it. Each run waits about 5 minutes for DNS propagation; no output during that wait is normal.

```bash
make deploy-vault          # restarts Vault; the role unseals it again from /etc/vault/unseal.json
make deploy-rustfs         # restarts RustFS; backups pause for a few seconds
make openwrt-certbot-tls   # copies the certificate to the router and restarts uhttpd
```

3. If Vault was renewed after the certificate had expired, make External Secrets retry immediately (node2):

```bash
NOW=$(date +%s)
kubectl annotate clustersecretstore vault-backend force-sync=$NOW --overwrite
kubectl -n flux-system annotate kustomization --all reconcile.fluxcd.io/requestedAt=$NOW --overwrite
```

4. If RustFS was renewed after the certificate had expired, check that CNPG archiving resumed:

```bash
kubectl -n databases get cluster -o custom-columns=NAME:.metadata.name,ARCHIVING:'.status.conditions[?(@.type=="ContinuousArchiving")].status'
```

Verify:

- Step 1 shows an expiry date about 90 days ahead for each renewed endpoint.
- `vault status` on node1 shows `Sealed false`.
- `kubectl get clustersecretstore vault-backend` is `Ready=True`; no Kustomization is blocked on `external-secrets-config`.
- CNPG clusters show `ContinuousArchiving=True`.
- The `TLSCertificate*` alert resolves (ntfy sends a "Resolved" message).

Rollback:

1. Renewal only replaces the certificate and key files and restarts the service; there is nothing to roll back.
2. If Vault is sealed after the restart, unseal it with the keys in `/etc/vault/unseal.json` (see `VAULT-001`).
3. If certbot fails, check the IONOS credentials and the DNS-01 challenge (same failure modes as `NET-005`), then rerun the target.

References:

- `ansible/deploy_vault.yml`, `ansible/deploy_rustfs.yml`, `ansible/generate_gateway_tls_certificate.yml`, `metal/openwrt/script/openwrt-deploy-tls.sh`
- `kubernetes/platform/blackbox-exporter/` (probes and alert rules)
- `postmortems/incident-2026-11-07-letsencrypt-certificates-expired.md`

## NET-010 Web Endpoint Down Through the Gateway

<a id="runbook-net-010"></a>
Runbook ID: `NET-010`
Owner: Platform
Severity: `SEV-2` (one app) or `SEV-1` (all)

Objective: Restore web access when the blackbox probes of the web UIs fail.
Alerts: `WebEndpointDown` (one target), `WebEndpointsAllDown` (every target).

What it means: the blackbox exporter calls Grafana, Keycloak, Prometheus and Threatmap through the Envoy
gateway (`web-*` targets, module `http_reachable`). A redirect to the SSO login or 401/403 counts as up;
connection errors, timeouts and 5xx count as down. Flux can report everything Ready while this fails.

Preconditions:

- `kubectl` on node2.

Procedure:

1. **All down**: the shared path is broken (gateway, Istio, Cilium, DNS). **One down**: that app.
2. Check what changed recently. A merged or automerged update to Envoy Gateway, Istio or Cilium is the
   first suspect.

```bash
git log --oneline --since="1 day ago" --first-parent master
```

3. Gateway and data path:

```bash
kubectl -n envoy-gateway-system get pods
kubectl get gateway -A
kubectl -n istio-system get pods
kubectl -n kube-system get pods -l k8s-app=cilium
kubectl get httproute -A
```

4. One app: its pods and route.

```bash
kubectl get httproute -A | grep <app>
kubectl -n <namespace> get pods
```

5. Probe by hand from inside the cluster (shows the HTTP status the probe sees):

```bash
kubectl run probe-test --rm -it --restart=Never --image=curlimages/curl -- \
  curl -sk -o /dev/null -w '%{http_code}\n' https://grafana.<cluster-domain>/api/health
```

6. If a recent update caused it, revert it (`GITOPS-010`).

Verify:

- Every `web-*` target has `probe_success == 1` in Prometheus; the alert resolves on ntfy.

Rollback:

1. If the fix made things worse, revert it; see `GITOPS-010`.

References:

- `kubernetes/platform/blackbox-exporter/` (targets in the prod overlay, rules in `web-rules.yaml`)
