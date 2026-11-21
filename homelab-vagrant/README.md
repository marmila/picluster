# Homelab Vagrant VMs

Vagrant definitions for VMs on the Windows laptop that belong to this fork (marmila/picluster). The upstream
project has no equivalent, so this folder sits next to `homelab-docs/`.

| Folder | VM | Procedure |
|---|---|---|
| [pimaster/](pimaster/) | `pimaster`: prod control VM (ansible-runner). `vagrant up pimaster` | [homelab-docs/pimaster-vm.md](../homelab-docs/pimaster-vm.md) |
| [pimaster/](pimaster/) | `pidev`: k3d dev cluster VM, same Vagrantfile, no autostart. `vagrant up pidev` | [homelab-docs/dev-environment.md](../homelab-docs/dev-environment.md) |

Always name the machine: `vagrant destroy` / `halt` / `reload` without a name act on both VMs.
