# Homelab docs

Documentation for changes made in this fork (marmila/picluster). The `docs/` folder is the upstream Jekyll
website and stays as upstream has it, so syncs from upstream do not conflict. Anything specific to this
homelab goes here.

| Document | What it covers |
|---|---|
| [alerting.md](alerting.md) | How alerts reach a phone (ntfy, healthchecks.io), certificate alerts, alerts and the OpenCode sre agent |
| [os-upgrade.md](os-upgrade.md) | How `make os-upgrade` upgrades nodes one at a time |
| [cluster-maintenance.md](cluster-maintenance.md) | Keeping the cluster updated: how Renovate works here, daily / weekly / monthly tasks, critical update order, event procedures |

Related folders:

- [runbooks/](../runbooks/README.md): step-by-step fixes, referenced by ID from alerts (for example `NET-009`).
- [postmortems/](../postmortems/): incident reports.
