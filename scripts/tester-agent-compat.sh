# Memastikan cluster memenuhi kontrak lingkungan Tester Agent (Ketentuan Implementasi M2):
#   - manifest Tester Agent dapat dipasang tanpa diubah (digest image di-pin),
#   - setiap pod aplikasi berlabel role yang sah,
#   - tidak ada NetworkPolicy, ResourceQuota, atau LimitRange yang menghalangi Tester Agent,
#   - (bila terpasang) daftar skenario dapat dibaca, dan opsional satu skenario latihan dijalankan.
#
# Pemakaian: OUT_DIR=evidence/tester ./scripts/tester-agent-compat.sh
#            RUN_PRACTICE=schema ./scripts/tester-agent-compat.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

OUT_DIR="${OUT_DIR:-evidence/tester-agent-compat}"
mkdir -p "$OUT_DIR"
ROLES="aggregator store broker consumer api mock sensor other"
fail=0

echo "==> Manifest Tester Agent (dry-run server, digest di-pin)"
./scripts/install-tester-agent.sh --check | tee "$OUT_DIR/manifest-check.txt"

echo "==> Label role pada setiap pod di $APP_NAMESPACE"
kubectl get pods -n "$APP_NAMESPACE" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.labels.role}{"\t"}{.spec.nodeName}{"\n"}{end}' \
  | tee "$OUT_DIR/pod-roles.tsv"
while IFS=$'\t' read -r pod role node; do
  [ -z "$pod" ] && continue
  if ! grep -qw -- "$role" <<<"$ROLES" || [ -z "$role" ]; then
    echo "GAGAL: pod $pod berlabel role '$role'" >&2
    fail=1
  fi
done < "$OUT_DIR/pod-roles.tsv"

echo "==> Tidak ada pembatas di namespace tester-agent"
for kind in networkpolicy resourcequota limitrange; do
  n="$(kubectl get "$kind" -n tester-agent --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  echo "$kind: $n" | tee -a "$OUT_DIR/tester-namespace.txt"
  if [ "$n" != "0" ]; then
    echo "GAGAL: $kind ada di namespace tester-agent" >&2
    fail=1
  fi
done

echo "==> Policy Kyverno tidak mencakup namespace tester-agent"
if kubectl get clusterpolicy -o yaml 2>/dev/null | grep -q 'tester-agent'; then
  echo "GAGAL: ada ClusterPolicy yang menyebut tester-agent" >&2
  fail=1
fi

if kubectl get daemonset tester-agent -n tester-agent >/dev/null 2>&1; then
  echo "==> Tester Agent terpasang"
  kubectl get pods -n tester-agent -o wide | tee "$OUT_DIR/tester-pods.txt"
  desired="$(kubectl get ds tester-agent -n tester-agent -o jsonpath='{.status.desiredNumberScheduled}')"
  ready="$(kubectl get ds tester-agent -n tester-agent -o jsonpath='{.status.numberReady}')"
  if [ "$desired" != "$ready" ]; then
    echo "GAGAL: Tester Agent siap $ready dari $desired node" >&2
    fail=1
  fi
  kubectl exec -n tester-agent daemonset/tester-agent -- /app list | tee "$OUT_DIR/scenarios.txt"
  if [ -n "${RUN_PRACTICE:-}" ]; then
    echo "==> Skenario latihan: $RUN_PRACTICE"
    kubectl exec -n tester-agent daemonset/tester-agent -- /app run practice "$RUN_PRACTICE" \
      | tee "$OUT_DIR/practice-$RUN_PRACTICE.txt" || fail=1
    kubectl logs -n tester-agent daemonset/tester-agent --since=15m --all-containers \
      > "$OUT_DIR/tester-logs.txt" 2>&1 || true
  fi
else
  echo "Tester Agent belum terpasang: jalankan ./scripts/install-tester-agent.sh"
fi

if [ "$fail" -ne 0 ]; then
  echo "Kontrak Tester Agent TIDAK terpenuhi. Lihat $OUT_DIR" >&2
  exit 1
fi
echo "Kontrak Tester Agent terpenuhi. Bukti di $OUT_DIR"
