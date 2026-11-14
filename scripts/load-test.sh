# Menjalankan skrip k6 (milik P2) dari luar pod aplikasi, opsional sambil mengubah jumlah
# instance Aggregator sesuai rencana (P2 kriteria 6: 3 -> 5 -> 2 selama pengujian).
#
# Variabel:
#   K6_SCRIPT    path skrip k6 (misalnya ../IF4031_chisli1/tests/k6/p2-sustained.js)
#   VUS          jumlah virtual user (diteruskan sebagai env VUS ke skrip)
#   DURATION     durasi (diteruskan sebagai env DURATION, misalnya 150s)
#   BASE_URL     alamat client-facing-api, diteruskan ke skrip
#   SCALE_PLAN   (opsional) "detik:replika ..." misalnya "0:3 40:5 80:2"
#   SCALE_TARGET (opsional) HPA yang diubah, bawaan aggregator
#   MAX_ERROR_RATE  batas http_req_failed (bawaan 0.01)
#   OUT_DIR      folder bukti
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

: "${K6_SCRIPT:?K6_SCRIPT wajib}"
OUT_DIR="${OUT_DIR:-evidence/load-test-$(date -u +%Y%m%dT%H%M%SZ)}"
SCALE_TARGET="${SCALE_TARGET:-aggregator}"
MAX_ERROR_RATE="${MAX_ERROR_RATE:-0.01}"
mkdir -p "$OUT_DIR"
command -v k6 >/dev/null || { echo "ERROR: k6 tidak terpasang di runner" >&2; exit 1; }

# 10.000 VU butuh banyak file descriptor di mesin penguji.
ulimit -n 65535 2>/dev/null || echo "PERINGATAN: ulimit -n tidak dapat dinaikkan ($(ulimit -n))"

orig_min="" orig_max=""
restore() {
  if [ -n "$orig_min" ]; then
    kubectl patch hpa "$SCALE_TARGET" -n "$APP_NAMESPACE" --type merge \
      -p "{\"spec\":{\"minReplicas\":$orig_min,\"maxReplicas\":$orig_max}}" >/dev/null || true
    echo "HPA $SCALE_TARGET dikembalikan ke $orig_min..$orig_max"
  fi
}
trap restore EXIT

scaler_pid=""
if [ -n "${SCALE_PLAN:-}" ]; then
  orig_min="$(kubectl get hpa "$SCALE_TARGET" -n "$APP_NAMESPACE" -o jsonpath='{.spec.minReplicas}')"
  orig_max="$(kubectl get hpa "$SCALE_TARGET" -n "$APP_NAMESPACE" -o jsonpath='{.spec.maxReplicas}')"
  (
    t0=$(date +%s)
    for step in $SCALE_PLAN; do
      at="${step%%:*}" n="${step##*:}"
      while [ $(( $(date +%s) - t0 )) -lt "$at" ]; do sleep 1; done
      kubectl patch hpa "$SCALE_TARGET" -n "$APP_NAMESPACE" --type merge \
        -p "{\"spec\":{\"minReplicas\":$n,\"maxReplicas\":$n}}" >/dev/null
      echo "$(date -u +%FT%TZ) $SCALE_TARGET -> $n replika" | tee -a "$OUT_DIR/scale-timeline.txt"
    done
  ) &
  scaler_pid=$!
  ( while sleep 5; do
      printf '%s ' "$(date -u +%FT%TZ)"
      kubectl get deploy "$SCALE_TARGET" -n "$APP_NAMESPACE" --no-headers 2>/dev/null | awk '{print "ready="$2}'
    done ) > "$OUT_DIR/replicas.txt" 2>&1 &
  watcher_pid=$!
fi

echo "==> k6 $K6_SCRIPT VUS=${VUS:-} DURATION=${DURATION:-}"
code=0
VUS="${VUS:-}" DURATION="${DURATION:-}" BASE_URL="${BASE_URL:-}" \
  AUTH_BASE_URL="${AUTH_BASE_URL:-http://auth.prod.localtest.me}" \
  FIELD_CLIENT_ID="${FIELD_CLIENT_ID:-${AUTH_CLIENT_FIELD_ID:-}}" \
  FIELD_CLIENT_SECRET="${FIELD_CLIENT_SECRET:-${AUTH_CLIENT_FIELD_SECRET:-}}" \
  MEDIA_CLIENT_ID="${MEDIA_CLIENT_ID:-${AUTH_CLIENT_MEDIA_ID:-}}" \
  MEDIA_CLIENT_SECRET="${MEDIA_CLIENT_SECRET:-${AUTH_CLIENT_MEDIA_SECRET:-}}" \
  k6 run --summary-export "$OUT_DIR/k6-summary.json" "$K6_SCRIPT" 2>&1 | tee "$OUT_DIR/k6.log" || code=$?

[ -n "$scaler_pid" ] && wait "$scaler_pid" 2>/dev/null || true
[ -n "${watcher_pid:-}" ] && kill "$watcher_pid" 2>/dev/null || true

rate="$(grep -o '"http_req_failed":{[^}]*"value":[0-9.e-]*' "$OUT_DIR/k6-summary.json" | grep -o '[0-9.e-]*$' || true)"
echo "http_req_failed = ${rate:-tidak diketahui} (batas $MAX_ERROR_RATE)" | tee "$OUT_DIR/result.txt"
if [ -n "$rate" ] && awk -v r="$rate" -v m="$MAX_ERROR_RATE" 'BEGIN{exit !(r>=m)}'; then
  echo "GAGAL: error rate melebihi batas" | tee -a "$OUT_DIR/result.txt"
  code=1
fi
echo "Bukti load test di $OUT_DIR"
exit "$code"
