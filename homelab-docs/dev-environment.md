# Dev environment on pimaster (k3d)

How to run the k3d dev cluster from `dev/` on the pimaster VM, which also hosts the ansible-runner container.
The upstream page [docs/_docs/dev.md](../docs/_docs/dev.md) explains how the dev environment is built; this page
covers how it runs in this homelab: resizing the VM, installing the tools and keeping the dev cluster away
from the ansible-runner's kubeconfig.

- **First time:** sections [2](#2-resize-the-pimaster-vm) to [5](#5-start-the-dev-cluster), in order.
- **Day to day:** [section 6](#6-day-to-day).
- **Done with dev for a while:** [section 7](#7-stop-and-give-the-ram-back).

## Contents

- [1. What it is and what it needs](#1-what-it-is-and-what-it-needs)
- [2. Resize the pimaster VM](#2-resize-the-pimaster-vm)
- [3. Check pimaster and the runner after the resize](#3-check-pimaster-and-the-runner-after-the-resize)
- [4. Install tools and kernel settings (one time)](#4-install-tools-and-kernel-settings-one-time)
- [5. Start the dev cluster](#5-start-the-dev-cluster)
- [6. Day to day](#6-day-to-day)
- [7. Stop and give the RAM back](#7-stop-and-give-the-ram-back)
- [8. Troubleshooting](#8-troubleshooting)
- [9. Reference](#9-reference)

## 1. What it is and what it needs

The dev cluster is a single-node **k3d** cluster (K3s in a Docker container), plus RustFS and, optionally,
Vault in Docker Compose. Everything runs in Docker on one x86 Ubuntu host. No new VM is needed: pimaster
already runs Docker for the ansible-runner.

```text
Windows host (VirtualBox, 21.8 GB RAM, 12 CPUs)
└── pimaster VM (Ubuntu 22.04, disk on D:)
    └── Docker
        ├── ansible-runner             (existing, network_mode: host)
        ├── k3d-picluster-server-0     (dev K3s, 172.30.0.2, capped at 5 GiB)
        ├── dev-rustfs                 (172.30.100.10, https://127.0.0.1:9091)
        └── dev-vault                  (optional, 172.30.100.11, http://127.0.0.1:8200)
```

Flux in the dev cluster syncs `https://github.com/marmila/picluster`, branch `master`, path
`kubernetes/clusters/dev`. Base: Cilium, CoreDNS, Flux, metrics-server, local-path storage. Everything else
is an opt-in profile (see [section 6](#6-day-to-day)).

### Requirements vs pimaster before the resize (checked 2026-11-10)

| Item | Needed | pimaster before |
| --- | --- | --- |
| vCPU | 4 | 1 |
| RAM | 10 GB (`make dev-preflight` fails under 8 GiB **available**) | 1 GB (0.6 GiB available) |
| Free disk in the VM | 30–40 GB | 29 GB, plus about 9.5 GB of reclaimable Docker build cache |
| Free disk on the host | the VDI grows dynamically | D: 843 GB free: OK |
| Tools | docker, k3d, kubectl, helm, tmpl, openssl, curl (flux optional) | only docker, openssl, curl |
| Kernel | iptables modules + `xt_socket` for Cilium | not loaded |
| Network | `172.30.0.0/16` and ports 6443, 9091, 9092, 8200 free | free |

### Host RAM budget

The Windows host has 21.8 GB. With pimaster at 10 GB:

| Consumer | About |
| --- | --- |
| Windows, VS Code, Chrome | 8–10 GB |
| pimaster | 10 GB |
| ansible-control-node VM | 2 GB |

That is tight. Power off `ansible-control-node` while you use dev if you don't need it, and shrink pimaster
back when you're done ([section 7](#7-stop-and-give-the-ram-back)).

## 2. Resize the pimaster VM

Changing RAM and CPUs only edits the VM's VirtualBox settings. The disk, network adapters (NAT, host-only
192.168.56.10, bridged 192.168.1.7) and everything inside Ubuntu stay the same. The ansible-runner has
`restart: unless-stopped`, so Docker starts it again after the reboot.

The VM must be **powered off**. Make sure no playbook is running in the runner first.

From **Windows PowerShell**:

```powershell
$vb = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

# 1. Shut pimaster down cleanly
& $vb controlvm pimaster acpipowerbutton

# 2. Repeat until it says VMState="poweroff"
& $vb showvminfo pimaster --machinereadable | Select-String '^VMState='

# 3. Resize: 10 GB RAM, 4 vCPU
& $vb modifyvm pimaster --memory 10240 --cpus 4

# 4. Check and start
& $vb showvminfo pimaster --machinereadable | Select-String '^(memory|cpus)='
& $vb startvm pimaster --type headless

# Optional: free 2 GB on the host while working on dev
# & $vb controlvm ansible-control-node acpipowerbutton
```

## 3. Check pimaster and the runner after the resize

SSH into pimaster and run:

```bash
echo "== Resources =="; nproc; free -h; grep MemAvailable /proc/meminfo
echo "== Runner =="; docker ps --filter name=ansible-runner --format '{{.Names}} {{.Status}}'
docker exec ansible-runner bash -lc 'ansible --version | head -1; ls ~/.kube'
echo "== Disk =="; df -h /; docker system df
```

Expected: `4` CPUs, about 9.5 GiB total, `ansible-runner Up ...` and an ansible version.

If the runner is not running:

```bash
docker start ansible-runner
# or, from the repo root:
cd ~/picluster && make ansible-runner-setup
```

Free the Docker build cache (about 9.5 GB). This removes only build cache, not the `ansible-runner` image; the
next runner rebuild is just slower:

```bash
docker builder prune -f
docker system df; df -h /
```

> Do **not** use `docker system prune -a`. If the runner happens to be stopped, it deletes the runner image
> too.

## 4. Install tools and kernel settings (one time)

### 4.1 Tools

Versions follow [.mise.toml](../.mise.toml). If you use mise on the VM, `mise install` in the repo covers
kubectl, helm and flux; k3d and tmpl are still needed.

```bash
# k3d
wget -q -O - https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# kubectl (same minor as .mise.toml / prod)
curl -LO https://dl.k8s.io/release/v1.37.2/bin/linux/amd64/kubectl
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl && rm kubectl

# helm 4
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

# tmpl: renders dev/k3d-cluster/k3d-cluster.yaml.tmpl (not checked by dev-preflight).
# Needs a recent Go; the Ubuntu 22.04 apt package is too old, the snap is current.
sudo snap install go --classic
go install github.com/krakozaure/tmpl@latest
sudo install -m 0755 ~/go/bin/tmpl /usr/local/bin/tmpl

# flux CLI (optional, used by status.sh and bootstrap.sh when present)
curl -s https://fluxcd.io/install.sh | sudo bash
```

Check:

```bash
for c in docker k3d kubectl helm tmpl openssl curl flux; do printf '%-8s ' $c; command -v $c || echo MISSING; done
k3d version; kubectl version --client; helm version --short
```

### 4.2 Kernel modules and sysctls for Cilium

Persistent across reboots (the upstream page's sysctl snippet has a broken quote; this is the corrected one):

```bash
cat <<'EOF' | sudo tee /etc/modules-load.d/cilium-dev.conf
iptable_filter
ip_tables
iptable_mangle
iptable_raw
iptable_nat
xt_socket
EOF
sudo systemctl restart systemd-modules-load
lsmod | grep -E 'xt_socket|iptable_(filter|mangle|raw|nat)'

cat <<'EOF' | sudo tee /etc/sysctl.d/90-k3d-dev.conf
net.core.devconf_inherit_init_net=1
net.netfilter.nf_conntrack_max=196608
net.ipv4.conf.all.forwarding=1
EOF
sudo sysctl --system | grep -E 'devconf|conntrack_max|all.forwarding'
```

`net.ipv4.conf.all.forwarding=1` is already on wherever Docker runs, so it changes nothing for the runner.

## 5. Start the dev cluster

### 5.1 Keep dev out of the runner's kubeconfig

The ansible-runner mounts the VM's `~/.kube` ([docker-compose.yaml](../ansible-runner/docker-compose.yaml)).
By default k3d writes the dev cluster into `~/.kube/config` **and makes it the current context**, so
anything in the runner that uses the default context would then hit the dev cluster.

Always point dev at its own kubeconfig file, in **every shell** you use for dev:

```bash
export KUBECONFIG=$HOME/.kube/k3d-dev.yaml
```

Optional shortcut in `~/.bashrc`:

```bash
alias devenv='export KUBECONFIG=$HOME/.kube/k3d-dev.yaml; cd ~/picluster/dev'
```

### 5.2 First start

```bash
cd ~/picluster && git pull
export KUBECONFIG=$HOME/.kube/k3d-dev.yaml
# Note what the runner's kubeconfig looks like before
md5sum ~/.kube/config 2>/dev/null || echo "no ~/.kube/config"

cd dev
make dev-preflight
make dev-up
```

`make dev-up` does, in order:

1. Creates the `picluster` Docker network (`172.30.0.0/16`).
2. Renders the k3d config with `tmpl` and creates the cluster `picluster` (context `k3d-picluster`).
3. `bootstrap.sh`: Cilium, CoreDNS, flux-operator, flux-instance, dev `cluster-settings`, waits for the Flux
   root Kustomization.
4. `external-services/up.sh`: generates `.env` and a local dev CA, starts RustFS, creates the buckets and
   Kubernetes credentials.
5. `smoke.sh`: nodes, base pods, DNS, local-path PVC, metrics, RustFS health.

It ends with `Smoke test passed`.

### 5.3 Verify the runner kubeconfig was not touched

```bash
md5sum ~/.kube/config 2>/dev/null || echo "no ~/.kube/config"   # same as before
grep -c k3d-picluster ~/.kube/config 2>/dev/null                # 0 or no file
kubectl config get-contexts                                      # with KUBECONFIG set: k3d-picluster only
```

If k3d wrote into `~/.kube/config` anyway, remove the dev entries from it and switch back:

```bash
kubectl --kubeconfig ~/.kube/config config get-contexts
kubectl --kubeconfig ~/.kube/config config delete-context k3d-picluster
kubectl --kubeconfig ~/.kube/config config delete-cluster k3d-picluster
kubectl --kubeconfig ~/.kube/config config delete-user admin@k3d-picluster
# then, if the file has another context left:
# kubectl --kubeconfig ~/.kube/config config use-context <previous-context>
```

## 6. Day to day

Always run these from `~/picluster/dev` with `KUBECONFIG=$HOME/.kube/k3d-dev.yaml`.

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

1. Add the profile file to `resources:` in
   [kubernetes/clusters/dev/profiles/kustomization.yaml](../kubernetes/clusters/dev/profiles/kustomization.yaml),
   for example `- cert-manager.yaml`.
2. `make dev-render`, commit, push.
3. `flux reconcile kustomization flux-system -n flux-system --with-source`, or wait for the 1h interval.

Available: `cert-manager`, `ingress` (needs cert-manager), `cnpg`, `secrets` (Vault), `observability`,
`logging`, `tracing`, `messaging`, `data`, `keycloak` (needs cnpg and secrets), `velero`.

With 10 GB on pimaster, run **at most two heavy profiles** (observability, logging, messaging, keycloak) at a
time. Check with `make dev-usage`.

The prod cluster reads `kubernetes/clusters/prod`, so dev profile changes never reach prod.

### POC workspace

```bash
make dev-poc-new NAME=my-poc
# creates test/my-poc/ and kubernetes/clusters/dev/profiles/poc-my-poc.yaml
# add "- poc-my-poc.yaml" to profiles/kustomization.yaml, commit, push
```

### Limits

- No Longhorn: `local-path` only, and PVCs are lost when the cluster is deleted.
- No Istio / Kiali (Istio CNI conflicts with Cilium on k3d).
- No IONOS DNS-01 or real certificates: the dev CA is local, self-signed and gitignored.

## 7. Stop and give the RAM back

```bash
cd ~/picluster/dev
export KUBECONFIG=$HOME/.kube/k3d-dev.yaml
make dev-down
```

Then, from Windows PowerShell, shrink pimaster back (2 GB is enough for the runner):

```powershell
$vb = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"
& $vb controlvm pimaster acpipowerbutton
& $vb showvminfo pimaster --machinereadable | Select-String '^VMState='   # wait for "poweroff"
& $vb modifyvm pimaster --memory 2048 --cpus 2
& $vb startvm pimaster --type headless
```

Next time: resize up again ([section 2](#2-resize-the-pimaster-vm)) and run `make dev-up`. The tools and kernel
settings stay installed.

## 8. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `ERROR: only N GiB available, need at least 8 GiB` | VM not resized, or something else is using memory. Check `free -h`. Override only for small tests: `make dev-up DEV_MIN_MEM_GB=6` |
| VirtualBox refuses to start pimaster, or Windows gets slow | Host out of RAM. Close apps, power off `ansible-control-node`, or use `--memory 8192` |
| `tmpl: command not found` in `create_cluster.sh` | [section 4.1](#41-tools) |
| Node stays `NotReady`, Cilium pods crash | Kernel modules not loaded: `lsmod \| grep xt_socket`, or run `make load-kernel-modules` |
| `kubectl context is '...', expected 'k3d-picluster'` | `KUBECONFIG` not exported in this shell |
| The runner talks to the dev cluster | k3d wrote into `~/.kube/config`: [section 5.3](#53-verify-the-runner-kubeconfig-was-not-touched) |
| ansible-runner not up after the resize | `docker start ansible-runner`, or `make ansible-runner-setup` |
| Flux not picking up a profile | Was it pushed to `master`? `flux get sources git -A`, then reconcile with `--with-source` |
| PVC `Pending` | Normal with local-path (`WaitForFirstConsumer`) until a pod uses it |
| RustFS TLS errors in a POC | Copy the `rustfs-ca` Secret and use the dev CA (`dev/external-services/certs/ca.crt`) |
| Disk filling up | `docker system df`, `docker image prune` (unused images only), `make dev-recreate` |

## 9. Reference

| Item | Value |
| --- | --- |
| k3d cluster / context | `picluster` / `k3d-picluster` |
| Dev kubeconfig | `~/.kube/k3d-dev.yaml` |
| K3s image | `rancher/k3s:v1.37.1-k3s1` (same as prod) |
| Docker network | `picluster`, `172.30.0.0/16`, gateway `172.30.0.1` |
| Pod / service CIDR | `10.42.0.0/16` / `10.43.0.0/16` |
| LoadBalancer pool (Cilium) | `172.30.200.1`–`172.30.200.254` |
| RustFS | `https://127.0.0.1:9091` (console `:9092`), in cluster `rustfs.dev-external.svc.cluster.local:9091` |
| Vault (optional) | `http://127.0.0.1:8200`, dev root token in `dev/external-services/.env` |
| Flux source | `marmila/picluster`, `master`, `kubernetes/clusters/dev` |
| Scripts | [dev/Makefile](../dev/Makefile), [dev/README.md](../dev/README.md) |
| Upstream doc | [docs/_docs/dev.md](../docs/_docs/dev.md), <https://picluster.ricsanfre.com/docs/dev/> |
