set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> sintaks bash"
for f in scripts/*.sh; do bash -n "$f"; done

if command -v terraform >/dev/null; then
  echo "==> terraform validate"
  (cd terraform && terraform init -backend=false -input=false >/dev/null && terraform validate)
else echo "SKIP: terraform tidak terpasang"; fi

if [ -f charts/microservice/Chart.yaml ]; then
  if command -v helm >/dev/null; then
    echo "==> helm lint"
    helm lint charts/microservice
    echo "==> validasi cakupan HPA"
    bash ./scripts/validate-hpa-coverage.sh
    echo "==> kontrak M2 (role, resource class, spread, storage, Tester Agent)"
    python3 ./scripts/contract-check.py
    if command -v kubeconform >/dev/null; then
      echo "==> kubeconform"
      ./scripts/render-all.sh | kubeconform -strict -ignore-missing-schemas -summary
    else echo "SKIP: kubeconform tidak terpasang"; fi
  fi
else echo "SKIP: chart belum ada"; fi

if command -v python3 >/dev/null; then
  echo "==> dashboard Grafana sinkron dengan skrip pembuatnya"
  dash_tmp="$(mktemp -d)"
  trap 'rm -rf "$dash_tmp"' EXIT
  python3 ./scripts/gen-dashboards.py "$dash_tmp" >/dev/null
  if ! diff -r "$dash_tmp" platform/observability/dashboards >/dev/null; then
    echo "ERROR: platform/observability/dashboards tidak sesuai scripts/gen-dashboards.py. Jalankan skripnya lalu commit hasilnya." >&2
    exit 1
  fi
fi

if ! find policies/kyverno -name '*.yaml' -print -quit | grep -q .; then
  echo "ERROR: policy Kyverno tidak ditemukan" >&2
  exit 1
fi
if ! find policies/tests -name 'kyverno-test.yaml' -print -quit | grep -q .; then
  echo "ERROR: kyverno-test.yaml tidak ditemukan" >&2
  exit 1
fi

echo "==> kyverno test"
if command -v kyverno >/dev/null; then
  kyverno test policies/tests/ --require-tests
elif command -v docker >/dev/null; then
  docker run --rm -v "$PWD:/work" -w /work \
    ghcr.io/kyverno/kyverno-cli:v1.19.2 \
    test policies/tests/ --require-tests
else
  echo "ERROR: kyverno CLI atau Docker wajib tersedia" >&2
  exit 1
fi

echo "Validasi selesai."
