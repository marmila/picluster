# Homelab docs

Documentation for changes made in this fork (marmila/picluster). The `docs/` folder is the upstream Jekyll
website and stays as upstream has it, so syncs from upstream do not conflict. Anything specific to this
homelab goes here.

| Document | What it covers |
|---|---|
| [alerting.md](alerting.md) | How alerts reach a phone (ntfy, healthchecks.io), certificate alerts, k3s upgrade alerts, node disk alerts, Terraform alerts, backup / secrets / storage / scrape-target alerts, Raspberry Pi under-voltage alerts, alerts and the OpenCode sre agent |
| [cluster-maintenance.md](cluster-maintenance.md) | Keeping the cluster updated: how Renovate works here, daily / weekly / monthly tasks, critical update order, event procedures |
| [update-automation.md](update-automation.md) | How Renovate updates get checked by CI and (step by step) merged automatically, and the alerts that watch them |
| [node-os-maintenance.md](node-os-maintenance.md) | OS package upgrades (`make os-upgrade-check`, `make os-upgrade`: drain, reboot, uncordon, Longhorn wait, one node at a time) and the manual safe reboot of a node |
| [sre-triage-agent.md](sre-triage-agent.md) | Read-only Claude Code triage agent in the cluster, started from ntfy, reports back to ntfy. Live (phases 0–3); the button in alert notifications is still to do |

Related folders:

- [runbooks/](../runbooks/README.md): step-by-step fixes, referenced by ID from alerts (for example `NET-009`).
- [postmortems/](../postmortems/): incident reports (also the 2026-04-17 Prometheus / Elasticsearch storage reduction).
