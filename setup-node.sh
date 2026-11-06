#!/bin/bash
# Sets up a Raspberry Pi OS or Ubuntu Server node as a k3s agent on the home
# Tailscale network (Headscale). Re-runnable. If a reboot is needed (memory
# cgroups on a Pi), the script saves its inputs, reboots, and finishes itself
# on boot through a systemd unit.
#
# First run (over SSH):
#   sudo NODE_ROLE=pi K3S_TOKEN=<token> HEADSCALE_AUTH_KEY=<key> ./setup-node.sh
#
# Optional variables:
#   K3S_SERVER                    k3s server address (default: 100.64.0.1)
#   NODE_BLUETOOTH                1 to install BlueZ, 0 to skip (default: auto-detect)
#   DISABLE_CONTAINERD_APPARMOR   1 to disable AppArmor for containerd, 0 to skip
#                                 (default: 1 when AppArmor is enabled)
#
# Missing values are prompted for when running interactively.

set -euo pipefail

HEADSCALE_URL="https://headscale.d-f.dev"
K3S_SERVER="${K3S_SERVER:-100.64.0.1}"
INSTALLED_SCRIPT="/usr/local/sbin/setup-node.sh"
ENV_FILE="/etc/setup-node/env"
RESUME_UNIT="setup-node-resume.service"
RESUME_UNIT_PATH="/etc/systemd/system/${RESUME_UNIT}"
K3S_CONFIG="/etc/rancher/k3s/config.yaml"
CONTAINERD_DIR="/var/lib/rancher/k3s/agent/etc/containerd"

log() { echo "[setup-node] $*"; }
die() { echo "[setup-node] ERROR: $*" >&2; exit 1; }

require_root() {
  [ "${EUID}" -eq 0 ] || die "run as root (sudo)."
}

detect_os() {
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    ubuntu|raspbian|debian) ;;
    *) die "unsupported OS '${ID:-unknown}'. Supported: Ubuntu Server, Raspberry Pi OS." ;;
  esac
  command -v apt-get >/dev/null 2>&1 || die "apt-get is required."
  log "OS: ${PRETTY_NAME:-$ID}"
}

load_saved_inputs() {
  if [ -f "$ENV_FILE" ]; then
    log "Resuming after reboot with saved inputs."
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
  fi
}

prompt_if_missing() {
  local name="$1" prompt="$2" secret="${3:-0}" value=""
  if [ -n "${!name:-}" ]; then
    return
  fi
  if [ ! -t 0 ]; then
    die "$name is required (set it as an environment variable)."
  fi
  if [ "$secret" = "1" ]; then
    read -r -s -p "$prompt" value
    echo
  else
    read -r -p "$prompt" value
  fi
  [ -n "$value" ] || die "$name is required."
  printf -v "$name" '%s' "$value"
  export "${name?}"
}

tailscale_ip() {
  command -v tailscale >/dev/null 2>&1 || return 0
  tailscale ip -4 2>/dev/null | head -n1 || true
}

tailscale_joined() {
  [ -n "$(tailscale_ip)" ]
}

validate_inputs() {
  case "${NODE_ROLE}" in
    pi|home) ;;
    *) die "NODE_ROLE must be 'pi' or 'home' (got '${NODE_ROLE}')." ;;
  esac
  if [ -z "${NODE_BLUETOOTH:-}" ]; then
    if [ -n "$(ls /sys/class/bluetooth 2>/dev/null || true)" ]; then
      NODE_BLUETOOTH=1
    else
      NODE_BLUETOOTH=0
    fi
  fi
  if [ -z "${DISABLE_CONTAINERD_APPARMOR:-}" ]; then
    if command -v aa-enabled >/dev/null 2>&1 && [ "$(aa-enabled 2>/dev/null || true)" = "Yes" ]; then
      DISABLE_CONTAINERD_APPARMOR=1
    else
      DISABLE_CONTAINERD_APPARMOR=0
    fi
  fi
  export NODE_BLUETOOTH DISABLE_CONTAINERD_APPARMOR K3S_SERVER
}

save_inputs() {
  install -d -m 0700 /etc/setup-node
  (
    umask 077
    {
      printf 'NODE_ROLE=%q\n' "$NODE_ROLE"
      printf 'K3S_TOKEN=%q\n' "$K3S_TOKEN"
      printf 'K3S_SERVER=%q\n' "$K3S_SERVER"
      printf 'NODE_BLUETOOTH=%q\n' "$NODE_BLUETOOTH"
      printf 'DISABLE_CONTAINERD_APPARMOR=%q\n' "$DISABLE_CONTAINERD_APPARMOR"
      printf 'HEADSCALE_AUTH_KEY=%q\n' "${HEADSCALE_AUTH_KEY:-}"
    } >"$ENV_FILE"
  )
}

install_resume_unit() {
  if [ "$(readlink -f "$0")" != "$INSTALLED_SCRIPT" ]; then
    install -m 0755 "$0" "$INSTALLED_SCRIPT"
  fi
  cat >"$RESUME_UNIT_PATH" <<EOF
[Unit]
Description=Finish node setup after reboot
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=${ENV_FILE}
ExecStart=${INSTALLED_SCRIPT}

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$RESUME_UNIT" >/dev/null
}

finish_resume() {
  if systemctl is-enabled --quiet "$RESUME_UNIT" 2>/dev/null; then
    systemctl disable "$RESUME_UNIT" >/dev/null
  fi
  rm -f "$RESUME_UNIT_PATH" "$ENV_FILE"
  systemctl daemon-reload
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "Installing base packages..."
  apt-get update
  apt-get install -y curl ca-certificates
  if [ "$NODE_BLUETOOTH" = "1" ]; then
    log "Installing BlueZ..."
    apt-get install -y bluez
    systemctl enable --now bluetooth
  fi
}

ensure_memory_cgroup() {
  if [ -f /sys/fs/cgroup/cgroup.controllers ] && grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
    return
  fi
  if [ -f /proc/cgroups ] && awk '$1 == "memory" && $4 == "1" { found = 1 } END { exit(found ? 0 : 1) }' /proc/cgroups; then
    return
  fi

  local cmdline_file=""
  if [ -f /boot/firmware/cmdline.txt ]; then
    cmdline_file="/boot/firmware/cmdline.txt"
  elif [ -f /boot/cmdline.txt ]; then
    cmdline_file="/boot/cmdline.txt"
  fi
  [ -n "$cmdline_file" ] || die "memory cgroups are disabled and no cmdline.txt was found."
  if grep -q "cgroup_enable=memory" "$cmdline_file"; then
    die "$cmdline_file already sets cgroup_enable=memory, but memory cgroups are still inactive. Check the boot config manually."
  fi

  log "Enabling memory cgroups in ${cmdline_file} and rebooting..."
  cp "$cmdline_file" "${cmdline_file}.bak"
  sed -i '1 s#$# cgroup_enable=memory cgroup_memory=1#' "$cmdline_file"
  save_inputs
  install_resume_unit
  systemctl reboot
  exit 0
}

setup_tailscale() {
  if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  systemctl enable --now tailscaled

  if tailscale_joined; then
    log "Tailscale already joined: $(tailscale_ip)"
    return
  fi

  [ -n "${HEADSCALE_AUTH_KEY:-}" ] || die "HEADSCALE_AUTH_KEY is required to join the tailnet."
  log "Joining the tailnet at ${HEADSCALE_URL}..."
  tailscale up --login-server="$HEADSCALE_URL" --authkey="$HEADSCALE_AUTH_KEY"

  for _ in $(seq 1 30); do
    tailscale_joined && break
    sleep 2
  done
  tailscale_joined || die "Tailscale did not come up."
  log "Tailscale IP: $(tailscale_ip)"
}

write_k3s_config() {
  local ip taint_value
  ip="$(tailscale_ip)"
  [ -n "$ip" ] || die "no Tailscale IPv4 address."
  taint_value="server.d-f.dev/node-role=${NODE_ROLE}:NoSchedule"

  install -d -m 0755 /etc/rancher/k3s
  (
    umask 077
    cat >"$K3S_CONFIG" <<EOF
server: https://${K3S_SERVER}:6443
token: ${K3S_TOKEN}
node-ip: ${ip}
node-external-ip: ${ip}
flannel-iface: tailscale0
kubelet-arg:
  - node-ip=${ip}
node-label:
  - server.d-f.dev/node-role=${NODE_ROLE}
node-taint:
  - ${taint_value}
EOF
  )
}

install_k3s_agent() {
  write_k3s_config
  if [ ! -x /usr/local/bin/k3s ]; then
    log "Installing k3s agent..."
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="agent" sh -
  fi
  systemctl enable k3s-agent
  systemctl restart k3s-agent
  systemctl is-active --quiet k3s-agent || die "k3s-agent is not running. Check: journalctl -u k3s-agent"
}

disable_containerd_apparmor() {
  if [ "$DISABLE_CONTAINERD_APPARMOR" != "1" ]; then
    return
  fi

  local cfg="${CONTAINERD_DIR}/config.toml" tmpl="${CONTAINERD_DIR}/config-v3.toml.tmpl"
  log "Waiting for k3s to generate the containerd config..."
  for _ in $(seq 1 60); do
    [ -f "$cfg" ] && break
    sleep 2
  done
  [ -f "$cfg" ] || die "containerd config was not generated at ${cfg}."

  if [ ! -f "$tmpl" ]; then
    log "Disabling AppArmor for containerd (Ubuntu kernel regression workaround)..."
    cp "$cfg" "$tmpl"
    sed -i "/^\[plugins\.'io\.containerd\.cri\.v1\.runtime'\]/a\  disable_apparmor = true" "$tmpl"
    grep -q "disable_apparmor = true" "$tmpl" || die "could not add disable_apparmor to ${tmpl}."
    systemctl restart k3s-agent
    systemctl is-active --quiet k3s-agent || die "k3s-agent did not restart after the containerd change."
  fi
}

main() {
  require_root
  detect_os
  load_saved_inputs

  prompt_if_missing NODE_ROLE "Node role (pi or home): "
  prompt_if_missing K3S_TOKEN "k3s token: " 1
  if ! tailscale_joined; then
    prompt_if_missing HEADSCALE_AUTH_KEY "Headscale auth key: " 1
  fi
  validate_inputs

  install_packages
  ensure_memory_cgroup
  setup_tailscale
  install_k3s_agent
  disable_containerd_apparmor

  finish_resume
  log "Done. Node role: ${NODE_ROLE}, Tailscale IP: $(tailscale_ip)."
  log "Check the node from the cluster with: kubectl get nodes"
}

main "$@"
