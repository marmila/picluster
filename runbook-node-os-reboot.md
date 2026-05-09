# Runbook: Safe OS Reboot of Cluster Nodes

**Cluster:** picluster (k3s HA)  
**Last executed:** 2026-04-21 → 2026-04-23  
**Trigger:** OS kernel updates requiring restart (`*** System restart required ***`)

---

## Cluster Layout

| Node | Role | Architecture |
|------|------|------|
| node-esp-1 | worker | x86 (mini PC) |
| node-esp-2 | worker | x86 (mini PC) |
| node2 | control-plane, etcd | ARM |
| node3 | control-plane, etcd | ARM |
| node4 | control-plane, etcd | ARM |
| node5 | worker | ARM |
| node6 | worker | ARM |

---

## Key Constraints

### etcd Quorum (node2, node3, node4)
K3s embeds etcd on all three control plane nodes. A 3-node etcd cluster requires **2/3 nodes up** for quorum. Losing quorum makes the Kubernetes API unavailable and the cluster unmanageable.

**Rule: reboot one control plane at a time. Verify the node is back and Ready before touching the next.**

### Longhorn Distributed Storage
All persistent volumes use Longhorn with a default replica count of 3. When a node goes down, Longhorn marks volumes as `degraded` and starts rebuilding replicas on surviving nodes.

**Rule: never drain a second node while any volume is in `degraded` state. Wait for full rebuild first.**

Rebuilding a degraded volume typically takes **5–20 minutes** depending on volume size. Skipping this wait leaves volumes with only 1 healthy replica — any further disruption risks data loss or a `faulted` (unrecoverable) volume.

### Stateful Workloads with Their Own Quorum
- **Kafka** (3 brokers, KRaft mode): tolerates 1 broker down at a time
- **PostgreSQL** (CloudNative-PG, 3 instances): tolerates 1 instance down
- **MongoDB** (3-member ReplicaSet): tolerates 1 member down
- **Keycloak** (2 instances): tolerates 1 instance down

Draining one node at a time and waiting for Longhorn health satisfies all of the above.

---

## Reboot Order

Always reboot in this order:

1. **Workers first** — node5, node6 (one at a time)
2. **Control planes last** — node2, node3, node4 (one at a time)

Rebooting workers first keeps etcd quorum intact throughout and limits the blast radius if something goes wrong.

---

## Pre-Flight Checks

Run these before starting any reboot:

```bash
# All nodes are Ready
kubectl get nodes

# No volumes currently degraded or faulted
kubectl -n longhorn-system get volumes.longhorn.io | grep -v Healthy

# Longhorn system pods are healthy
kubectl -n longhorn-system get pods | grep -v Running | grep -v Completed

# Optionally run the cluster health check script
bash ansible/files/check_lh.sh
```

Only proceed if all nodes are `Ready` and no volumes are `degraded` or `faulted`.

---

## Procedure

### Where to Run kubectl Commands

- **For rebooting a worker (node5/node6):** run from any control plane node (node2, node3, or node4) or your local machine.
- **For rebooting node2:** SSH to **node3 or node4** first, then run commands from there.
- **For rebooting node3:** SSH to **node4** (or node2, already back up), then run from there.
- **For rebooting node4:** SSH to **node2 or node3**, then run from there.

**Never run the drain/wait/uncordon sequence from the node you are about to reboot** — the SSH session will die mid-sequence when the node goes down.

---

### Phase 1 — Workers

Repeat this block for **node5**, then **node6**:

```bash
# 1. Drain the node (evicts pods gracefully, cordons it)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --grace-period=60

# 2. Reboot
ssh <node> sudo reboot

# 3. Wait for the node to come back Ready
kubectl wait --for=condition=Ready node/<node> --timeout=300s

# 4. Uncordon so the scheduler can place pods again
kubectl uncordon <node>
```

**After each worker reboot — mandatory wait:**

```bash
# Watch until this returns empty (no degraded volumes)
watch -n 10 "kubectl -n longhorn-system get volumes.longhorn.io | grep degraded"
```

Do not proceed to the next node until the above command returns no output.

---

### Phase 2 — Control Planes

Repeat this block for **node2**, then **node3**, then **node4**:

```bash
# 0. SSH to a DIFFERENT control plane node first
ssh node3  # (or node4 when rebooting node3, etc.)

# 1. Drain the target control plane
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --grace-period=60

# 2. Reboot
ssh <node> sudo reboot

# 3. Wait for node to come back Ready
kubectl wait --for=condition=Ready node/<node> --timeout=300s

# 4. Give embedded etcd time to re-sync with peers
sleep 30

# 5. Uncordon
kubectl uncordon <node>
```

**After each control plane reboot — mandatory checks before proceeding:**

```bash
# 1. All three control planes are Ready
kubectl get nodes | grep control-plane

# 2. No degraded volumes
watch -n 10 "kubectl -n longhorn-system get volumes.longhorn.io | grep degraded"

# 3. etcd quorum is healthy
#    (k3s embeds etcd — 3/3 control planes Ready = quorum is intact)
kubectl get nodes
```

Only when all three checks pass, move to the next control plane node.

---

## Troubleshooting

### Volume stuck in `degraded` for more than 30 minutes

Check replica rebuild progress:

```bash
kubectl -n longhorn-system get replicas.longhorn.io -o wide | grep -E "RB|ERR"
```

Check Longhorn manager logs for errors:

```bash
kubectl -n longhorn-system logs -l app=longhorn-manager --tail=100 | grep -i error
```

### Node does not come back Ready within 5 minutes

Check if k3s service started:

```bash
ssh <node> sudo systemctl status k3s
ssh <node> sudo journalctl -u k3s -n 50
```

### etcd unhealthy after control plane reboot

Check etcd member list from a surviving control plane:

```bash
kubectl -n kube-system exec -it \
  $(kubectl -n kube-system get pod -l component=etcd -o name | head -1) \
  -- etcdctl member list
```

If the rebooted node does not appear or shows `unstarted`, check k3s logs on that node:

```bash
ssh <node> sudo journalctl -u k3s -n 100 | grep -i etcd
```

### Pod eviction fails during drain (PodDisruptionBudget or non-graceful)

Force the drain as a last resort — only if the node genuinely needs to reboot now:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data \
  --disable-eviction --grace-period=30 --force
```

---

## Automation Candidate (Ansible)

This procedure maps naturally onto an Ansible playbook with the following structure:

```
For each node in [node5, node6, node2, node3, node4]:
  1. kubectl drain <node>
  2. reboot <node>
  3. wait for node Ready
  4. (if control plane) sleep 30
  5. kubectl uncordon <node>
  6. wait for all Longhorn volumes Healthy  ← gate between every node
```

The existing [ansible/update.yml](ansible/update.yml) handles the OS update + conditional reboot. The Longhorn health gate (step 6) and the kubectl drain/uncordon wrapping would need to be added.

Suggested Ansible modules for the gate:
- `kubernetes.core.k8s_info` — poll Longhorn volume objects
- `until` loop with `retries` and `delay` — wait for `robustness == Healthy`

---

## Reference

- [ansible/update.yml](ansible/update.yml) — existing OS update playbook
- [ansible/files/check_lh.sh](ansible/files/check_lh.sh) — Longhorn health check script
- [kubernetes/platform/system-upgrade/](kubernetes/platform/system-upgrade/) — k3s version upgrade automation (separate from OS reboots)
