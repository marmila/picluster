# Incident: Envoy Gateway Ingress Outage

## Summary

All ingresses served by Envoy Gateway were returning 500 errors. Protected services (Hubble, Longhorn, Prometheus, Alertmanager) were unreachable due to OIDC validation failures. The root cause was a cascade starting from three stalled Flux HelmReleases that prevented the OTel collector from deploying, which caused the Envoy Gateway to never reach `Accepted` state.

---

## Timeline of Root Causes

### 1. Stalled HelmReleases — Cilium, Loki, Tempo

**Symptom**: `flux-system/cilium-app`, `flux-system/loki-app`, and `flux-system/tempo-app` all in `False` state with:
```
Failed to perform remediation: missing target release for rollback: cannot remediate failed release
```

**Cause**: Each HelmRelease failed on its first install attempt. Flux tried to remediate by rolling back but there was no previous release to roll back to (`MissingRollbackTarget`). Flux stopped retrying. All pods were actually running — Flux just didn't know it.

**Fix**: Suspend and resume each HelmRelease to clear the stalled state:
```bash
kubectl patch helmrelease -n tempo tempo --type=merge -p '{"spec":{"suspend":true}}'
kubectl patch helmrelease -n loki loki --type=merge -p '{"spec":{"suspend":true}}'
kubectl patch helmrelease -n kube-system cilium --type=merge -p '{"spec":{"suspend":true}}'

kubectl patch helmrelease -n tempo tempo --type=merge -p '{"spec":{"suspend":false}}'
kubectl patch helmrelease -n loki loki --type=merge -p '{"spec":{"suspend":false}}'
kubectl patch helmrelease -n kube-system cilium --type=merge -p '{"spec":{"suspend":false}}'
```

---

### 2. OTel Collector Not Deployed

**Symptom**: `No resources found in otel namespace`. `opentelemetry-collector-app` kustomization stuck with:
```
dependency 'flux-system/tempo-app' is not ready
```

**Cause**: `opentelemetry-collector-app` depends on `tempo-app` and `loki-app`. Both were stalled (see above), so Flux never reconciled the OTel collector.

**Fix**: Resolved automatically once Tempo and Loki HelmReleases were cleared.

---

### 3. Envoy Gateway Not Accepted — Missing OTel Service

**Symptom**: `kubectl get gateway -n envoy-gateway-system public-gateway` showed empty `ADDRESS` and `PROGRAMMED` columns. Gateway status:
```
Message: Invalid access log backendRefs in the referenced EnvoyProxy: service otel/otel-collector not found
Reason:  InvalidParameters
Status:  False
Type:    Accepted
```

**Cause**: The prod overlay at `kubernetes/platform/envoy-gateway/config/overlays/prod/kustomization.yaml` includes the `opentelemetry` component, which patches the `EnvoyProxy` to send access logs, traces, and metrics to `otel/otel-collector:4317`. Because the OTel collector was not deployed, the EnvoyProxy referenced a non-existent service, and Envoy Gateway refused to mark the Gateway as `Accepted`.

**Fix**: Resolved automatically once the OTel collector deployed.

---

### 4. ExternalDNS Generating Empty Endpoints

**Symptom**: ExternalDNS logs showing:
```
Endpoints generated from HTTPRoute keycloak/keycloak: []
Endpoints generated from HTTPRoute kube-system/hubble: []
...
```
No DNS records written to Bind9 at `10.0.0.11`.

**Cause**: ExternalDNS generates DNS records for Gateway HTTPRoutes by reading `gateway.status.addresses`. Because the Gateway was not `Accepted`, Envoy Gateway never populated `status.addresses`, so ExternalDNS had no IP to write.

**Fix**: Resolved automatically once the Gateway became `Accepted`.

---

### 5. OIDC / SecurityPolicy Failures — All Protected Routes Return 500

**Symptom**: Envoy Gateway logs:
```
setting 500 direct response in routes due to errors in SecurityPolicy
error: OIDC: Get "https://iam.homelab.marmilan.com/realms/picluster/.well-known/openid-configuration":
       dial tcp: lookup iam.homelab.marmilan.com on 10.43.0.10:53: no such host
```
Affected: Hubble, Longhorn, Prometheus, Alertmanager.

**Cause**: `iam.homelab.marmilan.com` had no DNS record in Bind9 (see cause 4 above). CoreDNS (10.43.0.10) forwarded the query to the node's `/etc/resolv.conf` resolver which also could not resolve it. Envoy Gateway's SecurityPolicy controller fetches the Keycloak OIDC discovery document at startup to validate OIDC configuration. Without DNS resolution, this fetch failed and the controller set a 500 response on all routes protected by those SecurityPolicies.

**Fix**: Resolved automatically once ExternalDNS wrote the DNS records.

---

### 6. Kiali Cannot Reach Prometheus or Grafana

**Symptom**: Kiali reporting connection errors to Prometheus and Grafana.

**Cause**: Wrong URLs in `kubernetes/platform/kiali/app/base/values.yaml`:

| Field | Wrong | Correct |
|---|---|---|
| `prometheus.url` | `http://kube-prometheus-stack-prometheus.kube-prom-stack:9090/prometheus/` | `http://kube-prometheus-stack-prometheus.kube-prom-stack.svc.cluster.local:9090` |
| `grafana.in_cluster_url` | `http://grafana.grafana.svc.cluster.local/grafana/` | `http://grafana-service.grafana.svc.cluster.local:3000` |

Prometheus is not configured with `--web.route-prefix=/prometheus/` and Grafana is not configured with `serve_from_sub_path=true`, so neither serves from a subpath. The service name `grafana` also does not exist — the Grafana operator creates it as `grafana-service`.

**Fix**: Updated `kubernetes/platform/kiali/app/base/values.yaml` with correct URLs.

---

## Cascade Summary

```
Cilium/Loki/Tempo HelmReleases stalled (MissingRollbackTarget)
  └─ opentelemetry-collector-app blocked by failed dependencies
       └─ otel/otel-collector service never created
            └─ EnvoyProxy references missing service → Gateway not Accepted
                 └─ gateway.status.addresses empty
                      └─ ExternalDNS generates [] for all HTTPRoutes
                           └─ No DNS records in Bind9
                                └─ iam.homelab.marmilan.com → NXDOMAIN
                                     └─ SecurityPolicy OIDC fetch fails → 500 on all protected routes
```

---

### 7. Fluent Bit CrashLoopBackOff on node5 and node6

**Symptom**: `fluent-bit` pods on node5 and node6 in `CrashLoopBackOff` with 100-400+ restarts. Liveness probe repeatedly failing with `context deadline exceeded` on `http://:2020/`.

**Cause**: A chain of three compounding issues:

1. **Wrong syslog parser**: `input.host` was configured with `parser: syslog-rfc3164-nopri` which expects `May 23 06:01:38` format. All nodes write ISO 8601 format (`2026-05-23T06:01:38+00:00`). Every host log line generated two internal error/warn messages. This did not crash other nodes because their event loop could absorb it, but it contributed to CPU pressure.

2. **Storage backlog spiral**: node5 and node6 had accumulated a massive filesystem backlog in `/var/log/fluentbit/storage/` from a prior OOMKill event (before memory limits were set). On every restart, Fluent Bit replayed the entire backlog, saturating the event loop. The HTTP health server at `:2020` became unresponsive, the liveness probe timed out, the pod was killed, and the cycle repeated — each crash adding more backlog.

3. **Wrong file edited**: All parser fix attempts were applied to `components/forwarding/fluent-bit-config.yaml`. The prod overlay (`overlays/prod/kustomization.yaml`) uses `components/aggregator`, not `components/forwarding`. None of the fixes landed in the cluster until the correct file was identified.

**Why other nodes were unaffected**: They never had the initial OOMKill that seeded the backlog, so the parse error CPU pressure never pushed them into the liveness probe failure spiral.

**Fix**:
1. Added `syslog-iso8601` parser to `kubernetes/platform/fluent/fluent-bit/components/aggregator/fluent-bit-config.yaml` and updated `input.host` to use it
2. Added `mem_buf_limit: 50MB` (kube input) and `mem_buf_limit: 10MB` (host input) to the same file
3. Manually cleared storage backlog on node5 and node6:
```bash
kubectl debug node/node5 -it --image=busybox -- sh -c "rm -rf /host/var/log/fluentbit/storage/* /host/var/log/fluentbit/flb_kube.db /host/var/log/fluentbit/flb_host.db"
kubectl debug node/node6 -it --image=busybox -- sh -c "rm -rf /host/var/log/fluentbit/storage/* /host/var/log/fluentbit/flb_kube.db /host/var/log/fluentbit/flb_host.db"
```
4. Deleted pods to force clean restart

Also fixed a pre-existing bad merge in `kubernetes/platform/fluent/fluent-bit/base/values.yaml` that had introduced a duplicate `config:` key and an erroneous active `env:` block. Restored to match upstream.

---

## Open Issues at Time of Writing

- **Kafka certificate** (`kafka/kafka-cert`): DNS-01 challenge for `kafka-broker-*.homelab.marmilan.com` failing propagation check. Likely caused by NS delegation for `homelab.marmilan.com` in IONOS pointing to internal Bind9 at `10.0.0.11`, which does not have the `_acme-challenge` TXT records created by the IONOS webhook. Needs investigation of IONOS DNS delegation vs cert-manager webhook behavior.

- **Hubble UI** (`service kube-system/hubble-ui not found`): Cilium HelmRelease was stalled before Hubble UI values were fully applied. Verify Hubble UI pods are running after Cilium reconciliation.
