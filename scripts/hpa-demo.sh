#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

NS="${1:-dev}"
OUT="${OUT_DIR:-hpa-evidence/$NS-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"

: "${CLIENT_ID:?CLIENT_ID kosong (isi dengan nilai AUTH_CLIENT_MEDIA_ID)}"
: "${CLIENT_SECRET:?CLIENT_SECRET kosong (isi dengan nilai AUTH_CLIENT_MEDIA_SECRET)}"
command -v k6 >/dev/null || { echo "ERROR: k6 belum terpasang (brew install k6)" >&2; exit 1; }

export API_URL="${API_URL:-http://api.$NS.localtest.me}"
export AUTH_URL="${AUTH_URL:-http://auth.$NS.localtest.me}"

kubectl get hpa -n "$NS" > "$OUT/hpa-sebelum.txt"
kubectl get pods -n "$NS" > "$OUT/pods-sebelum.txt"

( while true; do
    echo "== $(date +%H:%M:%S)"
    kubectl get hpa client-facing-api -n "$NS" --no-headers
    kubectl top pods -n "$NS" -l app.kubernetes.io/name=client-facing-api --no-headers 2>/dev/null || true
    sleep 10
  done ) > "$OUT/hpa-timeline.txt" 2>&1 &
WATCH=$!
trap 'kill $WATCH 2>/dev/null || true' EXIT

k6 run tests/k6/hpa.js | tee "$OUT/k6-ringkasan.txt"

sleep 15
kill $WATCH 2>/dev/null || true
kubectl get hpa -n "$NS" > "$OUT/hpa-sesudah.txt"
kubectl get pods -n "$NS" -l app.kubernetes.io/name=client-facing-api > "$OUT/pods-sesudah.txt"
kubectl describe hpa client-facing-api -n "$NS" > "$OUT/hpa-describe.txt"

echo "Bukti tersimpan di $OUT"
