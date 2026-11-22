# Homelab docs

Documentation for changes made in this fork (marmila/picluster). The `docs/` folder is the upstream Jekyll
website and stays as upstream has it, so syncs from upstream do not conflict. Anything specific to this
homelab goes here.

| Document | What it covers |
|---|---|
| [quick-start.md](quick-start.md) | Build from scratch and day-to-day `make` targets: where commands run, secret files, install order, `k3s-config`, fork-only targets (`os-upgrade-check`, `node-config-update`, `move-rancher-to-storage*`, `admin-cli`), destructive targets, full target table |
| [alerting.md](alerting.md) | How alerts reach a phone (ntfy, healthchecks.io), certificate alerts, k3s upgrade alerts, node disk alerts, Terraform alerts, backup / secrets / storage / scrape-target alerts, Raspberry Pi under-voltage alerts, node temperature alerts, the weekly ntfy digest, alerts and the triage agents |
| [cluster-maintenance.md](cluster-maintenance.md) | Keeping the cluster updated: how Renovate works here, daily / weekly / monthly tasks, critical update order, event procedures |
| [update-automation.md](update-automation.md) | How Renovate updates get checked by CI and (step by step) merged automatically, and the alerts that watch them |
| [node-os-maintenance.md](node-os-maintenance.md) | OS package upgrades (`make os-upgrade-check`, `make os-upgrade`: pre-flight incl. CPU, memory and disk of the other nodes, drain, reboot, uncordon, progress-based Longhorn wait, one node at a time) and the manual safe reboot of a node |
| [disk-replacement.md](disk-replacement.md) | Replace every node's SSD one at a time without downtime (after the 2026-11-22 worn-disk incident): new sizes and models, Pi adapter compatibility, order, procedures for Pi workers, x86 workers (PXE), masters (etcd) and node1 (clone) |
| [ops-checklist.md](ops-checklist.md) | Working checklist: what was done in November 2026, the checks for the next days, open follow-ups and backlog |
| [pimaster-vm.md](pimaster-vm.md) | Rebuild the **pimaster** prod control VM with Vagrant ([homelab-vagrant/pimaster/](../homelab-vagrant/pimaster/)): backup of keys / secrets / kubeconfig, rebuild, restore, ansible-runner start, resize |
| [dev-environment.md](dev-environment.md) | k3d dev cluster on the separate **pidev** VM (`vagrant up pidev`, 10 GB / 4 vCPU, no secrets, no runner): create, `make dev-up`, profiles, halt / destroy; appendix for running dev on pimaster |
| [sre-triage-agent.md](sre-triage-agent.md) | Read-only Claude Code triage agent in the cluster: **Triage** button on every alert, report back to ntfy. Live since 2026-11-15 (all phases); troubleshooting in runbook `OBS-006` |

Related folders:

- [runbooks/](../runbooks/README.md): step-by-step fixes, referenced by ID from alerts (for example `NET-009`).
- [postmortems/](../postmortems/): incident reports (also the 2026-04-17 Prometheus / Elasticsearch storage reduction).
