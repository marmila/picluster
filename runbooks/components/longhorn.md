# Longhorn Storage Runbooks

## LONGHORN-001 Longhorn Volume Degraded or Faulted

<a id="runbook-longhorn-001"></a>
Runbook ID: `LONGHORN-001`
Owner: Platform
Severity: `SEV-1` (faulted), `SEV-3` (degraded)

Objective: Bring a Longhorn volume back to all replicas healthy, or recover the data of a faulted volume.

Alerts: `LonghornVolumeDegraded` (warning, fewer healthy replicas than configured for 30 minutes),
`LonghornVolumeFaulted` (critical, no healthy replica: the workload cannot use the volume). Labels `volume`,
`pvc`, `pvc_namespace` name the volume.

Background: Longhorn keeps each volume as replicas on several nodes (data under `/storage` on each node). A
volume is briefly degraded while a replica rebuilds after a node reboot or drain; that is normal and the
warning waits 30 minutes for it. Longhorn metrics only reach Prometheus because of
`kubernetes/platform/longhorn/app/components/monitor/prometheus-networkpolicy.yaml`: if no Longhorn alert can
fire, check that `ScrapeTargetDown` is not firing for `longhorn-backend`.

Procedure:

1. Find the volume and its replicas (on node2):

```bash
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,NODE:.status.currentNodeID,REPLICAS:.spec.numberOfReplicas | grep -v healthy
kubectl -n longhorn-system get replicas.longhorn.io -l longhornvolume=<volume> -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeID,STATE:.status.currentState,FAILED:.spec.failedAt
kubectl -n longhorn-system get nodes.longhorn.io
```

2. Match the case:

| What you see | Meaning | Go to |
| --- | --- | --- |
| A replica `rebuilding` | Rebuild in progress | Wait; check again in 30 minutes |
| A Longhorn node not ready or not schedulable | Node down, disk full, or `/storage` not mounted | Step 3 |
| Replica `error` / `stopped` on a healthy node | Replica failed | Step 4 |
| Volume `faulted` | Every replica failed | Step 5 |

3. Node problem: check the node (`kubectl get nodes`), its disk (`df -h /storage` on the node) and the
   Longhorn node conditions (`kubectl -n longhorn-system describe nodes.longhorn.io <node>`). Once the node
   is back, Longhorn rebuilds the replica by itself.

4. A failed replica on a healthy node: delete it, Longhorn creates and rebuilds a new one from a healthy
   replica.

```bash
kubectl -n longhorn-system delete replicas.longhorn.io <replica>
```

5. Faulted volume: stop the workload using it (scale to 0), then in the Longhorn UI open the volume and use
   "Salvage" on the most recent replica. If no replica can be salvaged, restore the PVC from the latest Velero
   backup (`BACKUP-001`).

Verify:

- `kubectl -n longhorn-system get volumes.longhorn.io` shows the volume `healthy`.
- `LonghornVolumeDegraded` / `LonghornVolumeFaulted` resolve.

Rollback:

1. Do not delete the last healthy replica of a volume. If a deletion in step 4 leaves no healthy replica,
   stop and restore from backup (`BACKUP-001`).

References:

- `kubernetes/platform/longhorn/app/components/monitor/longhorn-alert-rules.yaml`
- `postmortems/longhorn-snapshot-incident-postmortem.md`
- [Longhorn: volume salvage](https://longhorn.io/docs/latest/advanced-resources/data-recovery/)
