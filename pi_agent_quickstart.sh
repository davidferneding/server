#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

if ! command -v apt-get >/dev/null 2>&1; then
  echo "This script currently supports Debian-based Raspberry Pi OS."
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y curl ca-certificates
update-ca-certificates

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

read -r -s -p "Headscale auth key: " headscale_auth_key
echo

if [ -z "$headscale_auth_key" ]; then
  echo "Headscale auth key is required."
  exit 1
fi

tailscale up --login-server=https://headscale.d-f.dev --authkey="$headscale_auth_key"

read -r -p "k3s server Tailscale IP or DNS name: " k3s_server
echo

if [ -z "$k3s_server" ]; then
  echo "k3s server Tailscale IP or DNS name is required."
  exit 1
fi

read -r -s -p "k3s token: " token
echo

if [ -z "$token" ]; then
  echo "Token is required."
  exit 1
fi

install -d -m 0755 /etc/rancher/k3s

cat >/etc/rancher/k3s/config.yaml <<EOF
server: https://${k3s_server}:6443
token: ${token}
node-label:
  - server.d-f.dev/node-role=pi
node-taint:
  - server.d-f.dev/node-role=pi:NoSchedule
EOF

chmod 0600 /etc/rancher/k3s/config.yaml

curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -
systemctl enable k3s-agent
systemctl restart k3s-agent
systemctl is-active --quiet k3s-agent

echo "Pi Tailscale and k3s agent configured. Both reconnect automatically on boot via tailscaled and k3s-agent."
