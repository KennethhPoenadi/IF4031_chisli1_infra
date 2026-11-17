#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "ERROR: K3s server harus dipasang pada host atau VM Linux" >&2
  exit 1
fi
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: jalankan script ini sebagai root, misalnya sudo -E ./scripts/up.sh" >&2
  exit 1
fi

: "${K3S_NODE_IP:?K3S_NODE_IP wajib diisi dengan IP LAN statis Node A}"

K3S_NODE_NAME="${K3S_NODE_NAME:-$(hostname -s)}"
K3S_CHANNEL="${K3S_CHANNEL:-stable}"

command -v curl >/dev/null || {
  echo "ERROR: curl tidak terpasang" >&2
  exit 1
}
command -v systemctl >/dev/null || {
  echo "ERROR: systemd diperlukan untuk menjalankan K3s" >&2
  exit 1
}
command -v ip >/dev/null || {
  echo "ERROR: iproute2 diperlukan untuk memeriksa alamat node" >&2
  exit 1
}

if ! ip -o -4 addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$K3S_NODE_IP"; then
  echo "ERROR: K3S_NODE_IP=$K3S_NODE_IP tidak ditemukan pada interface host ini" >&2
  exit 1
fi

installer="$(mktemp)"
cleanup() {
  rm -f "$installer"
}
trap cleanup EXIT

echo "==> Mengunduh installer resmi K3s"
curl --fail --silent --show-error --location https://get.k3s.io --output "$installer"

install_env=(INSTALL_K3S_CHANNEL="$K3S_CHANNEL")
if [ -n "${K3S_VERSION:-}" ]; then
  install_env+=(INSTALL_K3S_VERSION="$K3S_VERSION")
fi

echo "==> Memasang K3s server $K3S_NODE_NAME pada $K3S_NODE_IP"
env "${install_env[@]}" sh "$installer" server \
  --node-name "$K3S_NODE_NAME" \
  --node-ip "$K3S_NODE_IP" \
  --advertise-address "$K3S_NODE_IP" \
  --tls-san "$K3S_NODE_IP" \
  --flannel-backend vxlan \
  --disable traefik \
  --disable servicelb \
  --disable metrics-server \
  --node-label ingress-ready=true \
  --write-kubeconfig-mode 640

systemctl is-active --quiet k3s
k3s kubectl wait --for=condition=Ready "node/$K3S_NODE_NAME" --timeout=180s

echo "==> K3s server siap"
k3s --version
k3s kubectl get nodes -o wide
echo "Token join tersimpan di /var/lib/rancher/k3s/server/node-token"
echo "Kubeconfig tersimpan di /etc/rancher/k3s/k3s.yaml"
