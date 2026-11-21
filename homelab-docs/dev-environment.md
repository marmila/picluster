# Dev environment: the pidev VM (k3d)

How to run the k3d dev cluster from `dev/` in this homelab. The upstream page
[docs/_docs/dev.md](../docs/_docs/dev.md) explains how the dev environment is built; this page covers where
and how it runs here.

The laptop has two VMs, both defined in [homelab-vagrant/pimaster/Vagrantfile](../homelab-vagrant/pimaster/Vagrantfile):

| VM | Purpose | Size | Host-only IP |
| --- | --- | --- | --- |
| **pimaster** | **Prod control VM**: ansible-runner, SSH key trusted by the nodes, secrets, prod kubeconfig ([pimaster-vm.md](pimaster-vm.md)) | 2 GB / 2 vCPU | 192.168.56.10 |
| **pidev** | **Dev VM**: k3d dev cluster, RustFS / Vault dev containers. No secrets, no ansible-runner | 10 GB / 4 vCPU | 192.168.56.11 |

Dev never runs on pimaster, so a dev mistake (a wrong kubectl context, a full disk, a memory spike) cannot
reach the runner or the prod cluster. pidev is disposable: destroy it and recreate it at any time.

- **First time:** sections [2](#2-prerequisites-on-windows) to [4](#4-start-the-dev-cluster).
- **Day to day:** [section 5](#5-day-to-day).
- **Done for now:** [section 6](#6-stop-free-the-ram-or-delete-pidev).

## Contents

- [1. What it is and what it needs](#1-what-it-is-and-what-it-needs)
- [2. Prerequisites on Windows](#2-prerequisites-on-windows)
- [3. Create pidev](#3-create-pidev)
- [4. Start the dev cluster](#4-start-the-dev-cluster)
- [5. Day to day](#5-day-to-day)
- [6. Stop, free the RAM, or delete pidev](#6-stop-free-the-ram-or-delete-pidev)
- [7. Troubleshooting](#7-troubleshooting)
- [8. Reference](#8-reference)
- [Appendix: dev on pimaster (not recommended)](#appendix-dev-on-pimaster-not-recommended)

## 1. What it is and what it needs

The dev cluster is a single-node **k3d** cluster (K3s in a Docker container), plus RustFS and, optionally,
Vault in Docker Compose, all in Docker on pidev.

```text
Windows laptop (VirtualBox, 21.8 GB RAM, 12 CPUs, VMs on D:)
├── pimaster VM  (prod control, 192.168.56.10)
│   └── ansible-runner container  ──►  prod cluster 10.0.0.0/24
└── pidev VM     (dev, 192.168.56.11)
    └── Docker
        ├── k3d-picluster-server-0     (dev K3s, 172.30.0.2, capped at 5 GiB)
        ├── dev-rustfs                 (172.30.100.10, https://127.0.0.1:9091)
        └── dev-vault                  (optional, 172.30.100.11, http://127.0.0.1:8200)
```

Flux in the dev cluster syncs `https://github.com/marmila/picluster`, branch `master`, path
`kubernetes/clusters/dev`. Base: Cilium, CoreDNS, Flux, metrics-server, local-path storage. Everything else
is an opt-in profile ([section 5](#5-day-to-day)). Changes are committed and pushed from the laptop; pidev only
pulls.

### What pidev gets from the Vagrantfile

| Item | Value |
| --- | --- |
| OS | Ubuntu 22.04 (`generic/ubuntu2204`), x86_64 |
| Size | 10 GB RAM, 4 vCPU (`make dev-preflight` needs 8 GiB **available**), 100 GB disk |
| Base ([base.sh](../homelab-vagrant/pimaster/provision/base.sh)) | user `marmila`, Docker + compose, DNSSEC fix, route `10.0.0.0/24`, repo in `~/picluster` |
| Dev tools ([dev-tools.sh](../homelab-vagrant/pimaster/provision/dev-tools.sh)) | Cilium kernel modules + sysctls, k3d, kubectl, helm 4, tmpl, flux |

### Host RAM budget

| Consumer | About |
| --- | --- |
| Windows, VS Code, Chrome | 8–10 GB |
| pimaster | 1–2 GB |
| ansible-control-node VM | 2 GB |
| pidev (running) | 10 GB |

That is tight on 21.8 GB. Power off `ansible-control-node` while pidev runs if you don't need it, and
`vagrant halt pidev` when you're done ([section 6](#6-stop-free-the-ram-or-delete-pidev)).

## 2. Prerequisites on Windows

One time, in PowerShell. Same as [pimaster-vm.md section 4](pimaster-vm.md#4-prerequisites-on-windows):

```powershell
vagrant --version                       # 2.4.9 tested
vagrant plugin list                     # needs vagrant-disksize
# vagrant plugin install vagrant-disksize

$vb = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $vb list bridgedifs | Select-String '^Name:'     # Wi-Fi name must match PIMASTER_BRIDGE
& $vb list systemproperties | Select-String 'Default machine folder'

# The default folder is on C: (about 28 GB free). New VMs must go to D:
& $vb setproperty machinefolder "D:\VirtualBox VMs"
```

## 3. Create pidev

```powershell
cd C:\Users\marco\bin\picluster
git pull
cd homelab-vagrant\pimaster
vagrant validate
vagrant up pidev
```

Always name the machine. `pidev` is defined with `autostart: false`, so a bare `vagrant up` never creates it,
and a bare `vagrant up` / `reload` / `destroy` in this folder acts on **pimaster**.

The first `up` takes about 10–15 minutes: box download, `base.sh`, then `dev-tools.sh`. Check:

```powershell
vagrant status
vagrant ssh pidev -c "nproc; free -h | head -2; df -h / | tail -1; ip route | grep 10.0.0.0; for c in docker k3d kubectl helm tmpl flux; do command -v `$c || echo `$c MISSING; done; lsmod | grep -c xt_socket"
```

Expected: 4 CPUs, about 9.5 GiB, about 100 GB root, the route, every tool found, `1` for `xt_socket`.

### Log in

The repo is cloned for `marmila`, so work as `marmila`:

```powershell
ssh marmila@192.168.56.11          # same key as pimaster
# or
vagrant ssh pidev                   # logs in as vagrant, then:  sudo -iu marmila
```

## 4. Start the dev cluster

On pidev as `marmila`:

```bash
cd ~/picluster && git pull
cd dev
make dev-preflight
make dev-up
```

`make dev-up` does, in order:

1. Creates the `picluster` Docker network (`172.30.0.0/16`).
2. Renders the k3d config with `tmpl` and creates the cluster `picluster` (context `k3d-picluster`).
3. `bootstrap.sh`: Cilium, CoreDNS, flux-operator, flux-instance, dev `cluster-settings`, waits for the Flux
   root Kustomization.
4. `external-services/up.sh`: generates `.env` and a local dev CA, starts RustFS, creates the buckets and the
   Kubernetes credentials.
5. `smoke.sh`: nodes, base pods, DNS, local-path PVC, metrics, RustFS health.

It ends with `Smoke test passed`.

No kubeconfig juggling is needed: pidev has no ansible-runner and no prod kubeconfig, so k3d can write
`~/.kube/config` and set `k3d-picluster` as the current context.

## 5. Day to day

On pidev, from `~/picluster/dev`:

| Command | What it does |
| --- | --- |
| `make dev-status` | Nodes, Flux Kustomizations, HelmReleases, non-running pods, warnings |
| `make dev-smoke` | Base smoke test, safe to re-run |
| `make dev-usage` | Host memory, Docker stats, `kubectl top` |
| `make dev-render` | Renders every dev kustomization without a cluster (good before a commit) |
| `make dev-bootstrap` | Re-runs the Cilium / CoreDNS / Flux bootstrap |
| `VAULT=1 make dev-services-up` | Adds Vault (needed by the `secrets`, `keycloak` profiles) |
| `make dev-down` | Stops external services, deletes the cluster; RustFS data is kept |
| `make dev-recreate` | down + up |
| `make dev-services-reset` | Deletes RustFS / Vault data, certs and credentials (asks for confirmation) |

### Profiles

Profiles are enabled through Git, because Flux reads `kubernetes/clusters/dev` from `master`:

1. On the laptop, add the profile file to `resources:` in
   [kubernetes/clusters/dev/profiles/kustomization.yaml](../kubernetes/clusters/dev/profiles/kustomization.yaml),
   for example `- cert-manager.yaml`. Commit and push.
2. On pidev: `git pull`, `make dev-render`, then
   `flux reconcile kustomization flux-system -n flux-system --with-source` (or wait for the 1h interval).

Available: `cert-manager`, `ingress` (needs cert-manager), `cnpg`, `secrets` (Vault), `observability`,
`logging`, `tracing`, `messaging`, `data`, `keycloak` (needs cnpg and secrets), `velero`.

With 10 GB, run **at most two heavy profiles** (observability, logging, messaging, keycloak) at a time. Check
with `make dev-usage`. More room: `$env:PIDEV_MEMORY = "12288"; vagrant reload pidev`.

The prod cluster reads `kubernetes/clusters/prod`, so dev profile changes never reach prod.

### POC workspace

```bash
make dev-poc-new NAME=my-poc
# creates test/my-poc/ and kubernetes/clusters/dev/profiles/poc-my-poc.yaml
# copy them to the laptop repo (or create them there), add "- poc-my-poc.yaml" to
# profiles/kustomization.yaml, commit and push from the laptop
```

### Limits

- No Longhorn: `local-path` only, and PVCs are lost when the cluster is deleted.
- No Istio / Kiali (Istio CNI conflicts with Cilium on k3d).
- No IONOS DNS-01 or real certificates: the dev CA is local, self-signed and gitignored.

## 6. Stop, free the RAM, or delete pidev

From `C:\Users\marco\bin\picluster\homelab-vagrant\pimaster`:

| Goal | Command | Keeps |
| --- | --- | --- |
| Pause: give the 10 GB back to Windows | `vagrant halt pidev` | VM, tools, cluster, RustFS data |
| Resume | `vagrant up pidev`, then on pidev `cd ~/picluster/dev && make dev-status` | |
| Delete only the cluster | on pidev: `make dev-down` | VM, tools, RustFS data |
| Delete everything | `vagrant destroy pidev` | nothing (recreate with [section 3](#3-create-pidev)) |

After a `halt` / `up`, the k3d container restarts with Docker. If the cluster isn't healthy,
`make dev-recreate` rebuilds it in a few minutes.

> Always write `pidev` in these commands. `vagrant destroy` without a name targets every machine in the
> folder, pimaster included.

## 7. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `vagrant up` created nothing for dev | Use `vagrant up pidev`: pidev doesn't autostart |
| `VirtualBox ... name "pidev" already exists` | Leftover VM: `VBoxManage unregistervm pidev --delete` |
| pidev disk on C: | Machine folder not changed ([section 2](#2-prerequisites-on-windows)). Move it with `VBoxManage movevm pidev --folder "D:\VirtualBox VMs"` (VM off) |
| `ERROR: only N GiB available, need at least 8 GiB` | Check `free -h`. Grow pidev (`PIDEV_MEMORY`) or, for small tests only, `make dev-up DEV_MIN_MEM_GB=6` |
| VirtualBox refuses to start pidev, or Windows gets slow | Host out of RAM. Close apps, power off `ansible-control-node`, or `$env:PIDEV_MEMORY = "8192"` |
| Tools missing | `vagrant provision pidev --provision-with dev-tools` |
| Node stays `NotReady`, Cilium pods crash | Kernel modules: `lsmod \| grep xt_socket`, or `make load-kernel-modules` |
| `kubectl context is '...', expected 'k3d-picluster'` | `kubectl config use-context k3d-picluster` |
| `/etc/bash.bashrc: line 7: PS1: unbound variable` from make | Harmless if the step continues; if it stops: `echo $BASH_ENV` and check `/etc/bash.bashrc` |
| Flux not picking up a profile | Pushed to `master`? `flux get sources git -A`, then reconcile with `--with-source` |
| PVC `Pending` | Normal with local-path (`WaitForFirstConsumer`) until a pod uses it |
| RustFS TLS errors in a POC | Copy the `rustfs-ca` Secret and use the dev CA (`dev/external-services/certs/ca.crt`) |
| Disk filling up | `docker system df`, `docker image prune` (unused images only), `make dev-recreate` |

## 8. Reference

| Item | Value |
| --- | --- |
| VM | `pidev`, 192.168.56.11, `vagrant up pidev` from `homelab-vagrant/pimaster` |
| VM size variables | `PIDEV_MEMORY` (MB, default 10240), `PIDEV_CPUS` (default 4) |
| k3d cluster / context | `picluster` / `k3d-picluster` |
| K3s image | `rancher/k3s:v1.37.1-k3s1` (same as prod) |
| Docker network | `picluster`, `172.30.0.0/16`, gateway `172.30.0.1` |
| Pod / service CIDR | `10.42.0.0/16` / `10.43.0.0/16` |
| LoadBalancer pool (Cilium) | `172.30.200.1`–`172.30.200.254` |
| RustFS | `https://127.0.0.1:9091` (console `:9092`), in cluster `rustfs.dev-external.svc.cluster.local:9091` |
| Vault (optional) | `http://127.0.0.1:8200`, dev root token in `dev/external-services/.env` |
| Flux source | `marmila/picluster`, `master`, `kubernetes/clusters/dev` |
| Scripts | [dev/Makefile](../dev/Makefile), [dev/README.md](../dev/README.md) |
| Upstream doc | [docs/_docs/dev.md](../docs/_docs/dev.md), <https://picluster.ricsanfre.com/docs/dev/> |

## Appendix: dev on pimaster (not recommended)

Only if pidev can't run (for example, not enough RAM for a third VM). It mixes dev with the prod control VM.

1. Resize pimaster to 10 GB / 4 vCPU. If pimaster was rebuilt from the repo Vagrantfile:
   `$env:PIMASTER_MEMORY = "10240"; $env:PIMASTER_CPUS = "4"; vagrant reload pimaster`. If it is still the
   original VM: power it off, `VBoxManage modifyvm pimaster --memory 10240 --cpus 4`, start it. The
   ansible-runner restarts by itself (`restart: unless-stopped`).
2. Install the tools: `vagrant provision pimaster --provision-with dev-tools` (repo-built VM), or run the
   commands from [dev-tools.sh](../homelab-vagrant/pimaster/provision/dev-tools.sh) by hand with `sudo`.
3. **Keep dev out of the runner's kubeconfig.** The runner mounts `~/.kube`, and k3d would make
   `k3d-picluster` the current context there. In every dev shell:

   ```bash
   export KUBECONFIG=$HOME/.kube/k3d-dev.yaml
   md5sum ~/.kube/config            # note it, compare after make dev-up
   cd ~/picluster/dev && make dev-preflight && make dev-up
   grep -c k3d-picluster ~/.kube/config   # must be 0
   ```

4. When done: `make dev-down`, then shrink pimaster back to 2 GB / 2 vCPU.

Do not use `docker system prune -a` on pimaster: if the runner happens to be stopped, it deletes the runner
image too.
