# Incident: Fluent Bit Continuous Restarts on node5/node6

**Date:** 2026-06-11 → 2026-06-13  
**Nodes affected:** node5 (10.0.0.15), node6 (10.0.0.16)  
**Severity:** High — logging pipeline degraded on the cluster's heaviest nodes  
**Status:** Fixed

---

## Symptoms

```
fluent-bit-k4vxk   node5   144 restarts in 35h
fluent-bit-gn5zd   node6    53 restarts in 35h
```

All other nodes (node2, node3, node4, node-esp-1, node-esp-2): 0–2 restarts.

Kubelet events on both pods:
```
Liveness probe failed: Get "http://10.42.6.31:2020/": context deadline exceeded
Readiness probe failed: Get "http://10.42.6.31:2020/api/v2/health": context deadline exceeded
Container fluent-bit failed liveness probe, will be restarted
```

---

## Diagnosis

### What the evidence ruled out

- **Not OOM**: exit code on node6 was `0` (clean exit); no memory pressure events on either node.
- **Not output errors**: metrics showed `fluentbit_output_errors_total = 0`, zero dropped records, zero storage backlog.
- **Not storage I/O**: metrics showed `storage_backlog = 0`; storage was healthy.
- **Not network**: Fluent Bit logs confirmed Fluentd connectivity OK at startup; zero forward errors.

### Root cause

The Fluent Bit process was alive but its HTTP server was unresponsive during periodic CPU saturation spikes. The liveness probe (`timeoutSeconds: 5`, `failureThreshold: 5`) killed the container after 50 seconds of unresponsiveness.

node5 and node6 run the cluster's most log-heavy stateful workloads:

- Kafka (`cluster-dual-role-2`)
- Loki backend, write, canary, read
- Tempo ingester
- Keycloak DB
- Longhorn manager, CSI plugin, instance-manager

During log bursts from these services, Fluent Bit's single-threaded event loop saturated on ARM hardware. Two config settings made it worse:

1. **`flush: 1`** — the event loop ran every second with no batching relief, hammering the pipeline with TLS flushes to Fluentd even during spikes.
2. **`multiline filter: match: '*'`** — the Go/Java/Python multiline parser was applied to host syslog and auth.log records too, wasting CPU on every host log record.

When the event loop saturated, the internal HTTP server stopped responding to the liveness probe within the 5s timeout.

---

## Fix

Three changes applied to [components/aggregator/fluent-bit-config.yaml](kubernetes/platform/fluent/fluent-bit/components/aggregator/fluent-bit-config.yaml) and [overlays/prod/values.yaml](kubernetes/platform/fluent/fluent-bit/overlays/prod/values.yaml):

### 1. Increase flush interval
```yaml
# before
flush: 1
# after
flush: 5
```
Gives the event loop 5x more breathing room between flush cycles. Reduces TLS connection overhead and storage write frequency.

### 2. Restrict multiline filter to kube logs
```yaml
# before
- name: multiline
  match: '*'
# after
- name: multiline
  match: 'kube.*'
```
Host logs (syslog, auth.log) do not contain Go/Java/Python stack traces. Running the multiline parser on them was pure CPU waste on every record.

### 3. Relax liveness probe
```yaml
# before
timeoutSeconds: 5
failureThreshold: 5
# after
timeoutSeconds: 15
failureThreshold: 10
```
Tolerates up to ~2.5 minutes of probe failure before killing the container. This does not mask real crashes — it stops false-positive kills during transient load spikes.

---

## How to diagnose a recurrence

**1. Confirm the probe is timing out, not failing with an error code:**
```bash
kubectl describe pod <fluent-bit-pod> -n fluent | grep -A 5 "Unhealthy"
# "context deadline exceeded" = timeout = event loop blocked
# "dial tcp ... connection refused" = process crashed
# "HTTP 500" = Fluent Bit health check failed (output errors)
```

**2. Check previous container logs for errors:**
```bash
kubectl logs <pod> -n fluent -c fluent-bit --previous --tail=100
```
If there are no `[error]` lines, the process was healthy internally — it's a CPU saturation issue.

**3. Check output and storage metrics while pod is running:**
```bash
kubectl port-forward -n fluent <pod> 2020:2020 &
curl -s http://localhost:2020/api/v2/metrics | grep -E "output_errors|retry|storage_backlog|dropped"
```
All zeros = not an output/storage problem.

**4. Check what's running on the affected node:**
```bash
kubectl get pods -A --field-selector spec.nodeName=<node> | wc -l
```
High pod count with log-heavy workloads (Kafka, Loki, Tempo) is the signal.

---

## Notes

- The probe relaxation is global (affects all nodes). This is intentional — the tighter values were too aggressive for any node under load.
- If restarts resume after this fix, the next step is adding `workers: 2` to the forward output plugin to move TLS I/O off the main event loop entirely.
- node4 had 2–4 restarts (minor) likely from the same cause at lower frequency.
