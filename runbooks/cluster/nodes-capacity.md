# Nodes and Capacity Runbooks

## CLUSTER-010 Node Replacement Workflow

<a id="runbook-cluster-010"></a>
Runbook ID: `CLUSTER-010`
Owner: Platform
Severity: `SEV-2` or `Maintenance`

Objective: Replace failed/degraded node with minimal disruption.

Procedure:

1. Cordon and drain old node if still reachable.

```bash
kubectl cordon <old-node>
kubectl drain <old-node> --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=15m
```

2. Remove old node object if permanently retired.

```bash
kubectl delete node <old-node>
```

3. Provision replacement host (networking, OS baseline).
4. Join replacement node using standard cluster automation.
5. Validate workload redistribution and storage attachment behavior.

Verify:

```bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
```

Rollback:

1. Keep workloads on remaining nodes if replacement join fails.
2. Re-attempt join after host/network fix.

## CLUSTER-011 Planned Node Drain and Maintenance

<a id="runbook-cluster-011"></a>
Runbook ID: `CLUSTER-011`
Owner: Platform
Severity: `Maintenance`

Objective: Safely perform node maintenance with minimal disruption.

Preconditions:

- Maintenance window approved.
- Workloads with PDB constraints reviewed.

Procedure:

1. Cordon node.

```bash
kubectl cordon <node-name>
```

2. Drain node.

```bash
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=10m
```

3. Perform host maintenance (kernel patch, reboot, disk ops, etc.).
4. Bring node back and uncordon.

```bash
kubectl uncordon <node-name>
```

Verify:

```bash
kubectl get nodes
kubectl get pods -A -o wide | grep <node-name>
```

Rollback:

1. If drain is blocked by PDB, abort drain and re-open scheduling (`uncordon`).
2. If node unhealthy after maintenance, keep cordoned and migrate workloads.

## CLUSTER-012 Node Disk Pressure Response

<a id="runbook-cluster-012"></a>
Runbook ID: `CLUSTER-012`
Owner: Platform
Severity: `SEV-2`

Objective: Free root disk space on a node before (or after) the kubelet starts evicting pods.

Alerts: `NodeRootDiskFillingUp` (root disk over 80%, warning), `KubeNodeDiskPressure` (DiskPressure
condition, critical), and the mixin alerts `NodeFilesystemSpaceFillingUp` / `NodeFilesystemAlmostOutOfSpace`.

Thresholds (`k3s_kubelet_config` in `ansible/vars/picluster.yml`):

| Root disk used | What happens |
| --- | --- |
| 70% | kubelet deletes unused images until 60% (`imageGCHighThresholdPercent`) |
| 80% | `NodeRootDiskFillingUp` fires |
| 85% | DiskPressure: node tainted `disk-pressure:NoSchedule`, pods evicted (`imagefs.available<15%`) |

Container images (`/var/lib/rancher/k3s/agent/containerd`) and logs share the root disk. On the x86 nodes it
is a 50G LV; Longhorn data is on a separate `/storage` LV and does not count here.

Procedure:

1. Identify the node and what uses the space. On node2:

```bash
kubectl get nodes
kubectl describe node <node-name> | grep -i -E 'DiskPressure|taint'
kubectl get pods -A --field-selector status.phase=Failed | grep -i evicted
```

On the node:

```bash
df -h /
sudo du -xsh /var/lib/rancher/k3s/agent/containerd /var/log /var/lib/longhorn 2>/dev/null
sudo journalctl --disk-usage
```

2. Shrink the journal. This freed 3.4G on node-esp-2 (2026-11-07):

```bash
sudo journalctl --vacuum-size=500M
```

3. Remove images no container uses:

```bash
sudo k3s crictl rmi --prune
```

   This can free nothing (as on node-esp-2): images still referenced by exited containers are kept. Do not
   delete exited containers by hand, since the kubelet may re-run init containers of running pods. Once the
   journal is trimmed and DiskPressure clears, the kubelet's own image GC (70%) removes the rest.

4. Delete evicted pods so they stop showing up (on node2):

```bash
kubectl get pods -A --field-selector status.phase=Failed -o json \
  | jq -r '.items[] | select(.status.reason=="Evicted") | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read ns p; do kubectl -n "$ns" delete pod "$p"; done
```

5. If the journal limit or image GC thresholds are missing on the node (fresh config not applied), run
   `make node-config-update` on pimaster. It restarts k3s only where the kubelet config changed, one node at
   a time.

Verify:

- `df -h /` below 80% on the node.
- Node condition `DiskPressure=False`, taint gone, DaemonSet pods (fluent-bit, cilium) running on the node.
- `NodeRootDiskFillingUp` and `KubeNodeDiskPressure` resolve.

Rollback:

1. If space cannot be freed, cordon the node and drain it (`CLUSTER-011`), then investigate offline.
2. Replace the node using `CLUSTER-010` if the disk is failing.

References:

- `ansible/vars/picluster.yml` (`k3s_kubelet_config`), `ansible/roles/basic_setup/tasks/journald.yml`,
  `ansible/update_node_config.yml`.
- `kubernetes/platform/kube-prometheus-stack/k3s-mixins/base/rules/node-disk-rules.yaml`.
- `postmortems/incident-2026-11-07-node-esp-2-disk-pressure.md`.

## CLUSTER-014 Hung Node and etcd Quorum Loss Recovery

<a id="runbook-cluster-014"></a>
Runbook ID: `CLUSTER-014`
Owner: Platform
Severity: `SEV-1`

Objective: Recover the cluster API when one or more control-plane nodes hang while their kernels stay
alive, leaving etcd without quorum. The tell-tale sign is a node that answers at the network layer but
serves nothing, and an apiserver that answers `ServiceUnavailable` instead of refusing connections.

Preconditions:

- SSH access to the `gateway` host (OpenWrt, `10.0.0.1`) and to the cluster nodes.
- Physical access, or remote power control, for the hung nodes.
- You have not restarted the remaining healthy control-plane member.

> **Warning:** ICMP is not a liveness signal in this cluster. The `gateway` rejects WAN-to-LAN traffic
> by default and only forwards a whitelist, so `ping` from the home network fails even when every node
> is healthy. Read the next paragraph before drawing conclusions.

**Why the usual checks lie.** The `gateway` runs OpenWrt `fw4` with two zones: `lan` (the lab network)
and `wan` (your home network). All traffic from `lan` to `wan` is accepted; traffic from `wan` to `lan`
is rejected unless explicitly
allowed. The forwarding chain permits only:

| Direction | Destination | Port |
| --- | --- | --- |
| WAN → LAN | any lab host | TCP 22 |
| WAN → LAN | any lab host | TCP 80, 443 |
| WAN → LAN | `10.0.0.10` (kube-vip VIP) | TCP 6443 |
| WAN → LAN | `10.0.0.11` (node1) | TCP 8200 (Vault), 9091, 9092 (S3) |
| WAN → LAN | `10.0.0.69` | TCP 9094 (Kafka) |

Anything else reaches `jump reject_to_wan`. Consequences to keep in mind:

- **IPv4 ICMP echo is not forwarded.** A failing `ping` says nothing about node health. Only ICMPv6
  echo is accepted in the forward chain.
- **Only the VIP exposes `6443`.** `curl https://<node-ip>:6443` is blocked by the firewall, so it
  cannot be used to decide whether the apiserver is up.
- **Only `22` is open on every node.** SSH is the reliable per-node probe.

Confirm the live rule set rather than assuming it:

```bash
ssh gateway 'nft list chain inet fw4 forward_wan'
```

Procedure:

1. Confirm the lab interface is up on the gateway. `ping` is blocked, so check state, not reachability.

```bash
ssh gateway 'ip -o addr show br-lan; ip route'
```

Expect `inet 10.0.0.1/24` on `br-lan` and a `10.0.0.0/24` route. This distinguishes "the lab segment is
down" from "the cluster is down".

2. Probe every node over TCP 22 and classify the failure. The error text is the diagnosis:

```bash
for h in node1 node2 node3 node4 node5 node-hp-1 node-hp-2 node-hp-3; do
  printf '%-10s ' "$h"
  timeout 10 ssh -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "$h" 'true' 2>&1 | tail -1
  echo
done
```

| Result | Meaning |
| --- | --- |
| Silent success | Node healthy |
| `Connection timed out during banner exchange` | **TCP connects but userspace is hung** — kernel alive, no sshd. This runbook. |
| `Connection refused` | Host alive, sshd not running |
| `No route to host` / connect timeout | Host down, or the link/segment is down |

3. Confirm quorum loss from a surviving control-plane node.

```bash
ssh node3 'sudo -n k3s kubectl get nodes --request-timeout=10s'
```

`ServiceUnavailable: the server is currently unable to handle the request` means the apiserver is
running but etcd has no quorum. `Unable to connect` means the apiserver itself is unreachable.

```bash
ssh node3 'sudo -n journalctl -u k3s --since "-30 min" --no-pager \
  | grep -iE "etcd|quorum|leader|raft" | tail -20'
```

Look for `failed to publish local member to cluster through raft`, `is starting a new election`, and
`dial tcp <peer>:2380: i/o timeout` for each hung peer.

4. Identify who holds the API VIP. A hung node can keep answering ARP for `10.0.0.10`, which blackholes
the VIP even before failover is possible.

```bash
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
ssh node3 'ip -o addr show | grep 10.0.0.10'
```

5. Check power and thermal state on every Raspberry Pi. Under-voltage is the most common cause of this
hang, and it is invisible from Kubernetes.

```bash
make get-pi-status
```

Or per node:

```bash
ssh node2 'sudo -n vcgencmd get_throttled'
```

Decode the bitmap: bit 0 under-voltage now, bit 2 throttled now, bit 16 under-voltage has occurred,
bit 18 throttling has occurred. `0x50005` means the node is under-voltage and throttled right now.

6. **Do not restart the healthy control-plane member.** With three etcd members you need two, and the
   survivor holds the newest raft log. Restarting it removes the only copy that can serve the election.
7. Hard power-cycle only the hung nodes. There is no graceful path once userspace is frozen and no
   listener remains.
8. As each node returns, confirm quorum is restored.

```bash
ssh <survivor> 'sudo -n k3s kubectl get nodes --request-timeout=15s'
```

9. Confirm the VIP is bound to a live node.

```bash
kubectl -n kube-system get lease plndr-cp-lock -o jsonpath='{.spec.holderIdentity}{"\n"}'
kubectl -n kube-system get pods -o wide | grep kube-vip
```

10. Let Flux re-converge. Do not force reconciles. Kustomizations are ordered by `dependsOn`, so a long
    `DependencyNotReady` cascade is normal for several minutes.

```bash
flux get kustomizations -A --status-selector ready=false
flux get helmreleases -A --status-selector ready=false
```

> **Note:** `Could not load chart: failed to download archive: context deadline exceeded` on many
> HelmReleases during the cascade are stale messages recorded while the API was unavailable — not a new
> fault. Confirm the sources are healthy before chasing them: `flux get sources all -A
> --status-selector ready=false` should return nothing.

Verify:

```bash
kubectl get nodes
flux get kustomizations -A --status-selector ready=false
flux get helmreleases -A --status-selector ready=false
kubectl -n databases get clusters.postgresql.cnpg.io
```

Healthy signals: every node `Ready`; both `flux get` commands return no rows; CNPG clusters report
`Cluster in healthy state`; `make get-pi-status` shows no `throttled=0x...` with the "now" bits set.

Rollback:

1. If a power-cycled node does not come back, treat it as failed hardware and follow `CLUSTER-010`.
2. If quorum cannot be restored because a member's data is suspect, restore from backup per
   `CLUSTER-002`. Never delete or re-initialise etcd data to force an election.
3. If under-voltage persists after the node is up, replace the power supply or cable before returning it
   to service. A throttled control-plane node will hang again under load.

References:

- `docs/_docs/openwrt.md#firewall` — gateway zones and the WAN-to-LAN whitelist.
- `ansible/group_vars/all.yml` — `default_gateway: 10.0.0.1` and `dns_server: 10.0.0.1`.
- `Makefile` — `get-pi-status` target.

**Incident record (2026-11-01).** `node2` and `node4` hung at the userspace level within minutes of
each other. Both answered ICMP but returned no SSH banner and did not answer etcd on `2380`, leaving
`node3` as the only member of three. The apiserver returned `ServiceUnavailable`, the VIP stayed ARP-answered by hung `node4`, and the
whole cluster appeared unreachable. `node3` reported `throttled=0x50005`; after recovery `node2`,
`node3` and `node4` all showed under-voltage history while `node5` was clean. Power-cycling `node2` and
`node4` while leaving `node3` running restored quorum and the VIP moved to `node3`. Flux re-converged
unaided. Follow-up: power delivery on the three control-plane Pis.

## CLUSTER-015 Stuck k3s Upgrade (system-upgrade-controller)

<a id="runbook-cluster-015"></a>
Runbook ID: `CLUSTER-015`
Owner: Platform
Severity: `SEV-3`

Objective: Finish a k3s upgrade that stopped part-way. Upgrades run from the `k3s-server` and `k3s-agent`
Plans in `kubernetes/platform/system-upgrade/config/base/`: masters first, one at a time, then workers one
at a time. system-upgrade-controller never retries a failed job, so one failure leaves the remaining nodes
on the old version until someone acts.

Alerts: `K3sUpgradePlanStuck`, `K3sNodeVersionDrift`. `KubeVersionMismatch` also fires during every normal
upgrade; act on it only if it lasts more than about an hour.

Preconditions:

- No other node is down or being drained. Upgrade one node at a time.
- On Pi nodes, check power first: `sudo vcgencmd get_throttled` should be `0x0` (or only the "since boot"
  bits `0x50000`). Under-voltage makes upgrade jobs time out.

Procedure:

1. Find where it stopped.

```bash
kubectl get nodes
kubectl -n system-upgrade get plans,jobs,pods -o wide
kubectl -n system-upgrade logs deploy/system-upgrade-controller --since=3h | grep -iE "JobFailed|error" | tail -20
```

2. Match the case:

| What you see | Cause | Fix |
| --- | --- | --- |
| Plan message `DeadlineExceeded`, no job left | Job ran out of time (often waiting for the masters, or under-voltage) | Step 3 |
| Agent job pod stuck in `Init:0/2` | The prepare step waits until every master runs the plan version | Step 4 for the master that is behind |
| A node with the plan label (`kubectl get nodes -L plan.upgrade.cattle.io/k3s-server,plan.upgrade.cattle.io/k3s-agent`) but the old version | Job finished, k3s was not restarted | Step 4 |
| A node upgraded but still `SchedulingDisabled` | Job was killed after the upgrade, before uncordon | Step 5 |

3. Re-create failed jobs by restarting the controller. If a `Failed` job still exists, delete it first,
   otherwise the controller keeps reporting it.

```bash
kubectl -n system-upgrade delete job -l upgrade.cattle.io/plan=k3s-agent --field-selector status.successful=0
kubectl -n system-upgrade rollout restart deploy/system-upgrade-controller
```

4. Node runs the old version although the new binary is installed. On that node:

```bash
sudo k3s --version | head -1                        # binary on disk
sudo systemctl show k3s -p ActiveEnterTimestamp     # when the service started (k3s-agent on workers)
sudo systemctl restart k3s                          # k3s-agent on workers
```

   Restart only if the binary is the new version and the service started before the job finished. On a
   master, make sure the other two masters are `Ready` first so etcd keeps quorum.

5. Node upgraded but still cordoned: `kubectl uncordon <node>`.

Verify:

- `kubectl get nodes` shows every node on the plan version, none `SchedulingDisabled`.
- `kubectl -n system-upgrade get plans` shows `COMPLETE True` for both plans.
- `K3sUpgradePlanStuck` and `K3sNodeVersionDrift` resolve.

Rollback:

1. Do not downgrade k3s through the Plans. If a new version misbehaves, revert the version bump in Git and
   follow the k3s release notes for the supported downgrade path.
2. If a node does not come back after the restart, follow `CLUSTER-014` (masters) or `CLUSTER-010`.

References:

- `kubernetes/platform/system-upgrade/config/base/k3s-agent.yaml` — `jobActiveDeadlineSecs` is 7200
  because the agent prepare step's wait for the masters counts against it.
- `kubernetes/platform/system-upgrade/config/base/k3s-upgrade-rules.yaml` — the alerts.
- `homelab-docs/alerting.md`, section "k3s upgrade alerts".
- `postmortems/incident-2026-11-05-node6-undervoltage.md` — the 2026-09-27 and 2026-11-07 failures.
