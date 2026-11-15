# Node OS maintenance: package upgrades and safe reboots

How to upgrade the operating system packages of the nodes and reboot them without breaking etcd quorum,
Longhorn volumes or stateful workloads. Replaces the former `os-upgrade.md` and `node-os-reboot.md`
(merged 2026-11-13).

- **Normal case:** `make os-upgrade-check` (dry run), then `make os-upgrade`. The playbook drains, reboots,
  uncordons and waits for Longhorn by itself, one node at a time. See [section 3](#3-make-os-upgrade).
- **Reboot only, no upgrade** (one node misbehaving, a pending `*** System restart required ***` you want to
  clear by hand): [section 4](#4-manual-safe-reboot).

The upstream [Ansible instructions](../docs/_docs/ansible-instructions.md) describe the original playbook; this
page covers how it runs in this homelab.

## Contents

- [1. Cluster layout](#1-cluster-layout)
- [2. Constraints](#2-constraints)
- [3. make os-upgrade](#3-make-os-upgrade)
- [4. Manual safe reboot](#4-manual-safe-reboot)
- [5. Troubleshooting](#5-troubleshooting)
- [6. Reference](#6-reference)

## 1. Cluster layout

| Node | Role | Architecture | Notes |
| --- | --- | --- | --- |
| node1 | outside k3s | ARM (Raspberry Pi) | Vault, RustFS, DNS, HAProxy |
| node2 | k3s master, etcd | ARM | |
| node3 | k3s master, etcd | ARM | |
| node4 | k3s master, etcd | ARM | |
| node5 | k3s worker | ARM | |
| node6 | k3s worker | ARM | |
| node-esp-1 | k3s worker | x86 (mini PC) | |
| node-esp-2 | k3s worker | x86 (mini PC) | |

`pimaster` in the inventory is the ansible-runner container itself (`ansible_connection: local`), not a real
machine, so it is not upgraded: its packages are refreshed when its image is rebuilt. The VM or host where the
runner container runs is not in the inventory either. Keep it updated on its own (for example with
`unattended-upgrades`) and never reboot it while a playbook is running: that stops the container and the run.

## 2. Constraints

### etcd quorum (node2, node3, node4)

k3s embeds etcd on the three masters. Quorum needs **2 of 3** up; without it the Kubernetes API stops. Rule:
**one master at a time**, and the next one only after the previous is back and Ready.

### Longhorn

Volumes have 3 replicas. When a node goes down, its replicas are lost and the volumes become `degraded` until
Longhorn rebuilds them on the remaining nodes (usually 5–20 minutes). Rule: **never take a second node down
while a volume is `degraded`**: a volume left with one healthy replica can turn `faulted` on the next
disruption.

### Workloads with their own quorum

Kafka (3 brokers, KRaft), CloudNativePG (3 instances), MongoDB (3-member replica set) and Keycloak (2
instances) each tolerate one member down. One node at a time plus the Longhorn wait covers all of them.

### Order

Workers first, then masters, one at a time. A problem shows up on a worker before etcd is at risk.

## 3. make os-upgrade

Playbook [ansible/update.yml](../ansible/update.yml), per-node steps in
[ansible/tasks/os_upgrade_node.yml](../ansible/tasks/os_upgrade_node.yml). Run from the repository root on the
Ansible control node.

### 3.1 Dry run first

```bash
make os-upgrade-check
```

It changes nothing on the nodes (Ansible `--check`): no package is upgraded, nothing is drained or rebooted.
It does run the read-only pre-flight checks for real and refreshes the apt package lists, so the result is
accurate. For each node it prints a summary like:

```text
node5 (k3s worker)
Packages to upgrade: 23
Kernel or firmware among them: ['linux-image-6.8.0-1015-raspi', ...]
Reboot already pending: False
Real run: upgrade, then if /var/run/reboot-required exists drain (from node2), reboot, wait Ready, uncordon, wait for Longhorn.
```

A kernel or firmware package in the list almost always means the real run will reboot that node. If a
pre-flight check fails in the dry run, the real run would stop at the same place: fix that first.

### 3.2 Real run

```bash
make os-upgrade
```

A run that reboots every node can take many hours, mostly waiting for Longhorn rebuilds (often over an hour
per node). Start it inside `tmux` or `screen`, so a dropped SSH session does not stop it halfway, and split it over
several sessions with `--limit` if needed (section 3.3).

```bash
tmux new -s osup
make os-upgrade 2>&1 | tee -a /tmp/os-upgrade.log
```

Follow it from node2 with `watch -n 60 ~/bin/lh-snaps.sh` (degraded volumes) and `~/bin/lh-rebuild.sh`
(rebuild progress); the scripts are in `LONGHORN-003` step 3.

Order: workers (node5, node6, node-esp-1, node-esp-2), then masters (node2, node3, node4), then node1. For
each node:

1. **Pre-flight** ([ansible/tasks/k3s_preflight.yml](../ansible/tasks/k3s_preflight.yml), shared with
   `make move-rancher-to-storage`). Otherwise the run stops before touching the node:
   1. every node is `Ready` and schedulable (none cordoned), and no Longhorn volume is `degraded` or `faulted`;
   2. k3s nodes only, the **capacity of the other nodes**, which take the drained pods (since 2026-11-15):
      - CPU below 80% and memory below 90% (`kubectl top nodes`). If a node is busier, the run **waits** up to
        10 minutes for it to calm down, then stops. A node that is still busy from the previous reboot (rebuilds,
        image pulls, a restarting Prometheus) is exactly where the next drained pods would land (section 3.5);
      - root disk and image disk below 85% (kubelet stats). Pulling the images of the drained pods can add
        several GB to another node: on 2026-11-15 node-esp-2 went from 46% to 87% when node-esp-1 was drained,
        and k3s evicts at 95%. The checked values are printed even when they are fine;
      - if `kubectl top` does not work (metrics-server down), CPU and memory are skipped with a message; a node
        whose stats cannot be read shows `?` and does not stop the run.
2. **Upgrade:** `apt-get dist-upgrade`.
3. **Only if `/var/run/reboot-required` exists:**
   1. drain the node (`--ignore-daemonsets --delete-emptydir-data`, 60 s grace, 300 s timeout),
   2. reboot and wait for SSH,
   3. wait until the node is `Ready` (up to 5 minutes),
   4. masters only: wait 30 s more for etcd to re-sync,
   5. uncordon,
   6. wait until no Longhorn volume is `degraded`
      ([ansible/tasks/k3s_wait_longhorn.yml](../ansible/tasks/k3s_wait_longhorn.yml), since 2026-11-15). Longhorn
      here rebuilds one replica per node at a time, as a full copy, and may first clean up the volume's
      snapshots, so the time varies a lot. The wait **follows progress** instead of a fixed time: it fails only
      when nothing has changed for 30 minutes (same volumes degraded, no rebuild or purge progress, no replica
      state change), or after 4 hours in any case. It prints each change of the degraded count.
   7. print how long it took, for example
      `node5: drain 0:01:12.4, reboot 95 s, Longhorn: 14:52 Longhorn healthy after 23 min`.

kubectl runs as `k3s kubectl` on another master (never on the node being rebooted). node1 is not a k3s node:
it is upgraded and rebooted without the drain and Longhorn steps. After a node1 reboot check `vault status` on
node1: if Vault comes back sealed, `VaultSealed` fires (runbook `VAULT-001`).

**On any failure the whole run stops.** If the failure was in the reboot part, the node is uncordoned first.
The next nodes, and the masters after a failed worker, are not touched. Fix the cause and run `make
os-upgrade` again: nodes already upgraded go quickly (nothing to upgrade, no reboot pending).

Before k3s is installed (`make init` runs `os-upgrade` first), there is no cluster to check: the pre-flight,
drain and Longhorn steps are skipped and a node that needs it is just rebooted.

### 3.3 Options

Run through the runner wrapper to pass options:

```bash
# One node or one group only (the pre-flight still checks the whole cluster)
./ansible-runner/ansible-runner.sh ansible-playbook update.yml --limit node5
./ansible-runner/ansible-runner.sh ansible-playbook update.yml --limit k3s_worker

# Longer drain timeout; Longhorn wait: stop after 60 min without progress, at most 6 h
./ansible-runner/ansible-runner.sh ansible-playbook update.yml -e os_upgrade_drain_timeout=600s   -e k3s_maint_longhorn_stall_minutes=60 -e k3s_maint_longhorn_max_hours=6

# Capacity limits of the pre-flight (defaults: cpu 80, memory 90, disk 85, wait 10 min while busy)
./ansible-runner/ansible-runner.sh ansible-playbook update.yml -e k3s_maint_max_mem_percent=95   -e k3s_maint_max_disk_percent=90 -e k3s_maint_load_wait_minutes=20
```

Raise a limit only when you know why the value is high and that the drained pods will not land there. The
same options work for `move_rancher_to_storage.yml`.

`os_upgrade_longhorn_retries` no longer exists (replaced on 2026-11-15 by the two `k3s_maint_longhorn_*`
options).

### 3.4 After the run

- A node that was upgraded but **not** rebooted may have had `iscsid` restarted by the upgrade. Do
  [cluster-maintenance.md 7.2](cluster-maintenance.md#72-after-a-node-reboot-or-k3s-agent-restart) for it, or
  Longhorn volume expansion fails silently on that node. Rebooted nodes are fine.
- Check nothing is left cordoned: `kubectl get nodes` shows no `SchedulingDisabled`.

### 3.5 First full run (2026-11-14)

The first run of the playbook over all nodes worked, in two parts on the same day:

1. Workers: node-esp-1, node-esp-2 and node6 were upgraded and rebooted; node5 had been done the day before and
   was skipped.
2. Before node2 (the first master) the pre-flight stopped the run: node6 was `Unknown`. Draining node-esp-1 and
   node-esp-2 had moved their heavy pods to node6, a Pi: Prometheus (replaying its 50 GB data at startup),
   `postgres-keycloak-1`, keycloak, operators, image pulls of 6 to 25 minutes, and the Longhorn rebuild of the
   Prometheus volume on top. Load went to 55 on 4 cores, the kubelet missed its heartbeats and the node went
   `NotReady` three times. Kubernetes then evicted Prometheus, which restarted on node-esp-2 and became `3/3`
   there; the Longhorn UI gave HTTP 500 while the Longhorn manager on node6 was too slow, and recovered on its
   own. No restart of Longhorn or of any pod was needed.
3. After the Prometheus rebuild finished (0 degraded volumes), `make os-upgrade` was started again: the
   workers were skipped quickly, the masters and node1 went through without a problem.

What to take from it:

- The pre-flight did its job: a master reboot with a node `NotReady` would have been worse.
- Pods drained from node-esp-1/2 do not move back after the uncordon, and the Pis cannot carry them. Done: a
  preferred node affinity keeps Prometheus on amd64 (`3b4a219c`), and since 2026-11-15 the pre-flight checks the
  CPU, memory and disk of the other nodes (section 3.2).
- Rebuilds after a reboot are short when volumes carry no old snapshots (see `LONGHORN-003`); the long wait was
  the Prometheus volume rebuilding while its pod was crash-looping on node6.

## 4. Manual safe reboot

For a reboot without an upgrade. Same rules as the playbook: workers first, one node at a time, Longhorn
healthy before the next.

### 4.1 Pre-flight

```bash
kubectl get nodes                                                       # all Ready, none SchedulingDisabled
kubectl -n longhorn-system get volumes.longhorn.io | grep -vi healthy   # no degraded or faulted (detached is fine)
kubectl -n longhorn-system get pods | grep -v -E "Running|Completed"    # Longhorn pods healthy
```

### 4.2 Where to run kubectl

Never from the node you are rebooting: the session dies with it.

- Worker: from any master.
- node2: from node3 or node4. node3: from node4 or node2. node4: from node2 or node3.

### 4.3 One node

```bash
NODE=node5
kubectl drain $NODE --ignore-daemonsets --delete-emptydir-data --grace-period=60
ssh $NODE sudo reboot
kubectl wait --for=condition=Ready node/$NODE --timeout=300s
sleep 30                     # masters only: let etcd re-sync
kubectl uncordon $NODE
watch -n 10 "kubectl -n longhorn-system get volumes.longhorn.io | grep degraded"   # wait until empty
```

After a master, also check that the API server sees etcd healthy:

```bash
kubectl get --raw='/readyz?verbose' | grep etcd      # expect: [+]etcd ok
kubectl get nodes | grep control-plane               # all three Ready
```

Move to the next node only when no volume is `degraded`.

## 5. Troubleshooting

### The playbook stopped

Read the last failed task:

| Failed at | Meaning | Do |
| --- | --- | --- |
| `Pre-flight \| All nodes Ready and schedulable` | A node is NotReady or cordoned (the message lists it) | Fix or uncordon it, run again. A node `Unknown` right after another node's drain is usually overloaded: see "A node goes NotReady after a drain" |
| `Pre-flight \| No Longhorn volume degraded or faulted` | A rebuild is still running, or a volume is faulted | Wait, or `LONGHORN-001` |
| `Pre-flight \| Other nodes not overloaded` | Another node stayed above 80% CPU or 90% memory for 10 minutes (the message lists it) | See "A node goes NotReady after a drain" for what runs there; run again when it is calm |
| `Pre-flight \| Other nodes have disk room for the drained pods' images` | Another node's root or image disk is above 85% | Free space there first (`CLUSTER-012`), then run again |
| `Reboot \| Drain the node` | Eviction blocked: a PodDisruptionBudget, or Longhorn protecting the last healthy replica | See "Drain blocked" below. The node was uncordoned |
| `Reboot \| Wait for the node to be Ready` | Node did not come back in 5 minutes | See "Node does not come back" |
| `Longhorn \| Stop when the rebuild did not finish` | `STALLED`: no progress for 30 minutes, or `TIMEOUT`: still rebuilding after 4 hours. The message lists the volumes | See "Volume stuck in degraded"; run again when healthy. The node is already uncordoned |

### Drain blocked

```bash
kubectl get pdb -A
kubectl -n longhorn-system get volumes.longhorn.io -o wide
```

Longhorn blocks the drain of a node that holds the only healthy replica of a volume: wait for the volume to
be healthy. As a last resort, only if the node must reboot now:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --disable-eviction --grace-period=30 --force
```

### Volume stuck in degraded

A slow rebuild usually is not stuck. Longhorn settings here (`concurrentReplicaRebuildPerNodeLimit: 1`,
`fastReplicaRebuildEnabled: false` in `kubernetes/platform/longhorn/app/base/values.yaml`) mean one rebuild per
node at a time, each a full copy. Before a rebuild, Longhorn also cleans up (purges) the volume's snapshots,
which can take a long time on a volume with large snapshots. Seen on 2026-11-13 after the node5 reboot: the
Prometheus volume (50 GB, 123 GB of snapshots) blocked the queue for over an hour while the cleanup ran.
The snapshots came from the nightly Velero backup; since 2026-11-14 Longhorn deletes them right after the upload
and the 03:30 cleanup job purges what is left, so this should be rare now. If a volume has many snapshots again,
see `LONGHORN-003` in `runbooks/components/longhorn.md` before starting a node maintenance.

Signs of this case, all normal:

- longhorn-manager logs `Replica rebuildings for map[...] are in progress on this node, which reaches or exceeds
  the concurrent limit value 1`: the other volumes are queued.
- longhorn-manager logs `Waiting for snapshot purge to complete before rebuilding` and `failed to start rebuild
  ... context deadline exceeded` every 30 s: the cleanup is still running.

Watch cleanup and rebuild progress per degraded volume:

```bash
kubectl -n longhorn-system get engines.longhorn.io -o json | python3 -c '
import json,sys
for e in json.load(sys.stdin)["items"]:
    s=e["status"]; n=e["spec"].get("volumeName","")
    for r,p in (s.get("purgeStatus") or {}).items():
        if p.get("isPurging"): print(n, "cleanup", str(p.get("progress"))+"%")
    for r,p in (s.get("rebuildStatus") or {}).items():
        print(n, "rebuild", str(p.get("progress"))+"%", p.get("state"), p.get("error",""))'
```

If the percentages keep rising, wait. If nothing moves for 30 minutes or there is an error:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep -E "RB|ERR"
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=100 | grep -i error
```

Then runbook `LONGHORN-001`.

### Node does not come back Ready within 5 minutes

```bash
ssh <node> sudo systemctl status k3s        # masters
ssh <node> sudo systemctl status k3s-agent  # workers
ssh <node> sudo journalctl -u k3s -n 50     # or -u k3s-agent
```

### A node goes NotReady after a drain

Seen 2026-11-14 on node6 (section 3.5). The pods of a drained node landed on a Pi, which is too slow for them.

```bash
kubectl top nodes
kubectl get pods -A -o wide --field-selector spec.nodeName=<node> --no-headers | awk '{print $1, $2, $4}' | column -t
ssh <node> uptime                                  # load above ~8 on a Pi is too much
ssh <node> sudo vcgencmd get_throttled             # 0x0: not a power problem
```

- Do not restart Longhorn or force-delete pods. After about 5 minutes `NotReady`, Kubernetes evicts the pods
  itself and they start on a node with room. A pod can stay `Terminating` for several minutes while containerd
  on the slow node catches up: wait. A force delete can leave a Longhorn volume attached to the slow node.
- Run `make os-upgrade` again when the node is `Ready`, its load is down and there are 0 degraded volumes.

### etcd unhealthy after a master reboot

k3s runs etcd inside the k3s process, so there is no etcd pod and no `etcdctl` by default. Check from another
master:

```bash
kubectl get --raw='/readyz?verbose' | grep etcd
ssh <node> sudo journalctl -u k3s -n 100 | grep -i etcd
```

## 6. Reference

- [ansible/update.yml](../ansible/update.yml) and
  [ansible/tasks/os_upgrade_node.yml](../ansible/tasks/os_upgrade_node.yml): the playbook
- [cluster-maintenance.md](cluster-maintenance.md): when to run it (monthly, section 6) and 7.2 after a
  restart without reboot
- [kubernetes/platform/system-upgrade/](../kubernetes/platform/system-upgrade/): k3s version upgrades, separate
  from OS upgrades
- History: last fully manual reboot of all nodes 2026-04-21 → 2026-04-23. Drain, uncordon and the Longhorn wait
  were added to the playbook on 2026-11-13; before that `make os-upgrade` rebooted nodes without draining.
  First full run with them: 2026-11-14 (section 3.5).
