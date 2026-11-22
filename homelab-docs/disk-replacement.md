# Disk replacement: every node, one at a time, no downtime

Plan and procedure to replace the SSD of every node, made after the 2026-11-22 incident
([postmortem](../postmortems/incident-2026-11-22-elasticsearch-slow-longhorn-pi-disks.md)). The cluster keeps
running during each swap; only node1 (Vault, RustFS, DNS, outside k3s) needs a short planned downtime.

## Contents

- [1. Why](#1-why)
- [2. New disks: model, size, compatibility](#2-new-disks-model-size-compatibility)
- [3. Order](#3-order)
- [4. Rules for every swap](#4-rules-for-every-swap)
- [5. Procedure A: Raspberry Pi Longhorn worker (node5, node6)](#5-procedure-a-raspberry-pi-longhorn-worker-node5-node6)
- [6. Procedure B: x86 worker (node-esp-1, node-esp-2)](#6-procedure-b-x86-worker-node-esp-1-node-esp-2)
- [7. Procedure C: master (node4, node3, node2)](#7-procedure-c-master-node4-node3-node2)
- [8. Procedure D: node1 (clone, short downtime)](#8-procedure-d-node1-clone-short-downtime)
- [9. After all Longhorn nodes are done](#9-after-all-longhorn-nodes-are-done)
- [10. Progress](#10-progress)

---

## 1. Why

SMART on 2026-11-22 (all nodes):

| Node | Current drive | Lifetime used | Errors | Holds |
|---|---|---|---|---|
| node-esp-2 | Crucial MX500 500 GB, SATA | **109%** | **1,754 reported uncorrectable, 6 offline uncorrectable, 2 reallocations** | Longhorn (ES + Prometheus copies) |
| node6 | Crucial BX500 240 GB, USB | **100%** `FAILING_NOW` | none | Longhorn |
| node5 | Crucial BX500 480 GB, USB | **100%** `FAILING_NOW` | 92 CRC (adapter/cable) | Longhorn |
| node4 | Crucial BX500 240 GB, USB | **100%** `FAILING_NOW` | none | etcd |
| node3 | 240 GB, USB | 47% | none | etcd |
| node2 | 240 GB, USB | 35% | 10 CRC | etcd |
| node1 | 240 GB, USB | 37% | 7 CRC | Vault, RustFS, DNS |
| node-esp-1 | Crucial BX500 480 GB, SATA | 34% | none | Longhorn (ES + Prometheus copies) |

Budget DRAM-less drives (BX500) without TRIM (the Pi USB bridges report `DISC-MAX 0B`) wear out in about two
years under Longhorn and etcd writes, and slow to hundreds of milliseconds per write long before they fail. That
stalled node5 and node6 on 2026-11-22. All disks are replaced, with bigger and much more durable ones.

## 2. New disks: model, size, compatibility

### 2.1 What to buy

All nodes take a **2.5" SATA SSD**: the Pis through their existing USB-SATA adapter, the mini PCs internally.
Choose drives with DRAM cache and high endurance (TBW). Avoid DRAM-less and QLC drives (Crucial BX500, Samsung
QVO, Crucial P-series).

| Node | Role | Now | **New size** | Why this size |
|---|---|---|---|---|
| node-esp-1 | Longhorn worker | 480 GB | **1.92 TB** | Longhorn data; most writes in the cluster |
| node-esp-2 | Longhorn worker | 500 GB | **1.92 TB** | same |
| node5 | Longhorn worker (Pi) | 480 GB | **1.92 TB** | same |
| node6 | Longhorn worker (Pi) | 240 GB | **1.92 TB** | same |
| node2, node3, node4 | masters, etcd | 240 GB | **480 GB** | etcd needs endurance and low latency, not space |
| node1 | Vault, RustFS backups, DNS | 240 GB | **1.92 TB** | RustFS backups grow (node1's disk was at 86%) |

Longhorn raw capacity goes from about 1.4 TB to about 7.4 TB (about 2.4 TB usable with 3 replicas).

Recommended models (both 2.5" SATA, DRAM cache):

| Model | 480 GB | 1.92 TB | Notes |
|---|---|---|---|
| **Kingston DC600M** (data-center) | 876 TBW | 3,504 TBW | Power-loss protection makes `fsync` fast: best for etcd and Longhorn. First choice |
| WD Red SA500 (NAS) | 350 TBW (500 GB) | 1,300 TBW (2 TB) | Cheaper alternative |
| Crucial MX500 | 180 TBW (500 GB) | 700 TBW (2 TB) | Cheapest that is fine: DRAM cache, low power, common on Pis. Only the **2 TB** for Longhorn nodes / node1 and **500 GB** for masters. At this cluster's rates (node5 ~55 TB/year, masters ~23 TB/year) that is 8–12 years. Firmware M3CR043 or newer (`smartctl -i`) |

For comparison, node-esp-2's MX500 500 GB is rated 180 TBW and had written about 187 TB.

### 2.2 Raspberry Pi compatibility (checked 2026-11-22)

On a Pi the part that must be compatible is the **USB-SATA adapter**, not the SSD: the Pi only sees the
adapter's bridge chip, which then speaks plain SATA to any 2.5" SSD. Checked on all six Pis:

| Pi | Model | Adapter (`lsusb`) | Driver / link |
|---|---|---|---|
| node1, node2, node3, node5, node6 | Raspberry Pi 4 Model B Rev 1.5 | `14b0:0207` StarTech USB-SATA | `uas`, 5000M |
| node4 | Raspberry Pi 4 Model B Rev 1.5 | `14b0:0206` StarTech USB-SATA (older revision) | `uas`, 5000M |

These StarTech adapters are widely used on the Pi 4, and these ones have run the BX500s with UAS for two years.
So **all drives can be bought at once**; keep the adapters. Conditions:

1. **2.5" SATA** drive (not NVMe, not mSATA, not M.2).
2. **Max power ≤ 4 W** in the drive's datasheet: the Pi 4 gives about 1.2 A (6 W) to all its USB ports
   together. Use the official 3 A power supply and nothing else on the Pi's USB ports.
3. **One new StarTech adapter of the same model for node5** (its current one logs 92 CRC errors).
4. The `fio` + `dmesg` check in procedure A5 stays as a **check after each swap**, not a reason to wait before
   buying.

### 2.3 Shopping list

| Qty | Item | For |
|---|---|---|
| 5 | Kingston DC600M **1.92 TB** 2.5" SATA (or WD Red SA500 2 TB, or Crucial MX500 2 TB) | node-esp-1, node-esp-2, node5, node6, node1 |
| 3 | Kingston DC600M **480 GB** 2.5" SATA (or WD Red SA500 500 GB, or Crucial MX500 500 GB) | node2, node3, node4 |
| 1 | StarTech USB 3.0 to 2.5" SATA adapter, same model as the others | node5 |

Before ordering, check the max power line of the exact model in its datasheet (condition 2).

## 3. Order

One node per day at most. Each swap waits for Longhorn to be fully healthy before the next.

| # | Node | Procedure | Why this position |
|---|---|---|---|
| 1 | node6 | A | Worst Pi disk; first run of the new drive in a Pi adapter (A5 check) |
| 2 | node-esp-2 | B | Disk with errors. After node6, so its ES/Prometheus copies move to a healthy disk |
| 3 | node5 | A | Worn; new adapter too |
| 4 | node-esp-1 | B | Size upgrade |
| 5 | node4 | C | Worn etcd disk |
| 6 | node3 | C | Size/endurance |
| 7 | node2 | C | Last master: it is the first master in the inventory (see 7, the `-e` flag) |
| 8 | node1 | D | Needs a short downtime; plan a quiet evening |

## 4. Rules for every swap

- **One node at a time.** The next one only when the previous is `Ready`, Longhorn has **no** `degraded`
  volume, and the new disk shows sane latency.
- **Masters:** etcd needs 2 of 3. Never touch a second master while one is out.
- **Where to run kubectl:** node2 for everything, except when node2 itself is swapped: then node3.
- **Ansible** runs on pimaster through the runner (`./ansible-runner/ansible-runner.sh ...`), from `~/picluster`.
- Imaging a Pi disk: on the **laptop** (Raspberry Pi Imager + PowerShell) or on any Linux machine with the
  repository (`metal/rpi/Makefile`).

### 4.1 Pre-flight (node2), before every swap

```bash
echo "== nodes (all Ready, none SchedulingDisabled)"; kubectl get nodes
echo "== Longhorn volumes not healthy (only detached ones allowed)"
kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness | grep -v healthy
echo "== Longhorn disk space per node"
kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | .status.diskStatus | to_entries[] | "\($n) avail=\(.value.storageAvailable/1e9|floor)G scheduled=\(.value.storageScheduled/1e9|floor)G max=\(.value.storageMaximum/1e9|floor)G"'
echo "== load"; kubectl top nodes
```

Go only if every node is `Ready`, no volume is `degraded`/`faulted`, and no node is above about 80% CPU.

### 4.2 Lighten the cluster during a swap (agreed: scaling down, evicting and cordoning are fine)

Draining a node moves its pods to the others, and on 2026-11-14 and 2026-11-22 that overloaded the Pis. Before a
drain, scale down what is not needed for a day, and keep heavy pods off the worn Pis.

**Scale down** (node2). Pick the namespaces; the current replica counts are saved so they can be restored:

```bash
NS="e-commerce trading"          # add or remove namespaces as you like
for ns in $NS; do
  kubectl -n $ns get deploy,statefulset -o json | jq -r '.items[] | "\(.kind) \(.metadata.name) \(.spec.replicas)"' | sed "s|^|$ns |" >> ~/scaled-down-$(date +%F).txt
  kubectl -n $ns scale deploy --all --replicas=0
  kubectl -n $ns scale statefulset --all --replicas=0
done
cat ~/scaled-down-$(date +%F).txt
```

Flux puts the replica count of a Deployment back on its next reconcile when the manifest sets `replicas:`. To keep
them down for the day, suspend those Kustomizations first (`flux get kustomizations | grep -E "e-commerce|trading"`,
then `flux suspend kustomization <name>`), and `flux resume kustomization <name>` afterwards.

**Restore** (node2), after the swap:

```bash
F=~/scaled-down-YYYY-MM-DD.txt
while read ns kind name n; do kubectl -n $ns scale $kind/$name --replicas=$n; done < $F
```

**Cordon the worn Pis** while draining an x86 node, so its heavy pods (Prometheus, Elasticsearch, Kafka,
Postgres) do not land on them; uncordon right after the drained node is back:

```bash
kubectl cordon node5 node6            # only if node-esp-1 has room: kubectl top node node-esp-1 below ~60% CPU / 70% memory
# ... drain and swap the x86 node ...
kubectl uncordon node5 node6
```

A cordoned node keeps its running pods and its Longhorn replicas; it only receives no new pods.

---

## 5. Procedure A: Raspberry Pi Longhorn worker (node5, node6)

Example for **node6** (IP `10.0.0.16`). For node5 use `node5` and `15`.

### A1. Move all Longhorn data off the node (node2)

Longhorn copies every replica on node6 to the other nodes. The volumes stay online.

```bash
N=node6
kubectl -n longhorn-system patch nodes.longhorn.io $N --type merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
watch -n 30 "kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID==\"$N\")]|length'; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded"
```

Wait until the first number (replicas on node6) is **0** and the second (degraded volumes) is **0**. This can
take hours. If a number stops moving for 30 minutes, paste the output of the pre-flight block.

### A2. Drain and power off (node2, then node6)

```bash
kubectl drain node6 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
```

On node6:
```bash
sudo poweroff
```

### A3. Remove the node from the cluster (node2)

```bash
kubectl delete node node6
kubectl -n kube-system delete secret node6.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node6
```

The `node-password` secret must go, or k3s rejects the reinstalled node ("Node password rejected").

### A4. Image the new SSD

Put the new SSD in node6's adapter (node5: in the new adapter) and connect it to the laptop.

**Laptop (Windows):**

1. Download the image named in `metal/rpi/Makefile` (`IMG=` / `URL_IMG=`, today
   `ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz`).
2. Raspberry Pi Imager: **Choose OS → Use custom** → that file; **Choose storage** → the new SSD; when it asks
   about OS customisation choose **No** (cloud-init files below do it). Write.
3. Unplug and plug the SSD back. The FAT partition `system-boot` appears (for example `E:`). In PowerShell from
   the repository root:
   ```powershell
   $NODE = "node6"; $IP = "16"; $BOOT = "E:"
   $ud = (Get-Content metal\rpi\cloud-init\nodes\user-data-SSD-partition -Raw).Replace("`r`n", "`n") -creplace 'nodeX', $NODE
   $nc = (Get-Content metal\rpi\cloud-init\nodes\network-config -Raw).Replace("`r`n", "`n") -creplace 'X', $IP
   [IO.File]::WriteAllText("$BOOT\user-data", $ud)
   [IO.File]::WriteAllText("$BOOT\network-config", $nc)
   Select-String -Path "$BOOT\user-data" -Pattern "hostname:"; Select-String -Path "$BOOT\network-config" -Pattern "10.0.0."
   ```
   Expected: `hostname: node6` and `10.0.0.16/24`. Eject the drive.

**Or on a Linux machine** with the repository (check the device with `lsblk` first, it is wiped):
```bash
cd metal/rpi
make img/ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz
make wipe-disk burn-image USB=/dev/sdX
make mount-system-boot prepare-node6 USB=/dev/sdX
```

### A5. First boot (node6)

Connect the adapter to the same blue USB 3 port, power on, wait about 5 minutes (cloud-init creates `/storage`
on the rest of the disk). Then on node6:

```bash
hostname; ip -4 addr show eth0 | grep inet
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT | grep -v loop     # / about 50G, /storage the rest (~1.7T)
lsusb -t | grep -i -A1 storage                              # Driver=uas, 5000M
sudo dmesg -T | grep -iE "uas|reset|error" | tail            # nothing new
```

**Compatibility test** (first Pi with the new drive model). Writes and reads 2 GB on `/storage`:

```bash
sudo apt-get install -y -qq fio
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=randwrite --bs=4k --iodepth=16 --direct=1 --ioengine=libaio --runtime=60 --time_based --group_reporting | grep -E "IOPS|lat \(usec\)|clat percentiles" -A1 | head -8
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=write --bs=1M --iodepth=8 --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting | grep -E "bw=|IOPS"
sudo rm -f /storage/.fio; sudo dmesg -T | grep -iE "uas|reset|abort|error" | tail -5
```

Good: thousands of IOPS, write bandwidth in the hundreds of MB/s (USB 3 limit about 350–400 MB/s), **no**
`uas`/`reset`/`abort` lines in `dmesg`. If `dmesg` shows UAS resets, stop and paste it: the adapter and drive do
not get along (fix: a UAS quirk for that adapter, or another adapter model).

### A6. Configure the node and join k3s (pimaster)

```bash
cd ~/picluster
ssh-keygen -R node6; ssh-keygen -R 10.0.0.16
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node6; ssh-keygen -R 10.0.0.16' || true
./ansible-runner/ansible-runner.sh ansible node6 -m ping
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node6
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node6
```

### A7. Check (node2)

```bash
kubectl get node node6 -o wide                                   # Ready
kubectl -n longhorn-system get nodes.longhorn.io node6           # READY True, SCHEDULABLE True
kubectl -n longhorn-system get nodes.longhorn.io node6 -o json | jq -r '.status.diskStatus | to_entries[] | "\(.value.diskPath // .key) max=\(.value.storageMaximum/1e9|floor)G"'
kubectl get pods -A -o wide --field-selector spec.nodeName=node6 | grep -vE "Running|Completed"   # nothing
```

Longhorn creates node6's disk on `/storage` by itself (`defaultDataPath`). It is empty at first and fills as new
replicas are scheduled there; nothing else to do.

On node6, the SMART baseline for the progress table:
```bash
sudo apt-get install -y -qq --no-install-recommends smartmontools
sudo smartctl -i -H -A -d sat /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
```

---

## 6. Procedure B: x86 worker (node-esp-1, node-esp-2)

Example for **node-esp-2**. The mini PC reinstalls itself over PXE: the autoinstall wipes `/dev/sda` and creates
`/` (80G LVM) and `/storage` (the rest), from `ansible/host_vars/node-esp-2.yml`.

### B1. Move Longhorn data off (node2)

As A1 with `N=node-esp-2`. Note: Elasticsearch and Prometheus have 2 replicas, one here; Longhorn rebuilds that
copy on another node (after node6's swap, its new disk). Wait for both numbers to reach 0.

### B2. Drain (node2) and power off (node-esp-2)

Pods move to node-esp-1 and the Pis. First do 4.2: scale down what is not needed, and cordon the Pis that still
have their old disks if node-esp-1 has room (`kubectl top nodes` below about 60% CPU; Prometheus prefers amd64
and will land on node-esp-1). Uncordon them after B6.

```bash
kubectl drain node-esp-2 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
kubectl get pods -A -o wide | grep -E "Pending|ContainerCreating|CrashLoop"   # wait until empty
```

On node-esp-2: `sudo poweroff`.

### B3. Remove the node (node2)

```bash
kubectl delete node node-esp-2
kubectl -n kube-system delete secret node-esp-2.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node-esp-2
```

### B4. Swap the drive and reinstall over PXE

1. Fit the new SSD inside the mini PC.
2. pimaster: regenerate the autoinstall files (always before a node-esp reinstall):
   ```bash
   cd ~/picluster && make pxe-setup
   ```
3. Power on node-esp-2 and choose **network boot (PXE, IPv4)** in the boot menu. The autoinstall runs without
   questions (about 10–15 minutes) and reboots into Ubuntu.

### B5. Configure and join (pimaster)

```bash
cd ~/picluster
ssh-keygen -R node-esp-2
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node-esp-2' || true
./ansible-runner/ansible-runner.sh ansible node-esp-2 -m ping
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node-esp-2
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node-esp-2
```

`setup_picluster.yml` bind-mounts `/var/lib/rancher` on `/storage/rancher` on a fresh node-esp
(`rancher_storage_dir`), before k3s is installed. Check on node-esp-2: `findmnt /var/lib/rancher` shows
`/storage/rancher`.

### B6. Check (node2 and node-esp-2)

As A7 with `node-esp-2`; on node-esp-2 SMART without `-d sat`:
```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop        # / 80G, /storage ~1.7T
sudo smartctl -i -H -A /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
```

---

## 7. Procedure C: master (node4, node3, node2)

Example for **node4** (IP `10.0.0.14`). Masters hold no Longhorn data here, so there is no eviction step. etcd
runs with 2 of 3 members during the swap.

### C1. etcd snapshot first (node2; for node2's own swap, on node3)

```bash
sudo k3s etcd-snapshot save --name pre-swap-node4
sudo k3s etcd-snapshot list | tail -3
```

### C2. Drain, power off, remove (node2)

```bash
kubectl drain node4 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
```
On node4: `sudo poweroff`. Then on node2:
```bash
kubectl delete node node4
kubectl -n kube-system delete secret node4.node-password.k3s --ignore-not-found
sleep 30
kubectl get --raw='/readyz?verbose' | grep etcd          # [+]etcd ok
kubectl get nodes | grep control-plane                    # node2 and node3 Ready
```

Deleting the node also removes node4 from etcd (k3s does it). The API keeps working on node2 and node3.

### C3. Image the new SSD

As A4 with `$NODE = "node4"; $IP = "14"` (Linux: `prepare-node4`).

### C4. First boot

As A5 (the compatibility test is optional once node6 passed with the same drive model).

### C5. Configure and join as a **secondary** master (pimaster)

```bash
cd ~/picluster
ssh-keygen -R node4; ssh-keygen -R 10.0.0.14
./ansible-runner/ansible-runner.sh bash -lc 'ssh-keygen -R node4; ssh-keygen -R 10.0.0.14' || true
./ansible-runner/ansible-runner.sh ansible node4 -m ping
./ansible-runner/ansible-runner.sh ansible-playbook setup_picluster.yml --tags node --limit node4
./ansible-runner/ansible-runner.sh ansible-playbook backup_configuration.yml --limit node4
./ansible-runner/ansible-runner.sh ansible-playbook k3s_install.yml --limit node4 -e k3s_primary_control_node=false
./ansible-runner/ansible-runner.sh ansible-playbook update_node_config.yml --limit node4
```

**`-e k3s_primary_control_node=false` is mandatory, above all for node2** (the first master in the inventory):
a primary master gets `cluster-init: true` and would start a new, empty one-node cluster instead of joining.
Check on the swapped master before anything else:

```bash
sudo grep -nE "cluster-init|^server:" /etc/rancher/k3s/config.yaml    # must show server: https://...:6443, no cluster-init
```

If it shows `cluster-init`, stop k3s at once (`sudo systemctl stop k3s`) and paste it.

### C6. Check (node2; for node2's swap, node3)

```bash
kubectl get nodes | grep control-plane                    # three Ready
kubectl get --raw='/readyz?verbose' | grep etcd           # [+]etcd ok
kubectl -n kube-system get pods -o wide | grep -E "kube-vip|coredns|cilium-operator"
```

After node2's swap also: `make admin-cli` on pimaster (flux CLI on node2) and copy the kubeconfig if you use one
from node2.

Wait at least an hour between masters, and only with all three `Ready`.

---

## 8. Procedure D: node1 (clone, short downtime)

node1 runs Vault, RustFS (backups, Loki chunks) and DNS outside k3s, with no second instance, so it cannot be
swapped live. The old disk is **cloned** to the new one (data, keys and configuration stay as they are) and the
root filesystem is grown. Downtime about 30–45 minutes; plan it in the evening, not during a Velero backup
(02:00) or the Longhorn snapshot cleanup (03:30).

During the downtime: Vault is unreachable (external-secrets keeps the existing secrets, refreshes fail), Velero
and Loki cannot write to RustFS (Loki keeps its WAL and catches up), DNS answers from node1 stop.

### D1. Before (node1)

```bash
vault status | grep -E "Sealed|Version"         # note how you unseal it
sudo systemctl list-units --type=service | grep -iE "vault|rustfs|bind|named|haproxy"
lsusb | grep -vi hub
```

### D2. Clone (Linux machine with two USB 3 ports, e.g. the pimaster host)

1. On node1: `sudo poweroff`. Take out the old SSD (in its adapter).
2. Connect the **old** SSD and the **new** SSD (in a second adapter) to the Linux machine:
   ```bash
   lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT          # identify OLD (223.6G) and NEW (1.7T) by size
   OLD=/dev/sdX; NEW=/dev/sdY                       # check twice: NEW is overwritten
   sudo dd if=$OLD of=$NEW bs=16M status=progress conv=fsync
   sudo sgdisk -e $NEW 2>/dev/null || true          # GPT: move the backup header to the end of the bigger disk
   sudo partprobe $NEW; lsblk $NEW
   sudo growpart $NEW 2                             # grow the root partition (partition 2) to the whole disk
   sudo e2fsck -f ${NEW}2
   sudo resize2fs ${NEW}2
   lsblk -o NAME,SIZE,MOUNTPOINT $NEW               # partition 2 about 1.7T
   ```
3. Put the new SSD (with node1's adapter) back on node1 and power on.

### D3. After (node1, then node2)

```bash
df -h /                                          # about 1.7T
vault status | grep Sealed                       # unseal if true (VAULT-001)
sudo systemctl --failed
```
On node2: `kubectl get externalsecrets -A | grep -v SecretSynced` (empty after a few minutes) and check that the
next Velero backup succeeds.

Keep the old node1 SSD untouched for a week as a fallback.

---

## 9. After all Longhorn nodes are done

When node6, node-esp-2, node5 and node-esp-1 run on new disks:

1. Give Elasticsearch and Prometheus their third replica back (node2):
   ```bash
   for v in pvc-a6e3a543-70ff-4bc5-a595-82bf0fcf9c45 pvc-e1c0c8e4-c16e-4a91-bf7c-0ebc0b68209b; do
     kubectl -n longhorn-system patch volumes.longhorn.io $v --type merge -p '{"spec":{"numberOfReplicas":3}}'
   done
   ```
2. Spread existing replicas over the bigger disks: Longhorn setting `replica-auto-balance` to `best-effort` (in
   `kubernetes/platform/longhorn/app/base/values.yaml`, `defaultSettings.replicaAutoBalance`), one PR.
3. SMART monitoring and a wear alert on every node (postmortem action 3c), so the next worn disk raises an alert.

## 10. Progress

| # | Node | Adapter (`lsusb`) | New drive (model, serial) | Date | SMART baseline | Notes |
|---|---|---|---|---|---|---|
| 1 | node6 | StarTech `14b0:0207` | | | | |
| 2 | node-esp-2 | internal SATA | | | | |
| 3 | node5 | new StarTech (old `14b0:0207`, CRC errors) | | | | |
| 4 | node-esp-1 | internal SATA | | | | |
| 5 | node4 | StarTech `14b0:0206` | | | | |
| 6 | node3 | StarTech `14b0:0207` | | | | |
| 7 | node2 | StarTech `14b0:0207` | | | | |
| 8 | node1 | StarTech `14b0:0207` | | | | |
