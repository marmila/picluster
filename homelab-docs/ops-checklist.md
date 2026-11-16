# Ops checklist (November 2026)

A working list of what was done, which checks remain over the next days, and the open follow-ups.
Tick a box (`- [x]`) in a commit when an item is done; move finished sections to "Done" with the date.

Where commands run: `kubectl` and `flux` on **node2**, `make` / Ansible on **pimaster** (`~/picluster`),
RustFS disk and `rc` on **node1**.

---

## Done

### 14 Nov 2026
- [x] **Longhorn snapshot bloat fixed:**
  - Longhorn deletes the Velero backup snapshot right after the upload; the cleanup job fails on errors (`d4eaa57f`).
  - Cleanup purges one volume at a time (`5efad74e`).
  - Runbook LONGHORN-003 (`26dcf6ec`). Before this, Prometheus carried 110 GB of snapshots on a 50 GB volume.
- [x] **Triage agent phases 0–3:** workstation tests (`4d378a4a`), image (`ffab15cf`), credentials in
  `secret-files` and Vault (`32a7c1ad`), read-only deployment (`343ff6b2`, `62d98695`, `0f72f49c`).
- [x] **First full `make os-upgrade` run:** all nodes upgraded, masters and node1 included. The pre-flight
  stopped once (node6 overloaded by drained pods); the rerun went through (`d5b17a5d`).
- [x] **Prometheus prefers amd64 nodes** (`3b4a219c`).
- [x] **Rancher-move playbook written:** `move_rancher_to_storage.yml`, CLUSTER-012 step 6 (`04251c0f`).

### 15 Nov 2026
- [x] **Velero:** the failed backup was a passing API connection reset; a manual backup Completed.
- [x] **Prometheus excluded from Velero backups**, triage agent can read Leases (`a939279d`).
- [x] **node1:** 70 GB of orphaned Loki copies removed in RustFS, 86% → 54%; postmortem, OBS-004 step 6,
  CLUSTER-012 step 7 (`27f522c8`).
- [x] **Eviction threshold** confirmed at 95% (k3s), docs corrected (`b937274e`).
- [x] **PXE layout:** node-esp root LV is 80G for future reinstalls (`ac19f095`).
- [x] **Rancher move done on node-esp-1 and node-esp-2**, reboot-tested, root at about 30% (`2a19a78d`).
- [x] **Triage agent finished (phases 4–5):** Triage button added automatically by Stage 5 (`594f2167`),
  acceptance tests passed, runbook OBS-006, skill sees node1 disks and Velero (`d4bb25f7`).
- [x] **Journald cap** in effect on all nodes.
- [x] **Orphaned keycloak volume** deleted; runbook LONGHORN-004 (`1a3ba3ac`).
- [x] **OS-upgrade playbook:** capacity pre-flight on the other nodes, progress-based Longhorn wait,
  durations (`1d4caf87`); disk check uses available bytes (`2a78b2ae`, `4e8a6ee1`). Validated with
  `make os-upgrade-check`: all OK, 0 packages pending.
- [x] **Docs consistency check** (`acbd2330`).

---

## 1. Checks over the next days

### 16 Nov morning (node2)
- [x] Nightly Velero backup Completed, empty ERR
- [x] Newest Prometheus backup (`pvc-e1c0c8e4`) still 2026-11-15T03:27
- [x] 0 degraded Longhorn volumes, all nodes Ready, all Kustomizations True
- [x] node1 about 54%, no disk alerts

Outcome 2026-11-16: `full-20261116020024` Completed with no errors (the first nightly run since Prometheus was
excluded). No new Prometheus backup after 15 Nov. 0 degraded volumes, 7/7 nodes Ready, no Kustomization
not Ready. node1 `/` at 43%, below the expected 54%: the old backups are already expiring. Highest disk:
node5 `/storage` 67% (section 3).

```bash
echo "== velero =="; kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors | tail -3
echo "== prometheus not backed up =="; kubectl -n longhorn-system get backups.longhorn.io -o custom-columns=VOL:.status.volumeName,CREATED:.status.backupCreatedAt | grep pvc-e1c0c8e4
echo "== longhorn =="; ~/bin/lh-snaps.sh | tail -3
echo "== nodes =="; kubectl get nodes
echo "== flux =="; flux get kustomizations -A | grep -v True || echo "all True"
echo "== disks =="; P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
kubectl get --raw "${P}sort_desc%28100%20%2A%20%281%20-%20node_filesystem_avail_bytes%7Bjob%3D%22node-exporter%22%2Cfstype%21%3D%22%22%2Cmountpoint%3D~%22%2F%7C%2Fstorage%22%7D%20%2F%20node_filesystem_size_bytes%7Bjob%3D%22node-exporter%22%2Cfstype%21%3D%22%22%2Cmountpoint%3D~%22%2F%7C%2Fstorage%22%7D%29%20%2A%20on%20%28instance%29%20group_left%20%28nodename%29%20node_uname_info%7Bjob%3D%22node-exporter%22%7D%29" | jq -r '.data.result[] | "\(.metric.nodename) \(.metric.mountpoint) \(.value[1] | tonumber | floor)%"' | head -6
```
Or tap **Triage** on an alert notification.

### 17 Nov (node1): Loki retention deletes current data
- [ ] Count close to 0

```bash
sudo sh -c 'cd /storage/rustfs/k3s-loki && find fake -name xl.meta ! -newermt 2026-11-09 | wc -l'
```

### 18 Nov (node1): old Prometheus backups expired
- [ ] `/` below 54%
- [ ] `k3s-longhorn` well below 97 GB

```bash
df -h /
sudo sh -c 'du -sh /storage/rustfs/k3s-longhorn'
```

- [ ] **When all three days are OK:** close actions 1 and 4 in
  [the node1 postmortem](../postmortems/incident-2026-11-15-node1-disk-rustfs-loki-orphans.md).

---

## 2. node1 / RustFS follow-ups (read-only, node1)

- [ ] **2a. Live Loki objects with extra copies** (postmortem action 5):
  ```bash
  sudo sh -c 'for o in /storage/rustfs/k3s-loki/fake/*/*/; do [ -e "$o/xl.meta" ] || continue; n=$(find "$o" -mindepth 1 -maxdepth 1 -type d | wc -l); [ "$n" -gt 1 ] && echo x; done' | wc -l
  ```
- [ ] **2b. Orphaned objects in other buckets** (run in tmux):
  ```bash
  for b in k3s-longhorn k3s-tempo k3s-barman k3s-velero; do echo "== $b =="; sudo sh -c "find /storage/rustfs/$b -mindepth 1 -type d -name '*-*-*-*-*' -printf '%h\n' | sort -u | while read o; do [ -e \"\$o/xl.meta\" ] || echo \"\$o\"; done | wc -l"; done
  ```
  Expected for 2a and 2b: 0 or close.
- [ ] **2c. node1 `/var/log` (2.7 GB):**
  ```bash
  sudo du -xh --max-depth=2 /var/log | sort -h | tail -10
  ```
- [ ] **2d. Per-bucket size metric and growth alert** (postmortem action 7): proposal first.

---

## 3. Longhorn replica balance and node5

node5 has 13 replicas and 67% of `/storage`; node6 has 9 and 16%; node-esp-1 has 7, node-esp-2 has 13.
Replica auto-balance is off and scheduling stops at 90% (`storageMinimalAvailablePercentage: 10`), so not urgent.

- [ ] **Which volumes are on node5** (node2):
  ```bash
  kubectl -n longhorn-system get replicas.longhorn.io -o custom-columns=NODE:.spec.nodeID,VOL:.spec.volumeName --no-headers | grep '^node5' | awk '{print $2}' | while read v; do kubectl -n longhorn-system get volumes.longhorn.io "$v" -o jsonpath='{.status.kubernetesStatus.pvcName}{" "}{.spec.size}{"\n"}'; done | awk '{printf "%-45s %.0f GiB\n",$1,$2/1073741824}' | sort -k2 -n
  ```
- [ ] **node5 I/O** (node5): `iostat -x 5 3`
- [ ] Decide whether to move a few big replicas by hand.

---

## 4. Quick items
- [ ] Unsubscribe the old triage ntfy topic in the phone app (the one replaced on 15 Nov).
- [ ] **Certificates:** `kubectl get certificate -A`. `pi-cluster-tls` renews around 7 Dec.
- [ ] **Let's Encrypt automation** before February 2027.

---

## 5. Backlog
- [ ] **Pi root disks:** images live on root there (node6 48%, node5 44%). Watch only; the 80% alert and
  the 85% os-upgrade pre-flight cover it.
- [ ] **Triage agent:** `curl -4` if the reconnects come back; smaller image; token renewal reminder
  ([sre-triage-agent.md](sre-triage-agent.md) 9.2, also update `sre-triage.ini`); optionally rename the alerts topic.
- [ ] **fluent-bit:** raise the CPU limit.
- [ ] **Fixed ntfy action buttons** for known alerts.
- [ ] **RustFS upstream issue** (optional, postmortem action 10).
- [ ] **Hardware:** node1/node6 power cables; keep an eye on node3.
- [ ] **Small items:** vendor the SUC files; check the Kafka 4.3.0/4.3.1 pin;
  `RaspberryPiUnderVoltage` alert only after 2 dips.
- [ ] **Before any node-esp reinstall:** `make pxe-setup`.
