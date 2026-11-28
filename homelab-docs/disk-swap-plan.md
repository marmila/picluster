# Disk swap plan

Task list for phase 1 of [disk-replacement.md](disk-replacement.md): the 4 worn disks (node6, node4, node-esp-2,
node5), every command in order, ready to paste. The background, the rules and the other procedures (node2, node3,
node1) are in disk-replacement.md; if this list and that document disagree, disk-replacement.md wins and this list
gets fixed.

**Where commands run:** kubectl and flux on **node2**, Ansible on **pimaster** (from `~/picluster`), RustFS checks on
**node1**, drive preparation on the **laptop** (from `c:\Users\marco\bin\picluster`).

**Stop rule:** if a "you want" line is not met, stop and ask. Do not start the next node.

**Order and rules**

1. node6 (procedure A): BX500 1 TB `CT1000BX500SSD1`
2. node4 (procedure C, master; no Longhorn data, so no eviction): BX500 1 TB. Can follow node6 the same day, once
   node6 is fully green.
3. node-esp-2 (procedure B): Samsung 870 EVO 1 TB `MZ-77E1T0B/EU`
4. node5 (procedure A): BX500 1 TB. Can follow node-esp-2 the same day, under the conditions in section 5.

- One Longhorn eviction at a time (node6, node-esp-2, node5): the next one starts only when the previous node is
  back in the cluster and every volume is `healthy`, including the 4.9 copies. With one node out and its data
  rebuilding elsewhere, a second eviction would leave too few nodes for the copies.
- Never two masters out at the same time.
- Start a Longhorn eviction in the morning or early afternoon (node5: by about 14:00 UTC), never one that would
  run overnight: the eviction takes 1-6 hours, the swap and join about 1.5 hours more.

**Replicas: what changes and what comes back**

| Volume | Now | During the swaps | At the end |
|---|---|---|---|
| Elasticsearch, Prometheus | should be 2 copies on the mini PCs (postmortem 2026-11-22); 0.4 checks and removes any copy left on a Pi | 1 copy on node-esp-1 while node-esp-2 is out (4.1) | **2 copies, node-esp-1 + node-esp-2** (4.9). Not 3: the third would land on a Pi BX500 |
| Keycloak Postgres ×2, Loki write | 1 copy, `best-effort` locality (disk-replacement 2.4) | moved by the eviction, still 1 copy | **1 copy, unchanged**. Not back to 3: Postgres has 2 CNPG instances + barman backups, Loki write is only the log buffer |
| everything else (Kafka ×3, ...) | 3 copies | moved by the eviction | **3 copies** over node5, node6, node-esp-1, node-esp-2 |

The 1-copy setting is a live patch, not in Git: a recreated or restored PVC comes back with 3 copies. If the final
check (section 6) shows one of them at 3, reapply disk-replacement 2.4. Full table with the reasons:
disk-replacement section 9.

Plus what each swap switches off and must switch back on: the Longhorn scheduling on the Pis (0.4, 4.1, 4.9)
and the cordon on node5 (4.3 → 4.8). No app is scaled down and no Kustomization is suspended: the e-commerce app
is commented out in Git, threatmap is already disabled, and freqtrade stays running (2.2).

---

## 0. Before the first swap

### 0.1 Prepare the new drives (laptop, any day before)

The Pi drives are prepared completely before they go near a Pi: on swap day the old disk comes out of the node's
adapter, the prepared one goes in, and the node boots straight into its new system. This needs **one spare USB-SATA
adapter for the laptop** (USB 3, UAS); the node adapters stay in the nodes. Without one, do 0.1 for each drive on
its swap day, after the node is removed.

Each prepared Pi drive carries its node's hostname and IP: it fits only that node.

- [ ] Laptop: install Raspberry Pi Imager and CrystalDiskInfo; download the image named in `metal/rpi/Makefile`
(`ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz`).
- [ ] For **each** drive (3 BX500, 1 870 EVO), in the spare adapter: CrystalDiskInfo.
You want: health Good, reallocated sectors 0, power-on hours near 0. Write model and serial in the progress
table (disk-replacement.md 10).
For **each BX500**, with its node (`node6` → `16`, `node4` → `14`, `node5` → `15`):

- [ ] **Write the image:** Raspberry Pi Imager, **Choose OS → Use custom** → the `.img.xz`; **Choose storage** →
  the BX500 (about 1 TB, check the size and that it is the USB disk: if the laptop has an internal disk of the same size, compare the serial with CrystalDiskInfo); OS customisation **No**; Write.
- [ ] **Write the node's config:** unplug and plug the drive back. PowerShell from `c:\Users\marco\bin\picluster`,
  with `$NODE`, `$IP` and `$BOOT` (the `system-boot` drive letter) set for this drive:

```powershell
$NODE = "node6"; $IP = "16"; $BOOT = "E:"
$ud = (Get-Content metal\rpi\cloud-init\nodes\user-data-SSD-partition -Raw).Replace("`r`n", "`n") -creplace 'nodeX', $NODE
$nc = (Get-Content metal\rpi\cloud-init\nodes\network-config -Raw).Replace("`r`n", "`n") -creplace 'X', $IP
[IO.File]::WriteAllText("$BOOT\user-data", $ud)
[IO.File]::WriteAllText("$BOOT\network-config", $nc)
Select-String -Path "$BOOT\user-data" -Pattern "hostname:", "ssh-rsa"; Select-String -Path "$BOOT\network-config" -Pattern "10.0.0."
```

You want: `hostname: <node>`, two `ssh-rsa` lines ending in `marmila@pimaster` (the key Ansible uses) and
`marmila@node1`, and `10.0.0.<IP>/24`. Password login is locked, so a wrong key means no access after the first
boot: if the keys on a running node change, update the template first (`ssh marmila@10.0.0.16 cat .ssh/authorized_keys`).

- [ ] **Eject** and label the drive **"<node> NEW"**.

Then:

- [ ] The **870 EVO** (node-esp-2): only the CrystalDiskInfo check and a **"node-esp-2 NEW"** label. Its system is
installed over PXE once it sits in the mini PC (4.4): the installer has to run on that machine.
- [ ] If `metal/rpi/cloud-init/` changes in git after a drive was prepared: redo "Write the node's config" for that drive.

### 0.2 Update pimaster

- [ ] Run:

```bash
cd ~/picluster && git pull
```

### 0.3 Pre-flight (node2, look only)

- [ ] Run:

```bash
echo "== nodes"; kubectl get nodes
echo "== volumes not healthy"; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness | grep -v healthy
echo "== longhorn space"; kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | .status.diskStatus | to_entries[] | "\($n) avail=\(.value.storageAvailable/1e9|floor)G scheduled=\(.value.storageScheduled/1e9|floor)G max=\(.value.storageMaximum/1e9|floor)G"'
echo "== load"; kubectl top nodes
```

You want: every node `Ready`, no volume `degraded`, no node above about 80% CPU.

### 0.4 Elasticsearch and Prometheus: no copy on a Pi (node2)

These helpers are used again in 4.1 and 4.9; paste them in every new node2 shell:

```bash
ES=$(kubectl -n elastic get pvc elasticsearch-data-efk-es-default-0 -o jsonpath='{.spec.volumeName}')
PROM=$(kubectl -n kube-prom-stack get pvc prometheus-kube-prometheus-stack-db-prometheus-kube-prometheus-stack-0 -o jsonpath='{.spec.volumeName}')
reps() {
  kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg es "$ES" --arg pr "$PROM" '.items[] | select(.spec.volumeName==$es or .spec.volumeName==$pr) | "\(if .spec.volumeName==$es then "elasticsearch" else "prometheus" end)\t\(.spec.nodeID)\t\(.status.currentState)\t\(.metadata.name)"' | sort
  for v in $ES $PROM; do kubectl -n longhorn-system get volumes.longhorn.io $v -o jsonpath='{.metadata.name} replicas={.spec.numberOfReplicas} {.status.robustness}{"\n"}'; done
}
sched() { for n in "${@:2}"; do kubectl -n longhorn-system patch nodes.longhorn.io $n --type merge -p "{\"spec\":{\"allowScheduling\":$1}}"; done; }
reps
```

- [ ] You want: per volume `replicas=2`, rows on node-esp-1 and node-esp-2 only, `running`, `healthy`. Then go
to section 1.
- [ ] Only if a row shows **node5 or node6**: remove that copy, so the node6/node5 evictions do not move it to the
other worn Pi. Do it only when the same volume also has `running` rows on node-esp-1 **and** node-esp-2:

```bash
sched false node5 node6                                                   # no new copies on the Pis meanwhile
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg es "$ES" --arg pr "$PROM" '.items[] | select((.spec.volumeName==$es or .spec.volumeName==$pr) and (.spec.nodeID|test("^node[0-9]"))) | .metadata.name' | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io
for v in $ES $PROM; do kubectl -n longhorn-system patch volumes.longhorn.io $v --type merge -p '{"spec":{"numberOfReplicas":2}}'; done
sched true node5 node6
reps
```

You want: the state of the first box.

---

## 1. Morning gate (before every swap)

- [ ] **node2:** last backup and Longhorn backup target:

```bash
kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors,WARN:.status.warnings | tail -3
kubectl -n longhorn-system get backuptargets.longhorn.io default -o custom-columns=AVAILABLE:.status.available,LASTSYNC:.status.lastSyncedAt
```

You want: the newest `full-...` `Completed` with ERR `<none>`, and `AVAILABLE` `true`.
No backup `Completed` = no swap that day.
- [ ] **node1:** RustFS timeouts last night, per hour:

```bash
D=$(date -u +%F)
sudo sh -c 'cat /var/log/rustfs/*' | grep -i timeout | grep -oE "\"timestamp\":\"${D}T[0-9]{2}" | cut -c25- | sort | uniq -c
```

You want: nothing or a few dozen. Hundreds at `02`: node1's disk is saturating again (postmortem
2026-11-15, action 11); stop and ask.
- [ ] **pimaster:** no USB resets on the Pis:

```bash
cd ~/picluster
./ansible-runner/ansible-runner.sh ansible raspberrypi -b -m shell -a 'dmesg -T | grep -iE "reset|i/o error" | grep -v "Power-on or device reset" | tail -3'
```

You want: no output. `Power-on or device reset occurred` is filtered out: the kernel prints it for every disk
that appears, also for each Longhorn volume attached over iSCSI (`IET VIRTUAL-DISK`, `sdb`, `sdc`, ...). A real
USB problem shows as `usb ...: reset SuperSpeed USB device`, `uas_eh_abort_handler` or `I/O error`.

- [ ] **node2:** pre-flight (0.3) and `reps` (0.4).

---

## 2. node6 (procedure A)

### 2.1 Checks

- [ ] Section 1 green.

### 2.2 Apps: nothing to scale down, freqtrade stays up (node2)

Nothing heavy is left to stop: the e-commerce app and its databases are commented out in Git (only its Keycloak,
Kafka, common and monitoring config is applied), threatmap is disabled, and the freqtrade backtest CronJob is
`suspend: true`. Freqtrade itself (1 pod, 100m CPU / 256Mi, 2 × 2 Gi volumes) keeps running: when its node is
drained it restarts on another one in 1-2 minutes (`Recreate`, never two bots), trades and state are on its volume.

- [ ] Run:

```bash
kubectl -n e-commerce get deploy,statefulset --no-headers 2>/dev/null | wc -l
kubectl -n trading get pods -o wide
kubectl -n trading get cronjob freqtrade-backtest -o jsonpath='{.spec.suspend}{"\n"}'
```

You want: `0`; freqtrade `Running 1/1`; `true`. If the first number is not 0, the e-commerce app was re-enabled:
scale it down as in disk-replacement 4.2.

### 2.3 Keycloak Postgres check (node2)

node6 holds the only copy of one Keycloak Postgres instance (1 replica).

- [ ] Run:

```bash
kubectl -n databases get pods -o wide | grep postgres-keycloak | awk '{print $1, $3, $(NF-2)}'
kubectl -n databases get cluster postgres-keycloak -o jsonpath='{"last backup: "}{.status.lastSuccessfulBackup}{"\n"}{range .status.conditions[?(@.type=="ContinuousArchiving")]}{"WAL archiving: "}{.status}{"\n"}{end}'
```

You want: both pods `Running`, a backup from last night, `WAL archiving: True`.

### 2.4 Move Longhorn data off node6 (node2, 1-6 h)

- [ ] Run:

```bash
N=node6
kubectl -n longhorn-system patch nodes.longhorn.io $N --type merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
watch -n 30 "kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID==\"$N\")]|length'; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded"
```

You want: both numbers `0` (replicas on node6, degraded volumes). If they stop moving for 30 minutes, stop
and paste the pre-flight block.

### 2.5 Drain, power off, remove

- [ ] node2: `kubectl drain node6 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s`
- [ ] node6: `sudo poweroff`
- [ ] node2:

```bash
kubectl delete node node6
kubectl -n kube-system delete secret node6.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node6
```

### 2.6 Swap the drive

- [ ] Take the adapter off the old disk; label the old disk **"node6 old"** with the date and keep it for a week.
- [ ] Put the drive labelled **"node6 NEW"** (0.1) in the adapter. Not prepared yet: do 0.1 for it now.

### 2.7 First boot and speed test (node6)

- [ ] Connect the adapter to the **same blue USB 3 port**, **network cable plugged in first** (a first boot without network leaves SSH refused: re-image, see 0.1), power on, wait 5 minutes:

```bash
hostname; ip -4 addr show eth0 | grep inet
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT | grep -v loop
lsusb -t | grep -i -A1 storage
sudo dmesg -T | grep -iE "uas|reset|error" | grep -v "Power-on or device reset" | tail
```

You want: `node6`, `10.0.0.16`; `/` about 50G and `/storage` about 880G; `Driver=uas, 5000M`; no `reset`.
- [ ] Speed test (mandatory on node6: it validates the BX500 on the adapter):

```bash
sudo apt-get update -qq && sudo apt-get install -y -qq fio
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=randwrite --bs=4k --iodepth=16 --direct=1 --ioengine=libaio --runtime=60 --time_based --group_reporting | grep -E "IOPS|lat \(usec\)|clat percentiles" -A1 | head -8
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=write --bs=1M --iodepth=8 --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting | grep -E "bw=|IOPS"
sudo rm -f /storage/.fio; sudo dmesg -T | grep -iE "uas|reset|abort|error" | grep -v "Power-on or device reset" | tail -5
```

You want: thousands of IOPS, hundreds of MB/s, no `uas`/`reset`/`abort` lines. UAS resets: stop and paste.

### 2.8 Join the cluster (pimaster)

A full OS upgrade and reboot first (the image is older than the running nodes), then the same playbooks as `make init` for a node (`nodes-setup`, `configure-os-backup`, `k3s-install`), limited to the
node, plus `update_node_config.yml` (Pi throttling metrics, USB TRIM rule, SMART metrics, journald and kubelet
config). With `--limit` the token comes from Vault and the server address is the API VIP (`k3s_api_vip`), so no
other node is needed in the run; only the worker label play (hosts `k3s_master`) is skipped, so 2.9 sets that label
by hand (cosmetic: the `ROLES` column, no manifest uses it).

- [ ] Run:

```bash
cd ~/picluster
ssh-keygen -R node6; ssh-keygen -R 10.0.0.16
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node6; ssh-keygen -R 10.0.0.16' || true
./ansible-runner/ansible-runner.sh ansible node6 -m ping
./ansible-runner/ansible-runner.sh ansible node6 -b -m apt -a 'update_cache=yes upgrade=dist autoremove=yes lock_timeout=600'   # full OS upgrade, before k3s
./ansible-runner/ansible-runner.sh ansible node6 -b -m reboot -a 'reboot_timeout=900'
./ansible-runner/ansible-runner.sh ansible node6 -b -m shell -a 'uname -r; echo pending=$(apt-get -s dist-upgrade | grep -c ^Inst); test -f /var/run/reboot-required && echo REBOOT-REQUIRED || echo no-reboot-needed'
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node6
```

You want: after the upgrade `pending=0` and `no-reboot-needed` (the new image is months behind: the full OS upgrade runs before k3s, so no drain is needed); every playbook green (`failed=0`).

### 2.9 Check

- [ ] node2:

```bash
kubectl label node node6 kubernetes.io/role=worker --overwrite   # k3s_install.yml skips its label play with --limit
kubectl get node node6 -o wide
kubectl -n longhorn-system get nodes.longhorn.io node6
kubectl -n longhorn-system get nodes.longhorn.io node6 -o json | jq -r '.status.diskStatus | to_entries[] | "\(.value.diskPath // .key) max=\(.value.storageMaximum/1e9|floor)G"'
kubectl get pods -A -o wide --field-selector spec.nodeName=node6 | grep -vE "Running|Completed"
```

You want: `Ready`; Longhorn `READY True`, `SCHEDULABLE True` (the new Longhorn node starts with scheduling on:
nothing to switch back), disk `/storage`; no pod in another state.
- [ ] node6, SMART baseline and TRIM:

```bash
sudo apt-get install -y -qq --no-install-recommends smartmontools
sudo smartctl -i -H -A -d sat /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
cat /sys/block/sda/device/scsi_disk/*/provisioning_mode
lsblk -D -d -o NAME,DISC-GRAN,DISC-MAX /dev/sda
sudo fstrim -v /storage && sudo fstrim -v /
sudo dmesg -T | grep -iE "sda|uas|reset|i/o error" | grep -v "Power-on or device reset" | tail
```

You want: `PASSED`; `unmap`; `DISC-MAX` `2G`; two "trimmed" lines; no reset or I/O error. Fill in the
progress table (disk-replacement.md 10).

### 2.10 Final check (node2)

- [ ] Run:

```bash
kubectl -n trading get pods -o wide
reps
```

You want: freqtrade `Running 1/1` (on any node); Elasticsearch and Prometheus unchanged (2 copies, mini PCs;
`reps` from 0.4, paste the helpers again in a new shell).

node4 only if everything in 2.9 is green.

---

## 3. node4 (procedure C, master)

node4 is an etcd member with no Longhorn data, so no eviction: about 1.5 hours. Start only with the three masters
`Ready`. etcd keeps running on node2 and node3 (2 of 3).

### 3.1 etcd snapshot (node2)

- [ ] Run:

```bash
kubectl get nodes | grep control-plane                    # node2, node3, node4 Ready
kubectl get --raw='/readyz?verbose' | grep etcd           # [+]etcd ok
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID=="node4")]|length'
sudo k3s etcd-snapshot save --name pre-swap-node4
sudo k3s etcd-snapshot list | tail -3
```

You want: three masters `Ready`, `[+]etcd ok`, **0** Longhorn replicas on node4 (if not 0: run 2.4 with
`N=node4` first), the new `pre-swap-node4` snapshot in the list.

### 3.2 Drain, power off, remove

- [ ] node2: `kubectl drain node4 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s`
- [ ] node4: `sudo poweroff`
- [ ] node2:

```bash
kubectl delete node node4
kubectl -n kube-system delete secret node4.node-password.k3s --ignore-not-found
sleep 30
kubectl get --raw='/readyz?verbose' | grep etcd
kubectl get nodes | grep control-plane
```

You want: `[+]etcd ok`; node2 and node3 `Ready`.

### 3.3 Swap the drive

- [ ] Old disk out, labelled **"node4 old"** with the date; the drive labelled **"node4 NEW"** in.

### 3.4 First boot (node4)

- [ ] Same blue USB 3 port, **network cable plugged in first**, power on, wait 5 minutes:

```bash
hostname; ip -4 addr show eth0 | grep inet
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT | grep -v loop
lsusb -t | grep -i -A1 storage
sudo dmesg -T | grep -iE "uas|reset|error" | grep -v "Power-on or device reset" | tail
```

You want: `node4`, `10.0.0.14`, `Driver=uas, 5000M`, no `reset`.

- [ ] Speed test of 2.7 (mandatory here too: node4's drive has firmware M6CR072, node6's M6CR061; progress table
  in disk-replacement.md 10). Same "you want".

### 3.5 Join as a **secondary** master (pimaster)

- [ ] Run:

```bash
cd ~/picluster
ssh-keygen -R node4; ssh-keygen -R 10.0.0.14
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node4; ssh-keygen -R 10.0.0.14' || true
./ansible-runner/ansible-runner.sh ansible node4 -m ping
./ansible-runner/ansible-runner.sh ansible node4 -b -m apt -a 'update_cache=yes upgrade=dist autoremove=yes lock_timeout=600'   # full OS upgrade, before k3s
./ansible-runner/ansible-runner.sh ansible node4 -b -m reboot -a 'reboot_timeout=900'
./ansible-runner/ansible-runner.sh ansible node4 -b -m shell -a 'uname -r; echo pending=$(apt-get -s dist-upgrade | grep -c ^Inst); test -f /var/run/reboot-required && echo REBOOT-REQUIRED || echo no-reboot-needed'
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node4
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node4
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node4 -e '{"k3s_primary_control_node": false}'
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node4
```

You want: after the upgrade `pending=0` and `no-reboot-needed`; every playbook green.

**`-e '{"k3s_primary_control_node": false}'` is mandatory** (JSON: `=false` would be the string "false", which is true): without it node4 could start a new, empty cluster.
(The role already treats only the first master in the inventory, node2, as primary; the extra var overrides
that and is the safety net. For node2's own swap it is what prevents `cluster-init`.)
- [ ] Right after `k3s_install.yml`, on node4:

```bash
sudo grep -nE "cluster-init|^server:" /etc/rancher/k3s/config.yaml
```

You want: a `server: https://...:6443` line and **no** `cluster-init`. If `cluster-init` shows:
`sudo systemctl stop k3s` at once and stop.

### 3.6 Check

- [ ] node2:

```bash
kubectl get nodes | grep control-plane
kubectl get --raw='/readyz?verbose' | grep etcd
kubectl -n kube-system get pods -o wide | grep -E "kube-vip|coredns|cilium-operator"
kubectl get pods -A -o wide --field-selector spec.nodeName=node4 | grep -vE "Running|Completed"
```

You want: three masters `Ready`, `[+]etcd ok`, those pods `Running`, nothing broken on node4.
- [ ] `kubectl -n trading get pods -o wide`: freqtrade `Running 1/1`.
- [ ] node4, SMART baseline and TRIM:

```bash
sudo apt-get install -y -qq --no-install-recommends smartmontools
sudo smartctl -i -H -A -d sat /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
cat /sys/block/sda/device/scsi_disk/*/provisioning_mode
lsblk -D -d -o NAME,DISC-GRAN,DISC-MAX /dev/sda
sudo fstrim -v / ; sudo fstrim -v /storage 2>/dev/null
sudo dmesg -T | grep -iE "sda|uas|reset|i/o error" | grep -v "Power-on or device reset" | tail
```

You want: `PASSED`, `unmap`, `DISC-MAX` `2G`, "trimmed", no errors. Fill in the progress table.

---

## 4. node-esp-2 (procedure B)

node-esp-2 holds one of the two copies of Elasticsearch and Prometheus; the other is on node-esp-1. While
node-esp-2 is out they run on **one copy** (node-esp-1) instead of letting the eviction put the second copy on a
Pi; 4.9 gives the second copy back on the new disk. Elasticsearch is in the nightly backup; Prometheus is not
(metrics only).

### 4.1 Checks and replicas (node2)

- [ ] Section 1 green; 2.2 (check) again. You want also: node6 already holding Longhorn data (`scheduled=`
above 0 in the pre-flight).
- [ ] Elasticsearch and Prometheus down to the node-esp-1 copy (helpers from 0.4):

```bash
reps                                                                     # one running copy on node-esp-1 and one on node-esp-2, per volume
sched false node5 node6 node-esp-2                                       # nowhere to rebuild meanwhile
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq -r --arg es "$ES" --arg pr "$PROM" '.items[] | select((.spec.volumeName==$es or .spec.volumeName==$pr) and .spec.nodeID=="node-esp-2") | .metadata.name' | xargs -r kubectl -n longhorn-system delete replicas.longhorn.io
for v in $ES $PROM; do kubectl -n longhorn-system patch volumes.longhorn.io $v --type merge -p '{"spec":{"numberOfReplicas":1}}'; done
sched true node5 node6                                                   # node-esp-2 stays off: the eviction is next
sleep 30; reps
```

You want: per volume one row, node-esp-1, `running`; `replicas=1 healthy`. Do not delete anything if the
first `reps` does not show a running copy on node-esp-1 for both volumes.

### 4.2 Move the rest of the Longhorn data off node-esp-2 (node2, 1-6 h)

- [ ] Run:

```bash
N=node-esp-2
kubectl -n longhorn-system patch nodes.longhorn.io $N --type merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
watch -n 30 "kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID==\"$N\")]|length'; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded"
```

You want: both numbers `0`.

### 4.3 Keep heavy pods off the worn disk, drain, power off, remove

node5 is the last worn disk by now. Cordon it only if node-esp-1 is below about 60% CPU and 70% memory.

- [ ] node2:

```bash
kubectl top node node-esp-1
kubectl cordon node5
kubectl drain node-esp-2 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
kubectl get pods -A -o wide | grep -E "Pending|ContainerCreating|CrashLoop"
```

Repeat the last line until it prints nothing.
- [ ] node-esp-2: `sudo poweroff`
- [ ] node2:

```bash
kubectl delete node node-esp-2
kubectl -n kube-system delete secret node-esp-2.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node-esp-2
```

### 4.4 Fit the 870 EVO and reinstall over PXE

- [ ] Swap the drive inside the mini PC: the old one labelled **"node-esp-2 old"** with the date, kept for a week;
the **"node-esp-2 NEW"** drive in.
- [ ] pimaster:

```bash
cd ~/picluster && make pxe-setup
```

- [ ] Power on node-esp-2, open the boot menu, choose **network boot (PXE, IPv4)**. The autoinstall runs by itself
(10-15 minutes) and reboots into Ubuntu.

### 4.5 Join the cluster (pimaster)

- [ ] Run:

```bash
cd ~/picluster
ssh-keygen -R node-esp-2
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node-esp-2' || true
./ansible-runner/ansible-runner.sh ansible node-esp-2 -m ping
./ansible-runner/ansible-runner.sh ansible node-esp-2 -b -m apt -a 'update_cache=yes upgrade=dist autoremove=yes lock_timeout=600'   # full OS upgrade, before k3s
./ansible-runner/ansible-runner.sh ansible node-esp-2 -b -m reboot -a 'reboot_timeout=900'
./ansible-runner/ansible-runner.sh ansible node-esp-2 -b -m shell -a 'uname -r; echo pending=$(apt-get -s dist-upgrade | grep -c ^Inst); test -f /var/run/reboot-required && echo REBOOT-REQUIRED || echo no-reboot-needed'
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node-esp-2
```

You want: after the upgrade `pending=0` and `no-reboot-needed`; every playbook green.

### 4.6 Check the node

- [ ] node-esp-2:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
findmnt /var/lib/rancher
sudo smartctl -i -H -A /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
```

You want: `/` 80G, `/storage` about 850G; `/var/lib/rancher` on `/storage/rancher`;
`Samsung SSD 870 EVO 1TB`, `PASSED`.
- [ ] node2:

```bash
kubectl label node node-esp-2 kubernetes.io/role=worker --overwrite
kubectl get node node-esp-2 -o wide
kubectl -n longhorn-system get nodes.longhorn.io node-esp-2
kubectl get pods -A -o wide --field-selector spec.nodeName=node-esp-2 | grep -vE "Running|Completed"
```

You want: `Ready`; Longhorn `READY True`, `SCHEDULABLE True`, disk `/storage`; no pod in another state.

### 4.7 Uncordon node5 (node2)

- [ ] `kubectl uncordon node5`

### 4.8 Freqtrade check (node2)

- [ ] `kubectl -n trading get pods -o wide`: freqtrade `Running 1/1` (`reps` comes in 4.9).

### 4.9 Elasticsearch and Prometheus: second copy back on node-esp-2 (node2)

- [ ] Helpers from 0.4 (new shell: paste them again), then:

```bash
sched false node5 node6                                                  # the new copy can only go to node-esp-2
for v in $ES $PROM; do kubectl -n longhorn-system patch volumes.longhorn.io $v --type merge -p '{"spec":{"numberOfReplicas":2}}'; done
watch -n 30 'kubectl -n longhorn-system get volumes.longhorn.io '"$ES $PROM"' -o custom-columns=NAME:.metadata.name,REPLICAS:.spec.numberOfReplicas,ROBUST:.status.robustness'
```

Wait until both are `healthy` (the rebuild copies the whole volume: minutes to an hour), then:

```bash
sched true node5 node6
reps
kubectl -n longhorn-system get nodes.longhorn.io
```

You want: per volume `replicas=2`, rows on node-esp-1 and node-esp-2, `running`, `healthy`; every Longhorn
node `SCHEDULABLE True`.

---

## 5. node5 (procedure A)

node5 can follow node-esp-2 the same day. Start only when **all** of these are true; if one is not, node5 waits for
the next morning (section 1 again):

- [ ] node-esp-2 done including **4.9**: Elasticsearch and Prometheus `replicas=2 healthy`, and no volume
  `degraded` (node2):

```bash
reps
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded
kubectl -n trading get pods -o wide | grep freqtrade-
```

You want: `reps` as in 4.9, `0`, freqtrade `Running`.
- [ ] node6 stable on the new BX500 since its swap: no USB/UAS reset or I/O error (pimaster):

```bash
cd ~/picluster
./ansible-runner/ansible-runner.sh ansible node6 -b -m shell -a 'dmesg -T | grep -iE "reset|uas|abort|i/o error" | grep -v "Power-on or device reset" | tail -5'
```

You want: no output.
- [ ] It is no later than about **14:00 UTC** (the node5 eviction in 2.4 takes 1-6 h, then about 1.5 h for the
  swap, OS upgrade and join). Later: node5 the next morning.

Then:

- [ ] Section 2 with `node5` and IP `15` everywhere: `N=node5`; `kubectl drain node5`; the secret
`node5.node-password.k3s`; the **"node5 NEW"** drive; `ssh-keygen -R node5; ssh-keygen -R 10.0.0.15`;
`--limit node5`; label and checks on node5.
- [ ] 2.3 (Keycloak check) is mandatory: node5 holds the only copy of the other Keycloak Postgres instance.
- [ ] `fio` (2.7) is optional: node6 validated the BX500.

---

## 6. After the swaps

- [ ] **First Monday after the Pi swaps** (one check covers node6, node4 and node5 when they were all swapped in
  the same week; TRIM itself is already checked by hand in 2.9): the weekly `fstrim.timer` ran cleanly (pimaster):

```bash
cd ~/picluster
./ansible-runner/ansible-runner.sh ansible raspberrypi -b -m shell -a 'systemctl status fstrim.service --no-pager | tail -4; dmesg -T | grep -iE "reset|i/o error" | grep -v "Power-on or device reset" | tail -3'
```

You want: "trimmed" lines, no reset or I/O error.
- [ ] **Final replica check** (node2, helpers from 0.4):

```bash
reps
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,PVC:.status.kubernetesStatus.pvcName,REPLICAS:.spec.numberOfReplicas,ROBUST:.status.robustness | sort -k3
kubectl -n longhorn-system get nodes.longhorn.io
```

You want: Elasticsearch and Prometheus 2 copies on the mini PCs; Keycloak Postgres ×2 and `data-loki-write-0`
at 1; everything else 3; every volume `healthy`; every Longhorn node `SCHEDULABLE True`; node5 not
`SchedulingDisabled` in `kubectl get nodes`. A Keycloak Postgres or Loki write volume at 3 means its PVC was
recreated: reapply disk-replacement 2.4 (check the current Keycloak PVC names first, CNPG may have renamed them).
- [ ] **Two weeks after each swap:** write amplification. Crucial drives only (attributes 247/248); expected 3 or
lower with TRIM. node2:

```bash
P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
Q='1 + increase(smartmon_attr_raw_value{id="248"}[7d]) / increase(smartmon_attr_raw_value{id="247"}[7d])'
kubectl get --raw "${P}$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$Q")" | jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1] | tonumber | . * 10 | round / 10)"' | sort
```

- [ ] **After the last of the 4 swaps:** expire the `DiskWornOut` silence (disk-replacement.md 9):

```bash
AM="kubectl -n kube-prom-stack exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093"
$AM silence expire e33eec49-ba6e-4267-99c4-d968f0e331d3
```

- [ ] **A week after each swap, new drive clean:** the old disk can go.
