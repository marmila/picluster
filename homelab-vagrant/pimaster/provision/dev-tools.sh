#!/bin/bash
#
# Tools and kernel settings for the k3d dev cluster (homelab-docs/dev-environment.md).
# Runs as root, safe to re-run. Only on request:
#   vagrant provision --provision-with dev-tools
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

KUBECTL_VERSION="${KUBECTL_VERSION:-v1.37.2}"   # keep in line with .mise.toml

echo "== Kernel modules for Cilium"
cat > /etc/modules-load.d/cilium-dev.conf <<'EOF'
iptable_filter
ip_tables
iptable_mangle
iptable_raw
iptable_nat
xt_socket
EOF
systemctl restart systemd-modules-load

echo "== sysctls for k3d"
cat > /etc/sysctl.d/90-k3d-dev.conf <<'EOF'
net.core.devconf_inherit_init_net=1
net.netfilter.nf_conntrack_max=196608
net.ipv4.conf.all.forwarding=1
EOF
sysctl --system >/dev/null

echo "== k3d"
command -v k3d >/dev/null || curl -fsSL https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

echo "== kubectl ${KUBECTL_VERSION}"
if ! kubectl version --client 2>/dev/null | grep -q "${KUBECTL_VERSION}"; then
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi

echo "== helm 4"
command -v helm >/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4 | bash

echo "== tmpl (needs a recent Go; the apt package is too old)"
# dev/create_cluster.sh calls `tmpl -data=@file.json x.tmpl`: that is benbjohnson/tmpl.
# Other tools named tmpl (e.g. krakozaure/tmpl) have no -data flag: replace them.
if ! tmpl -h 2>&1 | grep -q -- '-data'; then
  snap list go >/dev/null 2>&1 || snap install go --classic
  rm -f /usr/local/bin/tmpl
  GOBIN=/usr/local/bin /snap/bin/go install github.com/benbjohnson/tmpl@latest
fi

echo "== flux CLI"
command -v flux >/dev/null || curl -fsSL https://fluxcd.io/install.sh | bash

echo
for c in docker k3d kubectl helm tmpl flux; do printf '%-8s ' "$c"; command -v "$c" || echo MISSING; done
echo "Dev tools ready. Next: homelab-docs/dev-environment.md, section 5."
