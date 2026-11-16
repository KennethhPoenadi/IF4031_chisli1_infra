#!/usr/bin/env bash
set -euo pipefail

if [ "$(uname -s)" != "Linux" ]; then
  echo "ERROR: K3s agent harus dipasang pada host atau VM Linux" >&2
  exit 1
fi
if [ "${EUID:-$(id -u)}" -ne 0 ]; then
  echo "ERROR: jalankan script ini sebagai root, misalnya sudo -E ./scripts/node-join.sh" >&2
  exit 1
fi

: "${K3S_SERVER_URL:?K3S_SERVER_URL wajib diisi, misalnya https://192.168.1.20:6443}"
: "${K3S_NODE_IP:?K3S_NODE_IP wajib diisi dengan IP LAN statis node worker}"

if [ -z "${K3S_TOKEN:-}" ]; then
  if [ -t 0 ]; then
    read -r -s -p "K3s join token: " K3S_TOKEN
    echo
  else
    echo "ERROR: K3S_TOKEN wajib diisi melalui environment pada mode non-interaktif" >&2
    exit 1
  fi
fi

case "$K3S_SERVER_URL" in
  https://*:6443) ;;
  *)
    echo "ERROR: K3S_SERVER_URL harus memakai https dan port 6443" >&2
    exit 1
    ;;
esac

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
  unset K3S_TOKEN
}
trap cleanup EXIT

echo "==> Mengunduh installer resmi K3s"
curl --fail --silent --show-error --location https://get.k3s.io --output "$installer"

export INSTALL_K3S_CHANNEL="$K3S_CHANNEL"
export K3S_URL="$K3S_SERVER_URL"
export K3S_TOKEN
if [ -n "${K3S_VERSION:-}" ]; then
  export INSTALL_K3S_VERSION="$K3S_VERSION"
fi

echo "==> Menggabungkan worker $K3S_NODE_NAME ke $K3S_SERVER_URL"
sh "$installer" agent \
  --node-name "$K3S_NODE_NAME" \
  --node-ip "$K3S_NODE_IP"

systemctl is-active --quiet k3s-agent
echo "K3s agent aktif. Verifikasi dari Node A dengan: sudo k3s kubectl get nodes -o wide"
