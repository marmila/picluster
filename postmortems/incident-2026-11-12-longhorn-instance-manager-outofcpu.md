# Incident: Elasticsearch down, Longhorn instance-manager could not be scheduled on node-esp-2
**Date:** 2026-11-12  
**Duration:** Elasticsearch volume stuck attaching from about 10:20 UTC (inferred) to about 18:25 UTC. Found at about 17:50 UTC.  
**Impact:** Elasticsearch and Kibana unavailable for about 8 hours: no log search, no new log indexing to Elasticsearch.
`config-elastic` (tofu-controller) failed every run, so `elastic-stack-config` was not ready. No data was lost: two
of the three volume replicas stayed healthy the whole time.

---

## Summary

Longhorn 1.13.0 was merged on 2026-11-11 (PR #977). Longhorn started a new v1.13.0 instance-manager on every node.
The old instance-managers stayed, because automatic engine upgrade was off
(`concurrent-automatic-engine-upgrade-per-node-limit = 0`) and every volume still ran an old engine (v1.12.0 or
v1.12.1). Each instance-manager reserves 12% of the node's CPU, 480m on a 4-core node.

node-esp-2 was already at 3906m of 4000m CPU requests. The new instance-manager pod was rejected by the kubelet with
`OutOfcpu` and its CR went to `error`. Volumes already running there were not affected. When the Elasticsearch pod
restarted, its volume had to start its engine on the new instance-manager, which did not exist, so the volume stayed
`attaching` forever. The pod stayed in `Init:0/2`.

`config-elastic` first showed a stuck state lock (fixed with GITOPS-007), and then
`error running Plan: ... exit status 1`. The real error, cut off in `kubectl get terraform`, was
`dial tcp ...:9200: i/o timeout` and `...:5601: connect: connection timed out`: Elasticsearch and Kibana were down.
The Terraform module itself was fine.

The same CPU shortage on node-esp-2 had already blocked a second instance-manager in September 2026 (after the UPS
outage).

---

## Timeline

Times are UTC. "Inferred" means reconstructed from object ages, not observed.

| Time | Event |
|------|-------|
| 2026-11-11 17:49 | Longhorn 1.13.0 merged (PR #977, `e9056cac`) |
| 2026-11-11 ~19:00 | New v1.13.0 instance-managers created on every node (inferred: 23h old at 18:00 next day). The one on node-esp-2 (`instance-manager-56036cf5…`) cannot be scheduled: `OutOfcpu`, requested 480m, used 3906m of 4000m |
| 2026-11-12 ~10:20 | Elasticsearch volume `pvc-a6e3a543…` starts waiting to attach to node-esp-2 (inferred: VolumeAttachment 7h37m old at 17:58). Elasticsearch down from here |
| 2026-11-12 (before 17:50) | `config-elastic` found with a stuck state lock. Force-unlocked with GITOPS-007 |
| 2026-11-12 ~17:31 | `efk-es-default-0` re-created, stays `Init:0/2`. `FailedAttachVolume: DeadlineExceeded` every 2 minutes |
| 2026-11-12 17:54 | `config-elastic` plan errors read in full: Elasticsearch `:9200` and Kibana `:5601` time out |
| 2026-11-12 ~17:58 | Volume `attaching`, robustness `unknown`, engine `stopped`. longhorn-manager: `invalid instance manager instance-manager-56036cf5…, state error` |
| 2026-11-12 ~18:15 | node-esp-2 cordoned, descheduler pod (500m) moved off it, errored instance-manager CR deleted. The new one did not start while the node was cordoned |
| 2026-11-12 ~18:20 | Node uncordoned. New instance-manager (v1.13.0) Running. Volume `attached`, `degraded` while the third replica rebuilt on node6 |
| 2026-11-12 ~18:30 | `efk-es-default-0` Ready. Kibana restarted (it had been unready for 5 days). `config-elastic` reconciled again |
| 2026-11-12 ~18:45 | Fix for the cause on master (`efc59eaf`): `concurrentAutomaticEngineUpgradePerNodeLimit: 1`. Within minutes 13 of 14 engines on v1.13.0; node6's old instance-manager removed |
| 2026-11-12 ~19:00 | `config-elastic` and `config-keycloak` `Ready=True`. Kibana green. Elasticsearch still red: 20 small system-index primaries `CLUSTER_RECOVERED`, recovering one at a time while the volume rebuilds its third replica on node6 |
| 2026-11-12 | descheduler and schema-registry CPU requests lowered (`b079075b`) |

---

## Root Causes

### Primary: old engines kept the old instance-managers alive after the Longhorn upgrade

With `concurrent-automatic-engine-upgrade-per-node-limit = 0`, Longhorn never moves volumes to the new engine image.
In this cluster volumes were still on v1.12.0, the version before the August 1.12.1 upgrade. Every Longhorn upgrade
leaves the old instance-manager running next to the new one, and each reserves 12% of node CPU. Any volume that
restarts uses the new instance-manager.

**Fix applied:** `concurrentAutomaticEngineUpgradePerNodeLimit: 1` in
`kubernetes/platform/longhorn/app/base/values.yaml` (`efc59eaf`). Longhorn upgrades engines live, one volume per node at
a time. When an old instance-manager has nothing left to run, it is removed.

### Primary: node-esp-2 has no CPU headroom

node-esp-2 (4 vCPU) is at 97% CPU requests. Instance-manager pods are bound to the node directly (`nodeName`), so the
scheduler cannot preempt anything for them: the kubelet just rejects them with `OutOfcpu`. Two pods with large requests
and no PVC run there: `descheduler` (500m) and `schema-registry` (500m).

**No fix yet.** Moving the descheduler freed enough for today only. See actions.

### Contributing: the errors pointed at the wrong component

- `kubectl get terraform` cuts the message at `exit status 1...`. It looks the same for a lock, a module bug or a
  dependency that is down. GITOPS-007 had no step that prints the full error and no case for "dependency down".
- The volume was `attaching` with robustness `unknown`, not `degraded` or `faulted`, so `LonghornVolumeDegraded` and
  `LonghornVolumeFaulted` did not fire. There is no alert for Elasticsearch being down or Kibana being unready (Kibana
  was unready for 5 days before this incident).
- No `flux` CLI on node2, so runbook commands using it could not be run as written.

---

## What went well

- The full Terraform error led straight from tofu to Elasticsearch, and the pod events to Longhorn.
- The cause matched the September 2026 notes (instance-manager `OutOfcpu` on node-esp-2), so the fix was known.
- No data loss: two replicas stayed `running` throughout.

## What went poorly

- Elasticsearch was down for about 8 hours before anyone noticed, and only through the Terraform resource.
- The Longhorn upgrade was applied without checking that each node could fit a second instance-manager.
- Cordoning the node stopped the new instance-manager from starting, which cost one extra round.
- GITOPS-007 uses placeholders (`<name>`) and assumes a lock. Too many round trips to get the real error.

---

## Actions to prevent recurrence

| # | Action | Status |
|---|---|---|
| 1 | Enable automatic engine upgrade (`concurrentAutomaticEngineUpgradePerNodeLimit: 1`) | Done (`efc59eaf`). Last engine (Elasticsearch volume) upgrades once its rebuild finishes; then one instance-manager per node |
| 2 | Free CPU requests on node-esp-2: lower the `descheduler` and `schema-registry` requests (500m each; measured 3m and 8m) | Done (`b079075b`: 50m and 100m) |
| 3 | Alert when a Longhorn volume is stuck `attaching` or an instance-manager is in `error` | Done: `LonghornVolumeStuckAttaching`, `LonghornInstanceManagerNotRunning` (kube-state-metrics `longhorn_crd_instance_manager_info`) |
| 4 | Alert when Elasticsearch is not green or Kibana is unready for more than 15 minutes | Done: `ElasticsearchNotHealthy`. Kibana: the mixin alert `KubeDeploymentReplicasMismatch` already covers `efk-kb` |
| 5 | Rewrite GITOPS-007: one `TF=` variable line, a step that prints the full error, a table by error text including "dependency down" | Done. ELASTIC-001 rewritten the same way (commands through the pod, cases from this incident) |
| 6 | New runbook LONGHORN-002: volume stuck attaching / instance-manager `OutOfcpu`, with the commands used here. Do not cordon the node while waiting for the instance-manager | Done |
| 7 | Longhorn upgrade checklist in `homelab-docs/update-automation.md`: check CPU headroom (≥ 500m free per node) before, and instance-managers and engine images after | Done |
| 8 | Install the `flux` CLI on node2 (version from `fluxcd_version`) | Done: `make admin-cli` (`ansible/install_admin_cli.yml`). The old shared task ignored the pinned version (the variable reached `curl`, not the install script) and now installs exactly `fluxcd_version` with a checksum check |

## Open questions

- Why did the Elasticsearch pod restart at about 10:20? Candidates: the descheduler evicting it, or ECK rolling the
  pod. Check `kubectl -n kube-system logs deploy/descheduler` and ECK operator logs if they still cover that time.
- Why was the `config-elastic` state lock left behind this time? Probably a runner killed while Elasticsearch was
  unreachable, not confirmed.
- Was there an alert at all? `TerraformNotReady` should have fired; check ntfy history.

---

## Quick health check

On node2:

```bash
kubectl -n longhorn-system get instancemanagers.longhorn.io -o wide
kubectl -n longhorn-system get engines.longhorn.io -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' | sort | uniq -c
kubectl describe node node-esp-2 | grep -A5 "Allocated resources" | grep cpu
kubectl -n elastic get elasticsearch,kibana
```

Healthy: one `running` instance-manager per node, all engines on the current Longhorn version, node-esp-2 below
about 85% CPU requests, Elasticsearch `green` and Kibana `green`.
