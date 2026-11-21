#!/bin/bash
#
# Base provisioning for the pimaster VM. Runs as root, safe to re-run.
# Secrets, SSH keys and kubeconfig are NOT created here: they are restored from
# a backup (homelab-docs/pimaster-vm.md), never generated.
#
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

USER_NAME="marmila"
USER_HOME="/home/${USER_NAME}"
REPO_URL="${REPO_URL:-https://github.com/marmila/picluster.git}"
SSH_PUBKEY="ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCnm/DUez8uWb1HuDMmVdQwrzfyKtnU+4bBpYWukECWWISPwF1tXJ78kj/HZcO/Fya35zJd5wRqPrmKfyuSJI0d3/wpQRi9JPkULlnCjT9LyTbzzfWZjqOFiG76VF4U77lbm80fG26ul0YqnYQXD5aIc3u+o5ehBqTsZlKEf3CzviE9eAM7cMACb/1uWJ+1KUTPNe4dPE72BLgU29RHNARHm/kVVo8BxTRtuZolcZZZX7TQbkFpxBA6SSCsdaTfGRzCtyl0E6RokVZuX0Zhh6VnXm2IWAu6jxGllJI2YdhtoTax3P+vbiJRCmK2xTWjJcoVYNo6k5nebkhbZ51kTu0l marmila@pimaster"

# Must be first: the generic/ubuntu2204 box ships DNSSEC=yes, and validation fails
# with "missing-key" since the Oct 2026 root KSK rollover, so apt cannot resolve anything.
echo "== DNS: DNSSEC off"
mkdir -p /etc/systemd/resolved.conf.d
printf '[Resolve]\nDNSSEC=no\n' > /etc/systemd/resolved.conf.d/90-dnssec-off.conf
systemctl restart systemd-resolved
for i in $(seq 1 15); do
  resolvectl query archive.ubuntu.com >/dev/null 2>&1 && break
  [ "$i" -eq 15 ] && { echo "ERROR: DNS still not resolving" >&2; resolvectl status >&2; exit 1; }
  sleep 2
done

echo "== Timezone"
timedatectl set-timezone Europe/Rome

echo "== Packages"
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg lsb-release git make jq cloud-guest-utils

echo "== Grow root disk to the virtual disk size"
# vagrant-disksize grows only the virtual disk; extend partition, PV, LV and filesystem.
pv="$(pvs --noheadings -o pv_name | head -n1 | tr -d ' ')"
if [ -n "$pv" ]; then
  disk="/dev/$(lsblk -no pkname "$pv")"
  partnum="$(cat "/sys/class/block/$(basename "$pv")/partition")"
  growpart "$disk" "$partnum" || true          # exit 1 = already full size
  pvresize "$pv"
  lvextend -r -l +100%FREE "$(findmnt -no SOURCE /)" || true   # fails only when nothing to add
fi
df -h /

echo "== IPv4 forwarding"
echo "net.ipv4.conf.all.forwarding=1" > /etc/sysctl.d/enabled_ipv4_forwarding.conf
sysctl -p /etc/sysctl.d/enabled_ipv4_forwarding.conf

echo "== User ${USER_NAME}"
# Order matters: docker group first, then the user. That gives the same IDs as
# the original VM (uid 1001, gid 1002), which ansible-runner/docker-compose.yaml
# builds the runner image with (USER_UID / USER_GID).
groupadd -f docker
if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G docker,sudo -c "Marco Milano" "${USER_NAME}"
fi
echo "${USER_NAME} ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-${USER_NAME}"
chmod 440 "/etc/sudoers.d/90-${USER_NAME}"
install -d -m 700 -o "${USER_NAME}" -g "${USER_NAME}" "${USER_HOME}/.ssh"
echo "${SSH_PUBKEY}" > "${USER_HOME}/.ssh/authorized_keys"
chown "${USER_NAME}:${USER_NAME}" "${USER_HOME}/.ssh/authorized_keys"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"
uid="$(id -u "${USER_NAME}")"; gid="$(id -g "${USER_NAME}")"
if [ "$uid" != "1001" ] || [ "$gid" != "1002" ]; then
  echo "WARNING: ${USER_NAME} is uid=${uid} gid=${gid}, the runner image expects 1001/1002." >&2
  echo "         Update USER_UID/USER_GID in ansible-runner/docker-compose.yaml or fix the IDs." >&2
fi

echo "== Docker"
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker.service containerd.service

echo "== Route to the cluster network via the gateway Pi"
cat > /etc/netplan/60-static-route.yaml <<'EOF'
network:
  version: 2
  ethernets:
    eth2:
      dhcp4: true
      routes:
        - to: 10.0.0.0/24
          via: 192.168.1.21
EOF
chmod 600 /etc/netplan/*.yaml
netplan apply
ip route | grep '^10.0.0.0/24' || echo "WARNING: route to 10.0.0.0/24 missing" >&2

echo "== Repo and ansible-runner directories"
if [ ! -d "${USER_HOME}/picluster/.git" ]; then
  sudo -u "${USER_NAME}" git clone "${REPO_URL}" "${USER_HOME}/picluster"
fi
# Same list as ansible-runner/Makefile (create-local-directories)
sudo -u "${USER_NAME}" mkdir -p \
  "${USER_HOME}/.ansible/collections" "${USER_HOME}/.ansible/roles" \
  "${USER_HOME}/.secrets" "${USER_HOME}/.kube" \
  "${USER_HOME}/.certbot/logs" "${USER_HOME}/.certbot/config" "${USER_HOME}/.certbot/work"

echo
echo "Base provisioning done."
echo "Next: restore ~/.ssh/id_rsa*, ~/.secrets, ~/.kube/config, ~/.certbot from the backup,"
echo "then run 'make ansible-runner-setup' in ~/picluster. Do NOT run it before the restore:"
echo "it would generate a new SSH key that the cluster nodes do not trust."
