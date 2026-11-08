# Homelab docs

Documentation for changes made in this fork (marmila/picluster). The `docs/` folder is the upstream Jekyll
website and stays as upstream has it, so syncs from upstream do not conflict. Anything specific to this
homelab goes here.

| Document | What it covers |
|---|---|
| [alerting.md](alerting.md) | How alerts reach a phone (ntfy, healthchecks.io), certificate alerts, k3s upgrade alerts, node disk alerts, Terraform alerts, alerts and the OpenCode sre agent |
| [os-upgrade.md](os-upgrade.md) | How `make os-upgrade` upgrades nodes one at a time |
| [cluster-maintenance.md](cluster-maintenance.md) | Keeping the cluster updated: how Renovate works here, daily / weekly / monthly tasks, critical update order, event procedures |
| [node-os-reboot.md](node-os-reboot.md) | Safe reboot of cluster nodes after OS upgrades (etcd quorum, Longhorn) |
| [storage-reduction-prometheus-elasticsearch.md](storage-reduction-prometheus-elasticsearch.md) | Shrinking Prometheus and Elasticsearch storage |

Related folders:

- [runbooks/](../runbooks/README.md): step-by-step fixes, referenced by ID from alerts (for example `NET-009`).
- [postmortems/](../postmortems/): incident reports.
