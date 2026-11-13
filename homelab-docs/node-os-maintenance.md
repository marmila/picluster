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

Order: workers (node5, node6, node-esp-1, node-esp-2), then masters (node2, node3, node4), then node1. For
each node:

1. **Pre-flight:** every node is `Ready` and schedulable (none cordoned), and no Longhorn volume is `degraded`
   or `faulted`. Otherwise the run stops before touching the node.
2. **Upgrade:** `apt-get dist-upgrade`.
3. **Only if `/var/run/reboot-required` exists:**
   1. drain the node (`--ignore-daemonsets --delete-emptydir-data`, 60 s grace, 300 s timeout),
   2. reboot and wait for SSH,
   3. wait until the node is `Ready` (up to 5 minutes),
   4. masters only: wait 30 s more for etcd to re-sync,
   5. uncordon,
   6. wait until no Longhorn volume is `degraded` (up to 30 minutes).

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

# Longer drain timeout, longer Longhorn wait (retries x 20 s)
./ansible-runner/ansible-runner.sh ansible-playbook update.yml -e os_upgrade_drain_timeout=600s -e os_upgrade_longhorn_retries=180
```

### 3.4 After the run

- A node that was upgraded but **not** rebooted may have had `iscsid` restarted by the upgrade. Do
  [cluster-maintenance.md 7.2](cluster-maintenance.md#72-after-a-node-reboot-or-k3s-agent-restart) for it, or
  Longhorn volume expansion fails silently on that node. Rebooted nodes are fine.
- Check nothing is left cordoned: `kubectl get nodes` shows no `SchedulingDisabled`.

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
| `Pre-flight \| All nodes Ready and schedulable` | A node is NotReady or cordoned (the message lists it) | Fix or uncordon it, run again |
| `Pre-flight \| No Longhorn volume degraded or faulted` | A rebuild is still running, or a volume is faulted | Wait, or `LONGHORN-001` |
| `Reboot \| Drain the node` | Eviction blocked: a PodDisruptionBudget, or Longhorn protecting the last healthy replica | See "Drain blocked" below. The node was uncordoned |
| `Reboot \| Wait for the node to be Ready` | Node did not come back in 5 minutes | See "Node does not come back" |
| `Reboot \| Wait until no Longhorn volume is degraded` | Rebuild took more than 30 minutes | See "Volume stuck in degraded"; run again when healthy |

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

### Volume stuck in degraded for more than 30 minutes

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
