# Quick start: make targets and playbooks in this fork

How to build the cluster from scratch, and the `make` commands for day-to-day work. It follows the upstream guide,
[Quick Start Instructions](https://picluster.ricsanfre.com/docs/ansible/), and adds this fork's targets and
changes. The upstream guide still covers hardware, cloud-init and the gateway. This page only covers what is
different or new here.

## Contents

1. [Where commands run](#1-where-commands-run)
2. [One-time setup on pimaster](#2-one-time-setup-on-pimaster)
3. [Full install from scratch](#3-full-install-from-scratch)
4. [Day-to-day commands](#4-day-to-day-commands)
5. [Destructive commands](#5-destructive-commands)
6. [All make targets](#6-all-make-targets)
7. [Fork differences from upstream](#7-fork-differences-from-upstream)

## 1. Where commands run

| Where | What |
|---|---|
| **Laptop (Windows)** | Edit, commit, push. Nothing else |
| **pimaster** (`~/picluster`) | `git pull`, then every `make` target. Ansible runs inside the ansible-runner container through `./ansible-runner/ansible-runner.sh` |
| **node2** | `kubectl` and the `flux` CLI (installed with `make admin-cli`) |
| **node1** | Host checks for Vault, RustFS and bind9 (`vault`, `rc`, `df`, `systemctl`) |

Rules:

- Never run `ansible-playbook` directly on the host. Use `make` or `./ansible-runner/ansible-runner.sh ansible-playbook ...`.
  The only exception is `install-local-utils`, see [section 6](#6-all-make-targets).
- In the inventory, `pimaster` is the runner container (local connection), not the VM. Apt does not update it;
  rebuilding the image does (`make ansible-runner-setup`).
- Before running any target, `git pull` on pimaster so it uses the playbooks you just pushed.
- The Galaxy roles and collections are baked into the runner image at build time. After a change to
  `ansible/requirements.yml` (for example a Renovate bump or a cherry-pick), run `make ansible-runner-setup`
  first, or the old role version keeps running.

`make` or `make help` lists every target with its one-line description.

## 2. One-time setup on pimaster

```bash
cd ~/picluster
git pull
make ansible-runner-setup        # build/start the runner container, create ~/.ssh/id_rsa if missing
make secret-files                # prompts for the secrets below, writes ~/.secrets/*.ini
```

`make prepare-ansible` runs both commands.

### Secret files in `~/.secrets`

They live only on pimaster; never commit them. `make secret-files` creates them, and
`make load-external-services-keys` copies them into Vault.

| File | Contents | Upstream / fork |
|---|---|---|
| `ionos-credentials.ini` | IONOS DNS API prefix and secret (certbot, external-dns, Let's Encrypt) | upstream |
| `github-pat.ini` | GitHub PAT, only when `git_private_repo: true` | upstream |
| `threatmap-credentials.ini` | Shodan, AbuseIPDB, OTX, MaxMind licence key and account ID | **fork** |
| `alertmanager-notifications.ini` | ntfy URL, healthchecks.io ping URL | **fork** |
| `sre-triage.ini` | Claude Code token and ntfy topics for the triage agent. Leave the token empty to skip | **fork** |

The Vault root/unseal file is written by `make external-services`. `k3s_install.yml` reads the k3s token
from Vault on demand, so Vault must be up before `make k3s-install`.

### Local mode (no Docker)

```bash
make ansible-local-setup                              # uv env + galaxy roles/collections
ANSIBLE_RUNNER_MODE=local ./ansible-runner/ansible-runner.sh ansible-playbook --version
```

This is for lint and syntax checks. Real runs use the container.

## 3. Full install from scratch

Do the steps in this order. Steps marked **fork** don't exist upstream, or work differently here.

| # | Command | What it does | Notes |
|---|---|---|---|
| 0 | edit `ansible/inventory.yml`, `ansible/vars/picluster.yml`, `host_vars/` | MACs, IPs, groups | node-esp-1/2 have `rancher_storage_dir` in host_vars (**fork**) |
| 1 | `cd metal/x86 && make get-kernel-files get-uefi-files` | PXE boot files | upstream |
| 2 | install node1 (cloud-init), then `make external-setup` | OS base, security, NTP on node1 | upstream |
| 3 | `make dns-setup` | bind9 authoritative for `homelab.marmilan.com` on node1 | upstream. The gateway forwards to it; external-dns writes into it (rfc2136) |
| 4 | `make pxe-setup` | PXE server on node1, cloud-init per x86 host | **Always** run before reinstalling a node-esp: it regenerates the autoinstall file (fork template: 80G root) |
| 5 | install node2–6 (Pi, cloud-init) and node-esp-1/2 (PXE) | | |
| 6 | `make os-upgrade-check`, then `make os-upgrade` | patch the fresh OS | **fork**: one node at a time, see [node-os-maintenance.md](node-os-maintenance.md). Before k3s exists, the drain and Longhorn steps are skipped |
| 7 | `make nodes-setup` | OS base on the k3s nodes, journald limit, Pi throttling metrics | **fork**: on a fresh node-esp it also bind-mounts `/var/lib/rancher` to `/storage` (tag `storage`) |
| 8 | `make secret-files` | if not done in section 2 | |
| 9 | `make external-services` | Vault (init, unseal, Terraform), RustFS (deploy, buckets, users), keys into Vault | RustFS replaces MinIO (`deploy-minio` is legacy) |
| 10 | `make load-external-services-keys` | loads the fixed secrets into Vault | **fork**: also loads the ThreatMap, Alertmanager (ntfy URL with the compact template) and SRE triage secrets. `external-services` already runs it; run it again on its own after changing a `~/.secrets` file |
| 11 | `make configure-os-backup` | restic jobs on the nodes | upstream |
| 12 | `make k3s-install` | K3s masters (node2–4) and workers | kubeconfig ends up in the runner |
| 13 | `make k3s-bootstrap` | installs Flux, which deploys everything from `master` | `make k3s-bootstrap-dev` for the dev overlay |
| 14 | `make admin-cli` | flux CLI on node2, at the cluster's Flux version | **fork**. `ADMIN_CLI_HOST=node3` for another node |
| 15 | `make node-config-update` | kubelet config, journald on non-k3s hosts, Pi throttling, **RustFS bucket metrics on node1** | **fork**. Steps 2 and 9 do not install the RustFS timer; only this target does |
| 16 | `make os-backup` | first restic backup | upstream |

`make init` runs steps 6, 7, 9, 11, 12 and 13 in one go: `os-upgrade nodes-setup external-services
configure-os-backup k3s-install k3s-bootstrap`. It does **not** run `external-setup`, `dns-setup`,
`pxe-setup`, `secret-files`, `admin-cli` or `node-config-update`.

### Check after install (node2)

```bash
kubectl get nodes -o wide
flux get kustomizations -A | grep -v True
kubectl -n longhorn-system get volumes.longhorn.io | grep -v healthy
```

## 4. Day-to-day commands

### OS upgrades (fork)

```bash
make os-upgrade-check     # dry run: pending packages, which nodes would drain/reboot. Changes nothing
make os-upgrade           # workers → masters → node1, one node at a time
```

Before each node, the run checks that every node is Ready and that the other nodes have CPU, memory and disk room
for its pods. If the node needs a reboot, the run drains it, reboots, uncordons, then waits until no Longhorn volume
is degraded. Any failure stops the whole run. Details and options: [node-os-maintenance.md](node-os-maintenance.md).

### Node configuration changes (fork)

```bash
make node-config-update
```

Run it after changing:

- `k3s_kubelet_config` (for example the image GC thresholds);
- the journald limit;
- the Pi throttling script;
- the RustFS bucket metrics script.

It restarts k3s only on nodes whose kubelet config changed, one at a time, and waits for each to be Ready.

### K3s server config changes

```bash
make k3s-config
```

This target came from upstream with the 2026-11 cherry-picks. Run it after changing `k3s_server_config` in
`ansible/vars/picluster.yml`, for example the `disable:` add-on list. It renders `/etc/rancher/k3s/config.yaml` on the
masters (node2–4) from the same template as the install. It restarts k3s only where the file changed, one master
at a time so etcd keeps quorum, and waits for each master to be Ready. It never runs the installer.

Don't use `make k3s-install` for this. In HA mode it runs the installer only on the first master, so the other
masters would get the new file but never restart.

The k3s **version** is upgraded by the system-upgrade-controller Plans (Flux), not by this target. Keep
`k3s_version` in `vars/picluster.yml` and the Plans at the same version.

### Moving k3s data to /storage (fork, node-esp-1/2)

Done on both nodes on 2026-11-15. You only need this again after a node-esp is reinstalled over an old layout.

```bash
make move-rancher-to-storage-check     # dry run: sizes, free space, plan
make move-rancher-to-storage           # drain, stop k3s, rsync, bind mount, start, uncordon
make move-rancher-to-storage-cleanup   # after checking the node: delete /var/lib/rancher.old (no drain)
```

Rollback steps are in runbook CLUSTER-012.

### Secrets and alerting (fork)

After changing a file in `~/.secrets` (a new ntfy topic, healthchecks URL or Claude token):

```bash
make load-external-services-keys
```

External Secrets picks the change up from Vault. The Alertmanager secret refreshes on its own. For the
triage agent, restart its pod. See [alerting.md](alerting.md) and [sre-triage-agent.md](sre-triage-agent.md).

### Flux upgrades (fork)

After Renovate bumps Flux, set `fluxcd_version` in `ansible/vars/picluster.yml`, then run:

```bash
make admin-cli
```

### Other

| Command | Use |
|---|---|
| `make get-pi-status` | `pi_throttling` on every Pi (under-voltage, throttling). The same data is in Prometheus |
| `make os-backup` | start a restic backup on all nodes now |
| `make openwrt-certbot-tls` | renew the gateway TLS certificate with certbot and deploy it to OpenWRT (Let's Encrypt item in the [checklist](ops-checklist.md)) |
| `make deploy-monitoring-agent` | Fluent Bit agent on node1, which sends node1's logs to Fluentd in the cluster. It works on node1 since the 2026-11 cherry-picks: the Vault lookup runs on the controller, `Self_Hostname` is indented, and role v1.0.6 is needed, so rebuild the runner first |
| `make configure-vault` / `make configure-minio` | re-apply the Terraform for Vault / RustFS (these are `tofu apply`: ask first) |
| `make lint-ci` | yamllint like CI does |
| `make syntax-check-external-services` | Ansible syntax check |
| `make uv-lock-check` | `uv.lock` in sync with `pyproject.toml` |

### Shutdown

```bash
make shutdown-k3s-worker     # workers first
make shutdown-k3s-master     # then masters
make shutdown-picluster      # or every node at once (1 minute delay)
```

node1 (Vault, RustFS) goes down with `shutdown-picluster`. After power returns, Vault must be unsealed before the
cluster can read secrets.

### Dev cluster

The k3d dev cluster runs on the pimaster VM and has its own Makefile in `dev/` (`make -C dev dev-up`,
`dev-status`, `dev-down`, ...). See [dev-environment.md](dev-environment.md).

## 5. Destructive commands

Only run these on purpose, after a backup check:

| Command | Effect |
|---|---|
| `make k3s-reset` | uninstalls K3s from every node (all cluster state is gone) |
| `make external-services-reset` | removes Vault and RustFS from node1 (secrets and S3 data) |
| `make clean` | both of the above |
| `make configure-vault`, `make configure-minio` | Terraform apply against live Vault / RustFS |

## 6. All make targets

**F** = added in this fork, **C** = changed in this fork, blank = as upstream.

| Target | | Playbook / command |
|---|---|---|
| `help` | | list targets |
| `prepare-ansible` | | `ansible-runner-setup` + `secret-files` |
| `ansible-runner-setup` | | build the runner container |
| `ansible-local-setup`, `ansible-local-galaxy`, `ansible-local-lint`, `ansible-local-syntax-check-external-services` | | uv-based local env |
| `uv-lock-check`, `lint`, `lint-ci`, `syntax-check-external-services`, `lint-fix-whitespace` | | checks |
| `init` | | full install, see [section 3](#3-full-install-from-scratch) |
| `secret-files` | C | `create_secret_files.yml`, with extra prompts for ThreatMap, Alertmanager and SRE triage |
| `os-upgrade` | C | `update.yml`: serial, drain, capacity pre-flight, Longhorn wait |
| `os-upgrade-check` | F | `update.yml --check --diff` |
| `node-config-update` | F | `update_node_config.yml` |
| `move-rancher-to-storage`, `-check`, `-cleanup` | F | `move_rancher_to_storage.yml` |
| `external-setup` | | `setup_picluster.yml --tags external` |
| `nodes-setup` | C | `setup_picluster.yml --tags node`, plus the `/storage` bind mount on fresh node-esp |
| `dns-setup` | | `configure_dns_authoritative.yml` |
| `pxe-setup` | C | `configure_pxe_server.yml` (fork cloud-init template) |
| `external-services` | | `external_services.yml` |
| `deploy-vault`, `deploy-rustfs`, `deploy-minio` (legacy) | | single external service |
| `configure-vault`, `configure-minio` | | Terraform via Ansible |
| `load-external-services-keys` | C | `load_external_services_keys.yml`, plus ThreatMap, Alertmanager and SRE triage secrets |
| `configure-os-backup`, `os-backup` | | restic |
| `k3s-install` | C | `k3s_install.yml` |
| `k3s-config` | | `k3s_config.yml`: rolling apply of the k3s server config on the masters (cherry-picked from upstream 2026-11) |
| `k3s-bootstrap`, `k3s-bootstrap-dev` | | Flux bootstrap |
| `k3s-reset`, `external-services-reset`, `clean` | | **destructive** |
| `openwrt-certbot-tls` | | gateway certificate |
| `deploy-monitoring-agent` | | `deploy_monitoring_agent.yml`: Fluent Bit agent on node1 |
| `shutdown-k3s-worker`, `shutdown-k3s-master`, `shutdown-picluster` | | shutdown in 1 min |
| `get-pi-status` | | `pi_throttling` on the Pis |
| `admin-cli` | F | `install_admin_cli.yml` (flux CLI on node2) |
| `install-local-utils` | F | `install_utilities_localhost.yml` (helm, kubectl on the host). Legacy: it runs host Ansible with `--ask-become-pass`, which breaks the runner-only rule, and upstream removed it. The runner image already has these tools |

## 7. Fork differences from upstream

- **Cherry-picked from upstream (2026-11, PR #992):**
  - `make k3s-config`;
  - k3s `v1.37.2+k3s1` with the `gateway-api-crd` add-on disabled;
  - the node1 Fluent Bit agent fixes and role `ricsanfre.fluentbit` v1.0.6;
  - the external-dns annotation prefix, so `fluentd.homelab.marmilan.com` reaches node1's bind;
  - the mixin pins and fixes.
- **Not in this fork yet:** upstream's split kubeconfig handling in `k3s_install.yml`. In this fork the
  kubeconfig is still written as one file. Check the cherry-pick report before you copy anything else from upstream.
- **Upstream digest:** a monthly CI job opens an issue listing new upstream commits, as a starting point for the
  next cherry-pick round.
- **Removed:** the upstream `rpi_metrics` role. Its replacement is `basic_setup/tasks/rpi_throttle_metrics.yml`,
  installed by `nodes-setup` / `node-config-update`.
- **New task files** (included by the playbooks above, not run on their own):
  - `os_upgrade_node.yml`, `k3s_preflight.yml`, `k3s_wait_longhorn.yml`: OS upgrade and the rancher move;
  - `rancher_bind_mount.yml`: the `/storage` bind mount;
  - `load_alertmanager_notifications_into_vault.yml`, `load_sre_triage_into_vault.yml`,
    `load_threatmap_credentials_into_vault.yml`: Vault loading;
  - `install_fluxcd_cli.yml`: the flux CLI.
- **New node1 metrics:** `rustfs_bucket_metrics` (hourly systemd timer, `/var/lib/node_exporter/rustfs_buckets.prom`),
  alerted by `RustFSBucketGrowingFast`, `RustFSOrphanedData` and `RustFSBucketMetricsMissing` (runbook CLUSTER-012).
