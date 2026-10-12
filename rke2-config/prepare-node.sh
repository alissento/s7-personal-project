#!/usr/bin/env bash
# Prepares an Ubuntu 26.04 VM for RKE2 and installs RKE2 — but does not start it.
#
# Usage:  sudo ./prepare-node.sh server   # on hl-master-0X
#         sudo ./prepare-node.sh agent    # on hl-worker-0X
#
# Override the version with RKE2_VERSION=... (current stable: https://update.rke2.io/v1-release/channels/stable).
set -euo pipefail

ROLE="${1:-}"
RKE2_VERSION="${RKE2_VERSION:-v1.36.5+rke2r1}"   # stable channel, checked 2026-10-12

if [[ "$ROLE" != "server" && "$ROLE" != "agent" ]]; then
  echo "usage: sudo $0 server|agent" >&2
  exit 1
fi
if [[ $EUID -ne 0 ]]; then
  echo "run as root (sudo $0 $ROLE)" >&2
  exit 1
fi

echo ">> Disabling swap (kubelet requirement)"
swapoff -a
sed -i -E '/^[^#].*[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab

echo ">> Installing base packages"
apt-get update -q
apt-get install -y -q curl qemu-guest-agent
systemctl enable --now qemu-guest-agent

if [[ "$ROLE" == "server" ]] && ! id etcd &>/dev/null; then
  echo ">> Creating etcd user (required by the CIS profile)"
  useradd -r -c "etcd user" -s /sbin/nologin -M etcd -U
fi

echo ">> Installing RKE2 $RKE2_VERSION ($ROLE)"
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION="$RKE2_VERSION" INSTALL_RKE2_TYPE="$ROLE" sh -

echo ">> Applying kernel parameters"
# CIS profile: kubelet refuses to start unless these match its expected defaults.
cp -f /usr/local/share/rke2/rke2-cis-sysctl.conf /etc/sysctl.d/60-rke2-cis.conf
# Ubuntu's inotify limits run out quickly with many pods (log shippers, controllers).
cat > /etc/sysctl.d/61-k8s-inotify.conf <<'EOF'
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 524288
EOF
systemctl restart systemd-sysctl

mkdir -p /etc/rancher/rke2/config.yaml.d
if [[ "$ROLE" == "server" ]]; then
  mkdir -p /var/lib/rancher/rke2/server/manifests
fi

echo ">> Checks"
if [[ "$(timedatectl show -p NTPSynchronized --value)" != "yes" ]]; then
  echo "!! Clock is not NTP-synchronised — etcd and TLS certificates need correct time" >&2
fi
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
  echo "!! ufw is active — open the ports in docs/network-plan.md or disable it" >&2
fi
echo "   hostname: $(hostname)  (must be unique in the cluster)"

echo ">> Done. Next: copy config and token files (rke2-config/README.md), then: systemctl enable --now rke2-$ROLE"
