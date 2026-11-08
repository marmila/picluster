# Incident: node-esp-2 root disk full (DiskPressure) during a package update
**Date:** 2026-11-07  
**Duration:** DiskPressure on node-esp-2 seen about 15:20 UTC, cleared after the journal was trimmed later that afternoon. node-esp-1 was close behind (83%) and was trimmed later that afternoon.  
**Impact:** The kubelet on node-esp-2 tainted the node `disk-pressure:NoSchedule` and evicted the new fluent-bit pod, so the fluent-bit HelmRelease upgrade (DaemonSet rollout) timed out and failed. Logs from node-esp-2 were not collected while fluent-bit was missing. No other workload was evicted and no data was lost.

---

## Summary

A batch of upstream version bumps (kube-prometheus-stack 92.17, Elasticsearch 8.19.23, Keycloak 26.8.1, fluent-bit 5.1.3, Velero 12.2.2 and others) pulled new container images onto every node. The x86 workers node-esp-1 and node-esp-2 have a 50G root LV that holds the container images (`/var/lib/rancher/k3s/agent/containerd`, 23G on node-esp-2) and the logs. The systemd journal had no size limit and had grown to 3.9G.

node-esp-2's root disk reached 84.8%. The kubelet's default eviction threshold (`imagefs.available<15%`, images live on the root disk) put the node into DiskPressure. The kubelet's default image garbage collection also only starts at 85%, so it could not help before eviction started.

No alert fired. The mixin filesystem alerts only fire at 5% and 3% free, and `KubeNodePressure` is severity `info`, which Alertmanager does not route.

`journalctl --vacuum-size=500M` freed 3.4G (84.8% → 77%) and DiskPressure cleared. fluent-bit was then re-rolled successfully.

---

## Timeline

All times UTC.

| Time | Event |
|---|---|
| Afternoon | Flux starts rolling out the upstream version bumps. Image pulls are slow on all nodes |
| 15:21 | The new fluent-bit pod on node-esp-2 is `Evicted` 13s after creation. The fluent-bit HelmRelease waits for the DaemonSet |
| 15:22 | node-esp-2: `DiskPressure=True`, taint `node.kubernetes.io/disk-pressure:NoSchedule`. Root disk 84.8%; node-esp-1 82.9% |
| 15:23 | On node-esp-2: containerd 23G, `/var/log` 4.5G, Longhorn 255M on root. `crictl rmi --prune` frees nothing |
| After 15:23 | Volume group has no free extents (rest of the disk is the 413G `/storage` LV for Longhorn), so the root LV cannot be grown. Journal found at 3.9G |
| Later | `journalctl --vacuum-size=500M` frees 3.4G, root disk 77% |
| Later | DiskPressure cleared, fluent-bit HelmRelease re-run; by about 16:50 every HelmRelease is Ready |
| ~16:50 | Same vacuum on node-esp-1 (done before this time) |

---

## Root Causes

### Primary: image cleanup starts at the eviction threshold

The kubelet defaults are `imageGCHighThresholdPercent: 85` and eviction at `imagefs.available<15%`, which is the same point. Unused images were only deleted once pods were already being evicted. With several large images pulled at once, there was no margin.

**Fix:** `imageGCHighThresholdPercent: 70`, `imageGCLowThresholdPercent: 60` in `k3s_kubelet_config`.

### Primary: no journal size limit

journald's default limit is 10% of the filesystem, capped at 4G. On a 50G root disk that is almost 4G of logs. It filled up over the three months since the rebuild.

**Fix:** `SystemMaxUse=500M` on every node (`basic_setup/tasks/journald.yml`).

### Contributing: no disk alert before eviction

The only root disk alerts fired at 95% and 97%, and the node pressure alert is not routed. The first sign was a failed HelmRelease.

**Fix:** `NodeRootDiskFillingUp` (80%, warning) and `KubeNodeDiskPressure` (critical), runbook `CLUSTER-012`.

### Contributing: `crictl rmi --prune` freed nothing

The old image versions were still referenced by exited containers, so `crictl` kept them. Only the journal could be freed quickly.

---

## What went well

- The eviction message pointed straight at the node condition, so the disk was found within minutes.
- Checking `du` per directory and the volume group layout ruled out the quick but wrong fixes (growing the LV, touching Longhorn's `/storage`).
- The journal vacuum was enough and needed no restart.

## What went poorly

- Image GC settings were never set: the kubelet defaults assume a dedicated image disk.
- node-esp-1 was at 83% at the same time and was only trimmed an hour later.
- The fluent-bit HelmRelease failure showed up before any disk warning.

---

## Actions to prevent recurrence

| # | Action | Status |
|---|---|---|
| 1 | Image GC from 70% down to 60% (`k3s_kubelet_config`) | Done (feature/node-disk-hygiene) |
| 2 | Journal limit `SystemMaxUse=500M` on all nodes (`basic_setup`) | Done (feature/node-disk-hygiene) |
| 3 | `make node-config-update` to apply 1 and 2 to running nodes, one node at a time | Done (feature/node-disk-hygiene), to run once after merge |
| 4 | Alerts `NodeRootDiskFillingUp` and `KubeNodeDiskPressure` with runbook `CLUSTER-012` | Done (feature/node-disk-hygiene) |
| 5 | Rewrite runbook `CLUSTER-012` with the steps used here | Done (feature/node-disk-hygiene) |

---

## Quick check

On node2:

```bash
kubectl get nodes -o custom-columns=NAME:.metadata.name,DISK:'.status.conditions[?(@.type=="DiskPressure")].status'
```

On a node:

```bash
df -h /; sudo journalctl --disk-usage; grep -i imageGC /etc/rancher/k3s/kubelet.config
```
