# Disk swap plan, 25 Nov - 22 Dec 2026

The run sheet for phase 1 of [disk-replacement.md](disk-replacement.md): every command in order, ready to paste.
The background, the rules and the other procedures (masters, node1) are in disk-replacement.md; if this sheet and
that document disagree, disk-replacement.md wins and this sheet gets fixed.

**Where commands run:** kubectl and flux on **node2**, Ansible on **pimaster** (from `~/picluster`), RustFS checks on
**node1**, imaging on the **laptop** (from `c:\Users\marco\bin\picluster`). Times are UTC (Italy is UTC+1).

**Stop rule:** if a "you want" line is not met, stop and ask. Do not start the next node.

| Day | What | Drive |
|---|---|---|
| Wed 25 - Thu 26 Nov | Morning checks; check the new drives | |
| Fri 27 Nov | Prep | |
| Sat 28 Nov, morning | **node6** (procedure A) | Crucial BX500 1 TB `CT1000BX500SSD1` |
| Sat 28 Nov, afternoon | **node4** (procedure C, master; no Longhorn data, no eviction) | Crucial BX500 1 TB |
| Sun 29 Nov | **node-esp-2** (procedure B) | Samsung 870 EVO 1 TB `MZ-77E1T0B/EU` |
| Mon 30 Nov | First automatic `fstrim.timer` on the Pis | |
| Sat 5 Dec | **node5** (procedure A); Sun 6 Dec spare | Crucial BX500 1 TB |
| ~12-19 Dec | Write amplification of the new drives, 2 weeks after each swap | |

Swaps are concentrated on weekends. Two nodes on Saturday is safe only because node4 holds no Longhorn data:
it starts after node6 is fully green (4.9), and not later than about 16:00 UTC; if node6 runs late, node4 moves to
Sunday after node-esp-2, or to 6 Dec. Two Longhorn nodes (node6, node5, node-esp-2) never go on the same day: with one
out and its data rebuilding elsewhere, a second eviction would leave too few nodes for the copies.
| by 22 Dec | All 4 swapped; the `DiskWornOut` silence expires | |

Baseline before the swaps (24 Nov evening, after TRIM): write latency 0.2-1.1 ms on every disk (node6 was 43 ms on
22 Nov).

---

## 1. Every morning before a swap

**node2: last backup and Longhorn backup target**

```bash
kubectl -n velero get backups.velero.io -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,ERR:.status.errors,WARN:.status.warnings | tail -3
kubectl -n longhorn-system get backuptargets.longhorn.io default -o custom-columns=AVAILABLE:.status.available,LASTSYNC:.status.lastSyncedAt
```

You want: the newest `full-2026MMDD...` `Completed` with ERR `<none>`, and `AVAILABLE` `true`.

**node1: RustFS timeouts last night, per hour** (set `D` to today)

```bash
D=2026-11-25
sudo sh -c 'cat /var/log/rustfs/*' | grep -i timeout | grep -oE "\"timestamp\":\"${D}T[0-9]{2}" | cut -c25- | sort | uniq -c
```

You want: nothing or a few dozen. Hundreds at `02`: node1's disk is saturating again (postmortem 2026-11-15,
action 11), tell before swapping.

**pimaster: no USB resets on the Pis**

```bash
cd ~/picluster
./ansible-runner/ansible-runner.sh ansible raspberrypi -b -m shell -a 'dmesg -T | grep -iE "reset|i/o error" | tail -3'
```

No backup `Completed` = no swap that day.

## 2. Wed 25 - Thu 26: check the new drives

Only with a free USB-SATA adapter (the node adapters are in use). **Laptop:** CrystalDiskInfo, one drive at a time.

You want: health Good, reallocated sectors 0, power-on hours near 0. Without a spare adapter, skip: each drive is
checked at its first boot (3.8 and 4.6).

## 3. Fri 27: prep

**pimaster**

```bash
cd ~/picluster && git pull
```

**node2: pre-flight** (only look)

```bash
echo "== nodes"; kubectl get nodes
echo "== volumes not healthy"; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUST:.status.robustness | grep -v healthy
echo "== longhorn space"; kubectl -n longhorn-system get nodes.longhorn.io -o json | jq -r '.items[] | .metadata.name as $n | .status.diskStatus | to_entries[] | "\($n) avail=\(.value.storageAvailable/1e9|floor)G scheduled=\(.value.storageScheduled/1e9|floor)G max=\(.value.storageMaximum/1e9|floor)G"'
echo "== load"; kubectl top nodes
```

**Laptop:** install Raspberry Pi Imager; download the image named in `metal/rpi/Makefile`
(`ubuntu-24.04.3-preinstalled-server-arm64+raspi.img.xz`).

## 4. Sat 28: node6 (procedure A)

Start at about 08:00: the eviction (step 3) takes 1-6 hours.

### 4.1 Checks

Section 1 (backup, timeouts, resets), then the pre-flight block of section 3.
You want: every node `Ready`, no volume `degraded`, no node above about 80% CPU.

### 4.2 Scale down what is not needed today (node2)

```bash
flux get kustomizations | grep -E "e-commerce|trading"
flux suspend kustomization <name>          # once per name from the line above
NS="e-commerce trading"
for ns in $NS; do
  kubectl -n $ns get deploy,statefulset -o json | jq -r '.items[] | "\(.kind) \(.metadata.name) \(.spec.replicas)"' | sed "s|^|$ns |" >> ~/scaled-down-$(date +%F).txt
  kubectl -n $ns scale deploy --all --replicas=0
  kubectl -n $ns scale statefulset --all --replicas=0
done
cat ~/scaled-down-$(date +%F).txt
```

### 4.3 Keycloak Postgres check (node2)

node6 holds the only copy of one Keycloak Postgres instance (1 replica).

```bash
kubectl -n databases get pods -o wide | grep postgres-keycloak | awk '{print $1, $3, $(NF-2)}'
kubectl -n databases get cluster postgres-keycloak -o jsonpath='{"last backup: "}{.status.lastSuccessfulBackup}{"\n"}{range .status.conditions[?(@.type=="ContinuousArchiving")]}{"WAL archiving: "}{.status}{"\n"}{end}'
```

You want: both pods `Running`, a backup from last night, `WAL archiving: True`.

### 4.4 Move Longhorn data off node6 (node2, 1-6 h)

```bash
N=node6
kubectl -n longhorn-system patch nodes.longhorn.io $N --type merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
watch -n 30 "kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID==\"$N\")]|length'; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded"
```

You want: both numbers `0` (replicas on node6, degraded volumes). If they stop moving for 30 minutes, stop and
paste the pre-flight block.

### 4.5 Drain, power off, remove

node2:

```bash
kubectl drain node6 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
```

node6:

```bash
sudo poweroff
```

node2:

```bash
kubectl delete node node6
kubectl -n kube-system delete secret node6.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node6
```

### 4.6 Image the new BX500 (laptop)

1. Take node6's adapter off the old disk; label the old disk **"node6 old, 28 Nov"** and keep it for a week.
2. Put the new BX500 in the adapter and connect it to the laptop.
3. Raspberry Pi Imager: **Choose OS → Use custom** → the `.img.xz`; **Choose storage** → the BX500 (about
   1 TB, check the size); OS customisation **No**; Write.
4. Unplug and plug the drive back. In PowerShell from `c:\Users\marco\bin\picluster` (set `$BOOT` to the
   `system-boot` drive letter):

```powershell
$NODE = "node6"; $IP = "16"; $BOOT = "E:"
$ud = (Get-Content metal\rpi\cloud-init\nodes\user-data-SSD-partition -Raw).Replace("`r`n", "`n") -creplace 'nodeX', $NODE
$nc = (Get-Content metal\rpi\cloud-init\nodes\network-config -Raw).Replace("`r`n", "`n") -creplace 'X', $IP
[IO.File]::WriteAllText("$BOOT\user-data", $ud)
[IO.File]::WriteAllText("$BOOT\network-config", $nc)
Select-String -Path "$BOOT\user-data" -Pattern "hostname:"; Select-String -Path "$BOOT\network-config" -Pattern "10.0.0."
```

You want: `hostname: node6` and `10.0.0.16/24`. Eject the drive.

### 4.7 First boot and speed test (node6)

Connect the adapter to the **same blue USB 3 port**, power on, wait 5 minutes.

```bash
hostname; ip -4 addr show eth0 | grep inet
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT | grep -v loop
lsusb -t | grep -i -A1 storage
sudo dmesg -T | grep -iE "uas|reset|error" | tail
```

You want: `node6`, `10.0.0.16`; `/` about 50G and `/storage` about 880G; `Driver=uas, 5000M`; no `reset`.

```bash
sudo apt-get install -y -qq fio
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=randwrite --bs=4k --iodepth=16 --direct=1 --ioengine=libaio --runtime=60 --time_based --group_reporting | grep -E "IOPS|lat \(usec\)|clat percentiles" -A1 | head -8
sudo fio --name=t --filename=/storage/.fio --size=2G --rw=write --bs=1M --iodepth=8 --direct=1 --ioengine=libaio --runtime=30 --time_based --group_reporting | grep -E "bw=|IOPS"
sudo rm -f /storage/.fio; sudo dmesg -T | grep -iE "uas|reset|abort|error" | tail -5
```

You want: thousands of IOPS, hundreds of MB/s, no `uas`/`reset`/`abort` lines. UAS resets: stop and paste.

### 4.8 Join the cluster (pimaster)

The same playbooks as `make init` for a node (`nodes-setup`, `configure-os-backup`, `k3s-install`), limited to
node6, plus `update_node_config.yml` (Pi throttling metrics, USB TRIM rule, SMART metrics, journald and kubelet
config). Checked against the playbooks on 2026-11-24: with `--limit` the token comes from Vault and the server
address is the API VIP (`k3s_api_vip`), so no other node is needed in the run; only the worker label play
(hosts `k3s_master`) is skipped, so 4.9 sets that label by hand (cosmetic: the `ROLES` column, no manifest uses it).

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

You want: every playbook green (`failed=0`).

### 4.9 Check

node2:

```bash
kubectl label node node6 kubernetes.io/role=worker --overwrite   # k3s_install.yml skips its label play with --limit
kubectl get node node6 -o wide
kubectl -n longhorn-system get nodes.longhorn.io node6
kubectl -n longhorn-system get nodes.longhorn.io node6 -o json | jq -r '.status.diskStatus | to_entries[] | "\(.value.diskPath // .key) max=\(.value.storageMaximum/1e9|floor)G"'
kubectl get pods -A -o wide --field-selector spec.nodeName=node6 | grep -vE "Running|Completed"
```

You want: `Ready`; Longhorn `READY True`, `SCHEDULABLE True`, disk `/storage`; no pod in another state.

node6 (SMART baseline and TRIM):

```bash
sudo apt-get install -y -qq --no-install-recommends smartmontools
sudo smartctl -i -H -A -d sat /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
cat /sys/block/sda/device/scsi_disk/*/provisioning_mode
lsblk -D -d -o NAME,DISC-GRAN,DISC-MAX /dev/sda
sudo fstrim -v /storage && sudo fstrim -v /
sudo dmesg -T | grep -iE "sda|uas|reset|i/o error" | tail
```

You want: `PASSED`; `unmap`; `DISC-MAX` `2G`; two "trimmed" lines; no reset or I/O error. Write model, serial and
SMART values in the progress table (disk-replacement.md 10).

### 4.10 Restore (node2)

```bash
F=~/scaled-down-$(date +%F).txt
while read ns kind name n; do kubectl -n $ns scale $kind/$name --replicas=$n; done < $F
flux resume kustomization <name>           # once per suspended name
```

node4 (section 4b) and Sunday only if everything in 4.9 is green.

## 4b. Sat 28 afternoon: node4 (procedure C, master)

node4 is an etcd member (master) with no Longhorn data, so no eviction: about 1.5 hours. Start only with node6
green and the three masters `Ready`, not later than about 16:00 UTC. etcd keeps running on node2 and node3
(2 of 3). Never take a second master out while node4 is out.

### 4b.1 etcd snapshot (node2)

```bash
kubectl get nodes | grep control-plane                    # node2, node3, node4 Ready
kubectl get --raw='/readyz?verbose' | grep etcd           # [+]etcd ok
kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID=="node4")]|length'
sudo k3s etcd-snapshot save --name pre-swap-node4
sudo k3s etcd-snapshot list | tail -3
```

You want: three masters `Ready`, `[+]etcd ok`, **0** Longhorn replicas on node4 (if not 0: run the eviction of 4.4
with `N=node4` first, or move node4 to Sunday), the new `pre-swap-node4` snapshot in the list.

### 4b.2 Drain, power off, remove

node2:

```bash
kubectl drain node4 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
```

node4:

```bash
sudo poweroff
```

node2:

```bash
kubectl delete node node4
kubectl -n kube-system delete secret node4.node-password.k3s --ignore-not-found
sleep 30
kubectl get --raw='/readyz?verbose' | grep etcd
kubectl get nodes | grep control-plane
```

You want: `[+]etcd ok`; node2 and node3 `Ready`. Label the old disk **"node4 old, 28 Nov"**.

### 4b.3 Image the BX500 (laptop)

As 4.6, with:

```powershell
$NODE = "node4"; $IP = "14"; $BOOT = "E:"
$ud = (Get-Content metal\rpi\cloud-init\nodes\user-data-SSD-partition -Raw).Replace("`r`n", "`n") -creplace 'nodeX', $NODE
$nc = (Get-Content metal\rpi\cloud-init\nodes\network-config -Raw).Replace("`r`n", "`n") -creplace 'X', $IP
[IO.File]::WriteAllText("$BOOT\user-data", $ud)
[IO.File]::WriteAllText("$BOOT\network-config", $nc)
Select-String -Path "$BOOT\user-data" -Pattern "hostname:"; Select-String -Path "$BOOT\network-config" -Pattern "10.0.0."
```

You want: `hostname: node4` and `10.0.0.14/24`.

### 4b.4 First boot (node4)

Same blue USB 3 port, power on, wait 5 minutes:

```bash
hostname; ip -4 addr show eth0 | grep inet
lsblk -o NAME,SIZE,TRAN,MODEL,MOUNTPOINT | grep -v loop
lsusb -t | grep -i -A1 storage
sudo dmesg -T | grep -iE "uas|reset|error" | tail
```

You want: `node4`, `10.0.0.14`, `Driver=uas, 5000M`, no `reset`. (`fio` not needed: node6 validated the BX500.)

### 4b.5 Join as a **secondary** master (pimaster)

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

**`-e k3s_primary_control_node=false` is mandatory**: without it node4 could start a new, empty cluster. (The role
already treats only the first master in the inventory, node2, as primary; the extra var overrides that and is the
safety net. For node2's own swap it is what prevents `cluster-init`.) Right
after `k3s_install.yml`, on node4:

```bash
sudo grep -nE "cluster-init|^server:" /etc/rancher/k3s/config.yaml
```

You want: a `server: https://...:6443` line and **no** `cluster-init`. If `cluster-init` shows: `sudo systemctl stop
k3s` at once and stop.

### 4b.6 Check

node2:

```bash
kubectl get nodes | grep control-plane
kubectl get --raw='/readyz?verbose' | grep etcd
kubectl -n kube-system get pods -o wide | grep -E "kube-vip|coredns|cilium-operator"
kubectl get pods -A -o wide --field-selector spec.nodeName=node4 | grep -vE "Running|Completed"
```

You want: three masters `Ready`, `[+]etcd ok`, those pods `Running`, nothing broken on node4.

node4 (SMART baseline and TRIM):

```bash
sudo apt-get install -y -qq --no-install-recommends smartmontools
sudo smartctl -i -H -A -d sat /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
cat /sys/block/sda/device/scsi_disk/*/provisioning_mode
lsblk -D -d -o NAME,DISC-GRAN,DISC-MAX /dev/sda
sudo fstrim -v / ; sudo fstrim -v /storage 2>/dev/null
sudo dmesg -T | grep -iE "sda|uas|reset|i/o error" | tail
```

You want: `PASSED`, `unmap`, `DISC-MAX` `2G`, "trimmed", no errors. Fill in the progress table.

## 5. Sun 29: node-esp-2 (procedure B)

Start at about 08:00.

### 5.1 Checks

Section 1, the pre-flight block of section 3, and 4.2 (scale down) again.
You want: every node `Ready` (node4 and node6 back), no volume `degraded`, and node6 already holding Longhorn data
(`scheduled=` above 0 in the pre-flight). If node4 was moved to today, it goes after node-esp-2 is green (4b).

### 5.2 Move Longhorn data off node-esp-2 (node2, 1-6 h)

Elasticsearch and Prometheus rebuild their copy on another node.

```bash
N=node-esp-2
kubectl -n longhorn-system patch nodes.longhorn.io $N --type merge -p '{"spec":{"allowScheduling":false,"evictionRequested":true}}'
watch -n 30 "kubectl -n longhorn-system get replicas.longhorn.io -o json | jq '[.items[]|select(.spec.nodeID==\"$N\")]|length'; kubectl -n longhorn-system get volumes.longhorn.io -o custom-columns=NAME:.metadata.name,ROBUST:.status.robustness | grep -c degraded"
```

You want: both numbers `0`.

### 5.3 Keep heavy pods off the worn disk, drain, power off, remove

node5 is the last worn disk by now. node2 (cordon only if node-esp-1 is below about 60% CPU and 70% memory):

```bash
kubectl top node node-esp-1
kubectl cordon node5
kubectl drain node-esp-2 --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=600s
kubectl get pods -A -o wide | grep -E "Pending|ContainerCreating|CrashLoop"
```

Repeat the last line until it prints nothing. Then on node-esp-2:

```bash
sudo poweroff
```

node2:

```bash
kubectl delete node node-esp-2
kubectl -n kube-system delete secret node-esp-2.node-password.k3s --ignore-not-found
kubectl -n longhorn-system delete nodes.longhorn.io node-esp-2
```

### 5.4 Fit the 870 EVO and reinstall over PXE

1. Swap the drive inside the mini PC; label the old one **"node-esp-2 old, 29 Nov"** and keep it for a week.
2. pimaster:

```bash
cd ~/picluster && make pxe-setup
```

3. Power on node-esp-2, open the boot menu, choose **network boot (PXE, IPv4)**. The autoinstall runs by itself
   (10-15 minutes) and reboots into Ubuntu.

### 5.5 Join the cluster (pimaster)

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

You want: every playbook green.

### 5.6 Check

node-esp-2:

```bash
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT | grep -v loop
findmnt /var/lib/rancher
sudo smartctl -i -H -A /dev/sda | grep -iE "model|serial|result|Percent|Total_LBAs|Wear"
```

You want: `/` 80G, `/storage` about 850G; `/var/lib/rancher` on `/storage/rancher`; `Samsung SSD 870 EVO 1TB`,
`PASSED`.

node2:

```bash
kubectl label node node-esp-2 kubernetes.io/role=worker --overwrite
kubectl get node node-esp-2 -o wide
kubectl -n longhorn-system get nodes.longhorn.io node-esp-2
kubectl get pods -A -o wide --field-selector spec.nodeName=node-esp-2 | grep -vE "Running|Completed"
kubectl uncordon node5
```

Then 4.10 (restore) and fill in the progress table.

## 6. Mon 30: first automatic TRIM

`fstrim.timer` runs on the Pis early Monday. pimaster:

```bash
cd ~/picluster
./ansible-runner/ansible-runner.sh ansible raspberrypi -b -m shell -a 'systemctl status fstrim.service --no-pager | tail -4; dmesg -T | grep -iE "reset|i/o error" | tail -3'
```

You want: "trimmed" lines, no reset or I/O error.

## 7. Sat 5 Dec: node5 (procedure A)

Start at about 08:00 after a green section 1, with node6, node4 and node-esp-2 green since the weekend before.
Sun 6 Dec is the spare day (also for node4 if it moved).

Section 4 with `node5` and IP `15` everywhere: `N=node5`; `kubectl drain node5`; the secret
`node5.node-password.k3s`; `$NODE = "node5"; $IP = "15"`; `ssh-keygen -R node5; ssh-keygen -R 10.0.0.15`;
`--limit node5`; checks on node5. node5 holds the only copy of the other Keycloak Postgres instance: 4.3 is
mandatory. `fio` (4.7) is optional (node6 validated the BX500). Label the old disk **"node5 old, 5 Dec"**.

## 8. Two weeks after each swap: write amplification

Crucial drives only (attributes 247/248); expected 3 or lower with TRIM. node2:

```bash
P="/api/v1/namespaces/kube-prom-stack/services/kube-prometheus-stack-prometheus:http-web/proxy/api/v1/query?query="
Q='1 + increase(smartmon_attr_raw_value{id="248"}[7d]) / increase(smartmon_attr_raw_value{id="247"}[7d])'
kubectl get --raw "${P}$(python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$Q")" | jq -r '.data.result[] | "\(.metric.instance)\t\(.value[1] | tonumber | . * 10 | round / 10)"' | sort
```

## 9. After the last of the 4 swaps

Expire the `DiskWornOut` silence early (disk-replacement.md 9):

```bash
AM="kubectl -n kube-prom-stack exec alertmanager-kube-prometheus-stack-0 -c alertmanager -- amtool --alertmanager.url=http://localhost:9093"
$AM silence expire e33eec49-ba6e-4267-99c4-d968f0e331d3
```

The old disks can go after a week of the new ones running clean.
