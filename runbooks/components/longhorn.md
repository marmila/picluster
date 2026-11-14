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
| Volume `attaching` for minutes, pod stuck in `Init` | Not a replica problem: the volume cannot attach | `LONGHORN-002` |

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

## LONGHORN-002 Volume Stuck Attaching (Instance-Manager Not Running)

<a id="runbook-longhorn-002"></a>
Runbook ID: `LONGHORN-002`
Owner: Platform
Severity: `SEV-2`

Objective: Get a volume that stays `attaching` attached again, so the pod using it can start.

Alerts: `LonghornVolumeStuckAttaching` (critical, volume `attaching` for 15 minutes; label `volume`,
`pvc`, `pvc_namespace`), `LonghornInstanceManagerNotRunning` (warning, an instance-manager not `running` for
15 minutes; labels `name`, `node`, `state`). Often seen first as something else: a pod stuck in `Init` with
`FailedAttachVolume ... DeadlineExceeded` events, or a service that depends on it failing (on 2026-11-12:
Elasticsearch down, then `config-elastic` Terraform errors).

Background: a volume's engine runs inside the Longhorn **instance-manager** of the node where the pod runs.
Each instance-manager reserves `guaranteed-instance-manager-cpu` (12%: 480m on a 4-core node). After a
Longhorn upgrade every node runs a second, new instance-manager next to the old one until all volumes are
on the new engine (`concurrentAutomaticEngineUpgradePerNodeLimit: 1` in
`kubernetes/platform/longhorn/app/base/values.yaml` does that within about an hour). Instance-manager pods
are bound to their node directly, so nothing gets preempted for them: if the node has no CPU left to
request, the kubelet rejects the pod with `OutOfcpu` and the instance-manager stays in `error`. Volumes
already running are fine; the next volume that starts on that node cannot attach. node-esp-2 (4 vCPU,
around 90% requested) has hit this twice: September 2026 and 2026-11-12.

Preconditions:

- `kubectl` on node2.
- Never delete the volume, the PVC or its replicas to "unstick" it: that is the data.

Procedure:

1. Find the stuck volume, its node, and the instance-managers that are not running:

```bash
echo "=== volumes attaching ==="
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,NODE:.status.ownerID,PVC:.status.kubernetesStatus.pvcName | grep -E "^NAME|attaching"
echo "=== instance-managers not running ==="
kubectl -n longhorn-system get instancemanagers.longhorn.io -o wide | grep -v " running "
echo "=== why (OutOfcpu = no CPU room on the node) ==="
kubectl -n longhorn-system get events --sort-by=.lastTimestamp | grep -E "instance-manager" | grep -vE "Pulled|Pulling|Created|Started" | tail -5
echo "=== CPU requested per node ==="
for n in $(kubectl get nodes -o name); do echo "${n#node/}: $(kubectl describe $n | grep -A5 'Allocated resources' | grep -E '^ +cpu' | awk '{print $2, $3}')"; done
echo "=== engines per version (old engines keep old instance-managers alive) ==="
kubectl -n longhorn-system get engines.longhorn.io -o jsonpath='{range .items[*]}{.spec.image}{"\n"}{end}' | sort | uniq -c
```

2. Set the node from step 1 (column `NODE` of the stuck volume, or `NODE` of the instance-manager):

```bash
NODE=node-esp-2
```

3. Match the case:

| Step 1 shows | Meaning | Go to |
| --- | --- | --- |
| Instance-manager on `$NODE` in `error`, events say `OutOfcpu` | No CPU room for it | Step 4, then step 5 |
| Instance-manager in `error`, other reason (image pull, crash) | Instance-manager broken | Step 5; if it comes back in `error`, check `kubectl -n longhorn-system describe pod <instance-manager pod>` |
| All instance-managers `running`, volume still `attaching` | longhorn-manager lost track | Step 6 |
| Volume `faulted`, or replicas not `running` | Replica problem, not attach | `LONGHORN-001` |

4. Free CPU on `$NODE`. List the pods that can move (Deployment, no PVC) with their CPU request:

```bash
kubectl get pods -A --field-selector spec.nodeName=$NODE -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,CPU:.spec.containers[*].resources.requests.cpu,PVC:.spec.volumes[*].persistentVolumeClaim.claimName,OWNER:.metadata.ownerReferences[0].kind' | awk 'NR==1 || ($4=="<none>" && $5=="ReplicaSet")'
```

   Delete one or more of them until the requests freed add up to at least 500m. Good candidates have a large
   request and are not user-facing (on 2026-11-12: `descheduler`, now 50m after the fix). Copy the
   namespace and name from the list:

```bash
kubectl -n kube-system delete pod descheduler-868ddf8dc8-fjp6p      # example: use a pod from the list
```

   Do **not** cordon the node. Cordoning keeps the freed room, but it also stopped the new instance-manager
   from starting on 2026-11-12.

5. Recreate the instance-manager that is in `error` and wait until all on `$NODE` are `running` (up to 5
   minutes). One paste:

```bash
for IM in $(kubectl -n longhorn-system get instancemanagers.longhorn.io -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.nodeID}{" "}{.status.currentState}{"\n"}{end}' | awk -v n="$NODE" '$2==n && $3=="error" {print $1}'); do kubectl -n longhorn-system delete instancemanagers.longhorn.io $IM; done
sleep 30
timeout 300 bash -c "while kubectl -n longhorn-system get instancemanagers.longhorn.io -o wide | grep ' $NODE ' | grep -qv ' running '; do echo waiting...; sleep 10; done" && echo "INSTANCE-MANAGERS RUNNING" || echo "STILL NOT RUNNING: run step 1 again"
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness,NODE:.status.ownerID | grep -E "^NAME| $NODE"
```

   Deleting an instance-manager in `error` is safe: it has no pod and runs nothing. Longhorn creates it again
   at once. Never delete one in `running`: every volume on that node would stop.

6. Instance-managers running but the volume still `attaching` after 5 minutes: restart longhorn-manager on
   the node (it runs no volumes; the volumes keep running):

```bash
kubectl -n longhorn-system delete pod -l app=longhorn-manager --field-selector spec.nodeName=$NODE
```

7. The volume shows `attached`, usually `degraded` while a replica rebuilds. The pod using it now starts.
   Restart what depended on it if it does not recover by itself (on 2026-11-12: Kibana, then
   `config-elastic` with `GITOPS-007` step 6).

Verify:

- `kubectl -n longhorn-system get volumes.longhorn.io` shows the volume `attached`; `healthy` once the
  rebuild ends.
- `kubectl -n longhorn-system get instancemanagers.longhorn.io -o wide`: all `running`. Once the engine
  upgrade has finished, one per node.
- Node CPU requests below about 85% (step 1), so the next Longhorn upgrade fits.
- `LonghornVolumeStuckAttaching` and `LonghornInstanceManagerNotRunning` resolve.

Rollback:

1. Nothing to roll back: only pods were moved. The moved pod runs on another node.

References:

- `postmortems/incident-2026-11-12-longhorn-instance-manager-outofcpu.md`
- `kubernetes/platform/longhorn/app/components/monitor/longhorn-alert-rules.yaml`
- `homelab-docs/update-automation.md` (Longhorn upgrades: check CPU room first)

## LONGHORN-003 Snapshot Cleanup Job Failed or Snapshots Piling Up

<a id="runbook-longhorn-003"></a>
Runbook ID: `LONGHORN-003`
Owner: Platform
Severity: `SEV-3`

Objective: Keep Longhorn volumes free of old backup snapshots, so replica rebuilds stay short and disks keep
their space.

Alerts: `KubeJobFailed` with `job_name` `longhorn-snapshot-cleanup-*` (or a manual `snapshot-cleanup-*` job) in
`longhorn-system`. Also seen as very slow rebuilds after a node reboot (`LONGHORN-001`), or a volume whose
`actualSize` is far above its size.

Background: the Velero `full` backup (02:00) takes a CSI snapshot of type `bak` of every PVC: Longhorn
snapshots the volume and uploads it to RustFS. Since 2026-11-14 the Longhorn setting
`autoCleanupSnapshotAfterOnDemandBackupCompleted: true` deletes that local snapshot as soon as the upload
finishes. The CronJob `longhorn-snapshot-cleanup` (03:30) is the fallback: it deletes snapshots older than
`RETAIN_DAYS` (3), then **purges** every volume that has removed snapshots, one volume at a time (deleting only
marks a snapshot; the purge frees the space, and Longhorn runs at most 5 purges at once). It fails when an API
call fails, a purge reports an error, or one volume purges for more than 2 hours. Before the fix, Prometheus
carried 110 GB of snapshots on a 50 GB volume and every rebuild copied them.

Procedure:

1. Read why the job failed (on node2):

```bash
JOB=$(kubectl -n longhorn-system get jobs --sort-by=.metadata.creationTimestamp -o name | grep snapshot-cleanup | tail -1)
kubectl -n longhorn-system logs "$JOB" | grep -E "ERROR|FAILED|purge done|delete"
```

2. Match the case:

| Log line | Meaning | Action |
| --- | --- | --- |
| `purge still running after 7200s` | A large volume (usually Prometheus) purges slowly; Longhorn keeps purging after the job gives up | Step 3, then step 4 |
| `snapshotPurge: HTTP 500 ... concurrent snapshot purge limit reached` after 30 min of retries | Other purges or rebuilds held all 5 slots | Step 4; it retries next night |
| `purge error: ...` | The engine reported an error | Step 3; if the volume is degraded, `LONGHORN-001` |
| `snapshotList` / `snapshotDelete` errors | Longhorn API or the volume's engine not reachable | `LONGHORN-001` / `LONGHORN-002` for that volume |

3. Purges running and snapshots per volume now:

```bash
kubectl -n longhorn-system get engines.longhorn.io -o json | python3 -c '
import json,sys
for e in json.load(sys.stdin)["items"]:
    ps=[v for v in (e.get("status",{}).get("purgeStatus") or {}).values() if v.get("state")=="in_progress"]
    if ps: print("purging:", e["spec"].get("volumeName"), min(int(v.get("progress",0)) for v in ps), "%")'
kubectl -n longhorn-system get snapshots.longhorn.io -o json | python3 -c '
import json,sys,collections
c=collections.Counter(); r=collections.Counter(); g=collections.Counter()
for s in json.load(sys.stdin)["items"]:
    v=s["spec"]["volume"]; st=s.get("status",{}); c[v]+=1; g[v]+=int(st.get("size") or 0); r[v]+=1 if st.get("markRemoved") else 0
for v,n in sorted(c.items(), key=lambda x:-g[x[0]])[:8]: print(f"{v}  snaps {n}  removed {r[v]}  {g[v]/1e9:.1f} GB")'
```

   One removed snapshot can stay: Longhorn cannot purge the snapshot directly under the live data until a
   newer snapshot exists (the next backup creates one).

4. Once no purge is running, delete the failed job so `KubeJobFailed` resolves:

```bash
kubectl -n longhorn-system delete job <job>
```

5. To clean up now instead of waiting for 03:30, run the job by hand (`RETAIN_DAYS=0` also deletes the
   snapshots of earlier days; today's are kept). Not while volumes rebuild: purges and rebuilds share the disks.

```bash
kubectl -n longhorn-system create job snapshot-cleanup-manual --from=cronjob/longhorn-snapshot-cleanup --dry-run=client -o yaml \
  | sed 's/value: "3"/value: "0"/' | kubectl apply -f -
kubectl -n longhorn-system logs -f job/snapshot-cleanup-manual
```

Verify:

- Each volume has at most 1–2 snapshots, `removed` 0 or 1.
- The next nightly job ends `Complete`.

Rollback:

1. Nothing to roll back: deleting and purging snapshots does not touch the volume data or the backups in
   RustFS. A deleted snapshot cannot be restored, so restores come from Velero (`BACKUP-001`).

References:

- `kubernetes/platform/longhorn/config/base/snapshot-cleanup-cronjob.yaml`
- `kubernetes/platform/longhorn/app/base/values.yaml` (`autoCleanupSnapshotAfterOnDemandBackupCompleted`)
- `kubernetes/platform/velero/config/base/` (schedule and VolumeSnapshotClass)
- `homelab-docs/node-os-maintenance.md` (slow rebuilds caused by snapshot purges)
