# pimaster VM: rebuild with Vagrant

How to rebuild the pimaster VM from scratch on the Windows laptop. pimaster is the **prod control VM**: it
hosts the ansible-runner container (the `pimaster` host in `ansible/inventory.yml` is that container, not the
VM), which manages the prod cluster.

The same Vagrantfile defines two machines:

| VM | Purpose | Size | Host-only IP | Doc |
| --- | --- | --- | --- | --- |
| **pimaster** | Prod control: ansible-runner, node SSH key, secrets, prod kubeconfig | 2 GB / 2 vCPU | 192.168.56.10 | this page |
| **pidev** | Dev: k3d dev cluster, no secrets, no runner. Starts only with `vagrant up pidev` | 10 GB / 4 vCPU | 192.168.56.11 | [dev-environment.md](dev-environment.md) |

- **Definition:** [homelab-vagrant/pimaster/Vagrantfile](../homelab-vagrant/pimaster/Vagrantfile), with the
  provisioners in [homelab-vagrant/pimaster/provision/](../homelab-vagrant/pimaster/provision/).
- **Always name the machine** in Vagrant commands (`vagrant up pimaster`, `vagrant destroy pimaster`). Without
  a name, `destroy`, `halt` and `reload` act on both VMs.
- **Not in git, and cannot be regenerated:** the SSH key the cluster nodes trust, `~/.secrets`, the kubeconfig
  and the certbot state. **Back them up first** ([section 3](#3-back-up-what-is-not-in-git)).

## Contents

- [1. Current VM](#1-current-vm)
- [2. What the Vagrantfile builds](#2-what-the-vagrantfile-builds)
- [3. Back up what is not in git](#3-back-up-what-is-not-in-git)
- [4. Prerequisites on Windows](#4-prerequisites-on-windows)
- [5. Rebuild](#5-rebuild)
- [6. Restore and start the ansible-runner](#6-restore-and-start-the-ansible-runner)
- [7. Resize, and the dev cluster](#7-resize-and-the-dev-cluster)
- [8. Troubleshooting](#8-troubleshooting)
- [9. Changes from the original Vagrantfile](#9-changes-from-the-original-vagrantfile)

## 1. Current VM

State as of 2026-11-21.

| Item | Value |
| --- | --- |
| VirtualBox name / UUID | `pimaster` / `2435e9b9-f219-4791-94c0-cd116e0aaeef` |
| Built from | `D:\SCRIPT\vagrant-pimaster\Vagrantfile` (Dec 2025, outside git; its `.vagrant\` folder holds the machine ID) |
| Box | `generic/ubuntu2204` |
| Disk | `D:\VirtualBox VMs\pimaster\generic-ubuntu2204-virtualbox-x64-disk001.vdi`, root LV 62 GB |
| Resources | 1 GB RAM, 1 vCPU |
| eth0 (NAT) | 10.0.2.15, `vagrant ssh` on 127.0.0.1:2222 |
| eth1 (host-only) | 192.168.56.10 (Windows side 192.168.56.1) |
| eth2 (bridged, Wi-Fi) | DHCP on the home LAN (192.168.1.x), route `10.0.0.0/24 via 192.168.1.21` |
| User | `marmila`, uid 1001 / gid 1002 (the runner image is built with these IDs) |

## 2. What the Vagrantfile builds

`vagrant up pimaster` runs the **base** provisioner (pidev runs the same one) ([base.sh](../homelab-vagrant/pimaster/provision/base.sh)):

1. Sets the timezone to Europe/Rome and installs git, make, curl, jq.
2. Grows partition, LVM and filesystem to the virtual disk size (default 100 GB).
3. Turns on IPv4 forwarding and sets DNSSEC off in systemd-resolved (the Oct 2026 root KSK rollover broke
   validation).
4. Creates the `docker` group, then user `marmila` (in that order, so the IDs are 1001/1002), with
   passwordless sudo and the `marmila@pimaster` public key in `authorized_keys`.
5. Installs Docker CE with the compose and buildx plugins.
6. Writes netplan `60-static-route.yaml`: `10.0.0.0/24 via 192.168.1.21` on eth2.
7. Clones `https://github.com/marmila/picluster` into `~/picluster` and creates the runner's local folders.

It does **not** start the ansible-runner. `make ansible-runner-setup` generates a new `~/.ssh/id_rsa` when none
is present, and the cluster nodes would not trust that key. Restore first, then start the runner
([section 6](#6-restore-and-start-the-ansible-runner)).

The **dev-tools** provisioner ([dev-tools.sh](../homelab-vagrant/pimaster/provision/dev-tools.sh)) installs
the Cilium kernel modules, sysctls, k3d, kubectl, helm 4, tmpl and flux. It runs automatically on pidev and
never on pimaster unless you ask for it ([section 7](#7-resize-and-the-dev-cluster)).

Tunables (environment variables in the PowerShell session that runs `vagrant`):

| Variable | Default | Use |
| --- | --- | --- |
| `PIMASTER_MEMORY` | `2048` | pimaster RAM in MB |
| `PIMASTER_CPUS` | `2` | pimaster vCPUs |
| `PIDEV_MEMORY` | `10240` | pidev RAM in MB |
| `PIDEV_CPUS` | `4` | pidev vCPUs |
| `PIMASTER_DISK` | `100GB` | Root disk of both VMs, grow only |
| `PIMASTER_BRIDGE` | `Realtek 8822CE Wireless LAN 802.11ac PCI-E NIC` | Another laptop or NIC: `VBoxManage list bridgedifs` |
| `PIMASTER_REPO` | `https://github.com/marmila/picluster.git` | |

## 3. Back up what is not in git

On the **current** pimaster:

```bash
cd ~
echo "== Will back up =="; ls -ld .ssh/id_rsa .ssh/id_rsa.pub .secrets .kube/config .certbot .gitconfig 2>&1
echo "== Local repo changes (should be none: pimaster only pulls) =="; git -C ~/picluster status --short
echo "== Crontab =="; crontab -l 2>/dev/null || echo "none"
ls -d .ssh/id_rsa .ssh/id_rsa.pub .secrets .kube/config .certbot .gitconfig 2>/dev/null \
  | tar czf ~/pimaster-backup.tgz -T -
tar tzf ~/pimaster-backup.tgz | head -30
```

Copy it to Windows (PowerShell). Keep it **outside** the repo: it holds secrets.

```powershell
New-Item -ItemType Directory -Force D:\SCRIPT\pimaster-backup | Out-Null
scp marmila@192.168.56.10:pimaster-backup.tgz D:\SCRIPT\pimaster-backup\pimaster-backup-$(Get-Date -Format yyyy-MM-dd).tgz
Get-ChildItem D:\SCRIPT\pimaster-backup
```

What each item is for:

| Item | Why it matters |
| --- | --- |
| `~/.ssh/id_rsa`, `id_rsa.pub` | The key Ansible uses on every node. If you lose it, you have to re-authorize a new key on every node |
| `~/.secrets` | Vault / IONOS / other secret files created by `make secret-files` |
| `~/.kube/config` | kubeconfig the runner uses |
| `~/.certbot` | Certbot account and certificates |
| `~/.gitconfig` | Git identity (optional) |

The Docker images and the build cache are not backed up: `make ansible-runner-setup` rebuilds the runner.

## 4. Prerequisites on Windows

```powershell
vagrant --version                       # 2.4.9 tested
vagrant plugin list                     # needs vagrant-disksize
# vagrant plugin install vagrant-disksize

$vb = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $vb list bridgedifs | Select-String '^Name:'    # the Wi-Fi adapter name must match PIMASTER_BRIDGE
& $vb list systemproperties | Select-String 'Default machine folder'
```

**Put the VM on D:.** The default machine folder is `C:\Users\marco\VirtualBox VMs`, and C: has about 28 GB
free. The disk is dynamic but can grow to 100 GB, so point the default folder at D: before creating the VM:

```powershell
& $vb setproperty machinefolder "D:\VirtualBox VMs"
```

This changes where VirtualBox creates new VMs from then on. Existing VMs stay where they are.

## 5. Rebuild

> Destructive: the old VM and its disk are deleted. Do it only after [section 3](#3-back-up-what-is-not-in-git)
> and with the backup file checked on D:.

1. Destroy the old VM from its original Vagrant folder (it knows the machine ID):

   ```powershell
   cd D:\SCRIPT\vagrant-pimaster
   vagrant status
   vagrant destroy -f
   vagrant global-status --prune
   ```

   This old folder defines a single machine, so `destroy` there removes only the old pimaster. pidev, if it
   exists, is managed from the repo folder and is not touched.

   If that folder is gone, delete it in VirtualBox instead:

   ```powershell
   & $vb controlvm pimaster poweroff
   & $vb unregistervm pimaster --delete
   ```

2. Create the new VM from the repo (Windows clone):

   ```powershell
   cd C:\Users\marco\bin\picluster
   git pull
   cd homelab-vagrant\pimaster
   vagrant validate
   vagrant up pimaster
   ```

   The first `up` downloads or updates the box, then runs `base.sh`, which takes about 5–10 minutes. The
   `.vagrant\` state folder is created here and is gitignored.

3. Check:

   ```powershell
   vagrant ssh pimaster -c "id marmila; df -h /; ip -4 -br addr; ip route | grep 10.0.0.0; docker version --format '{{.Server.Version}}'; docker compose version; ls ~marmila/picluster | head -3"
   ```

   Expected: `uid=1001(marmila) gid=1002(marmila)`, a root disk of about 100 GB, eth1 192.168.56.10, the
   `10.0.0.0/24` route, Docker with compose, and the repo.

## 6. Restore and start the ansible-runner

From Windows, copy the backup in. The SSH host key changed, so drop the old entry first:

```powershell
ssh-keygen -R 192.168.56.10
scp D:\SCRIPT\pimaster-backup\pimaster-backup-<date>.tgz marmila@192.168.56.10:pimaster-backup.tgz
```

On the new pimaster (`ssh marmila@192.168.56.10`):

```bash
cd ~
tar xzf pimaster-backup.tgz
chmod 700 .ssh .secrets; chmod 600 .ssh/id_rsa .kube/config
ls -l .ssh .secrets .kube

cd ~/picluster
make ansible-runner-setup
docker ps --filter name=ansible-runner --format '{{.Names}} {{.Status}}'
./ansible-runner/ansible-runner.sh ansible --version
./ansible-runner/ansible-runner.sh ansible picluster -m ping
```

`ansible picluster -m ping` returning `pong` from every node proves the restored key works. Then delete the
backup file from the VM (`rm ~/pimaster-backup.tgz`) and keep the copy on D:.

## 7. Resize, and the dev cluster

**The dev cluster does not run on pimaster.** It runs on the separate `pidev` VM: `vagrant up pidev`, then
follow [dev-environment.md](dev-environment.md). pimaster stays small and only runs the ansible-runner.

To change pimaster's size, set the variables in the PowerShell session. Vagrant applies them on every
`vagrant up` / `vagrant reload`:

```powershell
cd C:\Users\marco\bin\picluster\homelab-vagrant\pimaster
$env:PIMASTER_MEMORY = "4096"; $env:PIMASTER_CPUS = "2"
vagrant reload pimaster

# Back to the default (2 GB / 2 vCPU)
Remove-Item Env:PIMASTER_MEMORY, Env:PIMASTER_CPUS
vagrant reload pimaster
```

If you resize with `VBoxManage` instead, the next `vagrant reload pimaster` without the variables puts the VM
back to 2 GB / 2 vCPU.

Only if pidev can't run (not enough RAM for a third VM), dev can run on pimaster:
[dev-environment.md appendix](dev-environment.md#appendix-dev-on-pimaster-not-recommended).

## 8. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| A Vagrant command touched pidev too | Commands without a machine name act on both VMs: always write `pimaster` or `pidev` |
| `Plugin vagrant-disksize missing` | `vagrant plugin install vagrant-disksize` |
| `VirtualBox ... name "pimaster" already exists` | The old VM is still registered: [section 5](#5-rebuild) step 1 |
| Vagrant asks which network to bridge, or the bridge fails | The adapter name differs: `VBoxManage list bridgedifs`, then `$env:PIMASTER_BRIDGE = "<name>"` |
| VM created on C: | Machine folder not changed: [section 4](#4-prerequisites-on-windows). Move it with `VBoxManage movevm pimaster --folder "D:\VirtualBox VMs"` (VM off) |
| `WARNING: marmila is uid=... gid=...` | IDs differ from 1001/1002 (box changed). Set `USER_UID` / `USER_GID` in `ansible-runner/docker-compose.yaml` to `id -u` / `id -g` |
| Root disk still small | `sudo pvs; sudo lvs; lsblk` and rerun `vagrant provision --provision-with base` |
| DNS fails (`missing-key`) | `resolvectl status`, check `/etc/systemd/resolved.conf.d/90-dnssec-off.conf` |
| Nodes unreachable | `ip route` must show `10.0.0.0/24 via 192.168.1.21 dev eth2`, and eth2 must have a 192.168.1.x address |
| `ansible ... -m ping` fails with `Permission denied (publickey)` | `~/.ssh/id_rsa` not restored, or the runner generated a new key: restore it, then `docker restart ansible-runner` |
| `ssh` from Windows: `REMOTE HOST IDENTIFICATION HAS CHANGED` | New VM, new host key: `ssh-keygen -R 192.168.56.10` |

## 9. Changes from the original Vagrantfile

| Original (`D:\SCRIPT\vagrant-pimaster`) | Now (`homelab-vagrant/pimaster`) | Why |
| --- | --- | --- |
| One machine | Two: `pimaster` (prod control) and `pidev` (dev, `autostart: false`) | Dev never shares a VM with the runner and its prod kubeconfig |
| 1 GB / 1 vCPU fixed | 2 GB / 2 vCPU, set with `PIMASTER_MEMORY` / `PIMASTER_CPUS` | Runner builds are slow on 1 vCPU; the dev cluster lives on pidev |
| 50 GB disk, LV not extended | 100 GB, partition / PV / LV / filesystem grown by the provisioner | Room for the k3d dev cluster |
| Docker without the compose / buildx plugins | With the plugins | `make ansible-runner-setup` uses `docker compose` |
| pip `ansible`, `ansible-lint`, `molecule` on the host | Removed | Ansible runs in the runner container (CLAUDE.md: never host `ansible-playbook`) |
| `marmila` with an empty password | Locked password, passwordless sudo via `/etc/sudoers.d` | Same sudo behaviour without an empty password |
| No DNSSEC fix | `DNSSEC=no` drop-in | Oct 2026 `missing-key` failure |
| No repo, no runner folders | Repo cloned, folders created | Ready for the restore |
| Inline script | `provision/base.sh` + `dev-tools.sh` (pidev only) | Readable, re-runnable, LF line endings enforced by `.gitattributes` |
| Netplan file 644 | 600 | Avoids netplan's permission warning |
