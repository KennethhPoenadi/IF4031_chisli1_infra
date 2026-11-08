#!/usr/bin/env bash
# Memasang Tester Agent persis seperti ketentuan M2: manifest pada commit yang di-pin, tanpa mengubah image.
# Sebelum memasang, memastikan manifest memang memakai digest image yang ditetapkan asisten.
#
#   ./scripts/install-tester-agent.sh            pasang
#   ./scripts/install-tester-agent.sh --check    hanya verifikasi manifest dan dry-run server
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

MANIFEST_URL="https://raw.githubusercontent.com/susTuna/if4031-tester-agent/ebb55261711123a9a211739ffbf140a275caa6da/manifest.yaml"
IMAGE_DIGEST="sha256:b3143da159cf23a8744ede12b847da6208353754234d53a5a7b46d071cf277ec"

manifest="$(mktemp)"
trap 'rm -f "$manifest"' EXIT
curl -fsSL "$MANIFEST_URL" -o "$manifest"

if ! grep -q "$IMAGE_DIGEST" "$manifest"; then
  echo "ERROR: manifest Tester Agent tidak memakai digest $IMAGE_DIGEST. Jangan dipasang." >&2
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  kubectl apply --dry-run=server -f "$manifest"
  echo "Manifest Tester Agent valid dan dapat diterapkan (dry-run server)."
  exit 0
fi

kubectl apply -f "$manifest"
kubectl -n tester-agent rollout status daemonset/tester-agent --timeout=180s
kubectl -n tester-agent get pods -o wide
