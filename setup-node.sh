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

enable_memory_cgroup() {
  if [ -f /sys/fs/cgroup/cgroup.controllers ] && grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    return
  fi

  if [ -f /proc/cgroups ] && awk '$1 == "memory" && $4 == "1" { found = 1 } END { exit(found ? 0 : 1) }' /proc/cgroups; then
    return
  fi

  cmdline_file=""
  if [ -f /boot/firmware/cmdline.txt ]; then
    cmdline_file="/boot/firmware/cmdline.txt"
  elif [ -f /boot/cmdline.txt ]; then
    cmdline_file="/boot/cmdline.txt"
  fi

  if [ -n "$cmdline_file" ] && ! grep -q "cgroup_enable=memory" "$cmdline_file"; then
    cp "$cmdline_file" "${cmdline_file}.bak"
    sed -i '1 s#$# cgroup_enable=memory cgroup_memory=1#' "$cmdline_file"
    echo "Enabled memory cgroups in ${cmdline_file}. Reboot the Pi, then rerun this script."
    exit 1
  fi

  echo "Memory cgroups are required for k3s. Add cgroup_enable=memory cgroup_memory=1 to /boot/firmware/cmdline.txt (or /boot/cmdline.txt), reboot, then rerun this script."
  exit 1
}

enable_memory_cgroup

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled

read -r -s -p "Headscale auth key: " headscale_auth_key
echo

if [ -z "$headscale_auth_key" ]; then
  echo "Headscale auth key is required."
  exit 1
fi

tailscale up --login-server=https://headscale.d-f.dev --authkey="$headscale_auth_key"

tailscale_ip="$(tailscale ip -4 | head -n1)"
if [ -z "$tailscale_ip" ]; then
  echo "Could not determine the Pi's Tailscale IPv4 address."
  exit 1
fi

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
node-ip: ${tailscale_ip}
node-external-ip: ${tailscale_ip}
flannel-iface: tailscale0
kubelet-arg:
  - node-ip=${tailscale_ip}
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

echo "Pi Tailscale and k3s agent configured with Tailscale node IPs. Both reconnect automatically on boot via tailscaled and k3s-agent."
