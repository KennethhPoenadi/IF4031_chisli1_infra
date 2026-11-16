# Game day: menjalankan beberapa skenario Tester Agent berurutan di bawah beban, tanpa
# intervensi selama jendela pemulihan, lalu mengumpulkan bukti (P5 kriteria 6-8).
#
# Variabel:
#   SCENARIOS         daftar skenario, dipisah spasi (bawaan: semua skenario latihan)
#   RECOVERY_SECONDS  jendela pemulihan per skenario tanpa intervensi (bawaan 180)
#   AUDIT_URL         alamat Aggregator untuk Audit API, misalnya http://ops.prod.localtest.me
#   AUDIT_TOKEN       token Audit API
#   K6_SCRIPT         (opsional) skrip k6 yang dijalankan di latar belakang selama game day
#   PROM_URL          (opsional) alamat Prometheus untuk membaca SLO jalur peringatan
#   OUT_DIR           folder bukti (bawaan evidence/game-day-<waktu>)
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

SCENARIOS="${SCENARIOS:-kill-store wipe-node clock-skew partition kill-leader schema}"
RECOVERY_SECONDS="${RECOVERY_SECONDS:-180}"
OUT_DIR="${OUT_DIR:-evidence/game-day-$(date -u +%Y%m%dT%H%M%SZ)}"
SOURCES="BMKG PVMBG SATELIT SENSOR_PANTAI"
mkdir -p "$OUT_DIR"
summary="$OUT_DIR/summary.md"

audit() { # audit <path>
  curl -fsS --max-time 30 -H "Authorization: Bearer ${AUDIT_TOKEN:?AUDIT_TOKEN wajib}" "${AUDIT_URL:?AUDIT_URL wajib}$1"
}

checksums() { # checksums <label>
  for s in $SOURCES; do
    printf '%s %s ' "$1" "$s"
    audit "/internal/audit/checksum?source=$s" || echo '{"error":"tidak terjangkau"}'
    echo
  done >> "$OUT_DIR/checksums.txt"
}

snapshot() { # snapshot <label>
  kubectl get pods -n "$APP_NAMESPACE" -o wide > "$OUT_DIR/pods-$1.txt" 2>&1 || true
  kubectl get nodes -o wide > "$OUT_DIR/nodes-$1.txt" 2>&1 || true
  kubectl get hpa,scaledobject -n "$APP_NAMESPACE" > "$OUT_DIR/autoscaling-$1.txt" 2>&1 || true
}

{
  echo "# Game day $(date -u +%FT%TZ)"
  echo
  echo "- Skenario: $SCENARIOS"
  echo "- Jendela pemulihan: ${RECOVERY_SECONDS}s per skenario, tanpa intervensi"
  echo
  echo "| Skenario | Mulai (UTC) | Selesai (UTC) | Exit Tester | Pod tidak Ready setelah pemulihan |"
  echo "| --- | --- | --- | --- | --- |"
} > "$summary"

checksums sebelum
snapshot sebelum
audit "/internal/audit/unprocessed?limit=1000" > "$OUT_DIR/unprocessed-sebelum.json" 2>/dev/null || true

k6_pid=""
if [ -n "${K6_SCRIPT:-}" ]; then
  echo "==> Beban latar: $K6_SCRIPT"
  k6 run --summary-export "$OUT_DIR/k6-summary.json" "$K6_SCRIPT" > "$OUT_DIR/k6.log" 2>&1 &
  k6_pid=$!
fi

for sc in $SCENARIOS; do
  start="$(date -u +%FT%TZ)"
  echo "==> Skenario $sc ($start)"
  code=0
  kubectl exec -n tester-agent daemonset/tester-agent -- /app run practice "$sc" \
    > "$OUT_DIR/scenario-$sc.txt" 2>&1 || code=$?
  echo "    menunggu ${RECOVERY_SECONDS}s tanpa intervensi"
  sleep "$RECOVERY_SECONDS"
  end="$(date -u +%FT%TZ)"
  snapshot "$sc"
  notready="$(kubectl get pods -n "$APP_NAMESPACE" --no-headers 2>/dev/null | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print $1}' | tr '\n' ' ')"
  echo "| $sc | $start | $end | $code | ${notready:-tidak ada} |" >> "$summary"
done

if [ -n "$k6_pid" ]; then
  echo "==> Menunggu beban latar selesai"
  wait "$k6_pid" || echo "k6 keluar dengan status $?" >> "$summary"
fi

checksums sesudah
snapshot sesudah
audit "/internal/audit/unprocessed?limit=1000" > "$OUT_DIR/unprocessed-sesudah.json" 2>/dev/null || true
kubectl logs -n tester-agent daemonset/tester-agent --all-containers --since=6h > "$OUT_DIR/tester-logs.txt" 2>&1 || true
kubectl get events -n "$APP_NAMESPACE" --sort-by=.lastTimestamp > "$OUT_DIR/events.txt" 2>&1 || true

{
  echo
  echo "## Checksum Audit API (count tidak boleh turun, partial harus false setelah pulih)"
  echo
  echo '```'
  cat "$OUT_DIR/checksums.txt"
  echo '```'
} >> "$summary"

if [ -n "${PROM_URL:-}" ]; then
  q='slo:alert_path_within_5s:ratio_rate5m'
  curl -fsS --max-time 15 --get "$PROM_URL/api/v1/query" --data-urlencode "query=$q" > "$OUT_DIR/slo.json" 2>/dev/null || true
  q2='1 - avg_over_time(slo:alert_path_within_5s:ratio_rate5m[6h])'
  curl -fsS --max-time 15 --get "$PROM_URL/api/v1/query" --data-urlencode "query=$q2" > "$OUT_DIR/error-budget-used.json" 2>/dev/null || true
  echo "- SLO jalur peringatan: lihat slo.json dan error-budget-used.json" >> "$summary"
fi

# Penurunan count antar checksum berarti ada HazardEvent yang hilang.
lost=0
for s in $SOURCES; do
  b="$(grep "^sebelum $s " "$OUT_DIR/checksums.txt" | grep -o '"count":[0-9]*' | cut -d: -f2 || true)"
  a="$(grep "^sesudah $s " "$OUT_DIR/checksums.txt" | grep -o '"count":[0-9]*' | cut -d: -f2 || true)"
  if [ -n "$b" ] && [ -n "$a" ] && [ "$a" -lt "$b" ]; then
    echo "- PERINGATAN: count $s turun dari $b ke $a" >> "$summary"
    lost=1
  fi
done
cat "$summary"
echo "Bukti game day di $OUT_DIR"
exit "$lost"
