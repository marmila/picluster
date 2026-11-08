# OS upgrades (`make os-upgrade`)

Additions to the upstream [Ansible instructions](../docs/_docs/ansible-instructions.md) for how `make os-upgrade`
(playbook `ansible/update.yml`) runs in this homelab.

How it runs:

- It targets only the `picluster` group (all Raspberry Pi and x86 cluster nodes).
- Nodes are processed one at a time (`serial: 1`): each node is upgraded and, if needed, rebooted before the next one starts. This avoids rebooting several K3s masters or workers at the same time, which can make the cluster unavailable.
- If any node fails, the run stops (`max_fail_percentage: 0`), so a broken node is not followed by more reboots. Fix the node and run `make os-upgrade` again; already-upgraded nodes are quick to process.

> [!NOTE]
>
> The `pimaster` host in the inventory is the ansible-runner container itself (`ansible_connection: local`), not a real machine, so it is not upgraded by this playbook. The container's packages are refreshed only when its image is rebuilt.
>
> The VM/host where the ansible-runner container runs is not in the inventory either. Keep it updated on its own, for example with `unattended-upgrades`. Do not reboot it while a playbook is running, because that stops the container and the run.

