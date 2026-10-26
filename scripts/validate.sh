# Pemeriksaan statis. Tool yang belum terpasang dilewati dengan pesan SKIP.
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
    if command -v kubeconform >/dev/null; then
      echo "==> kubeconform"
      ./scripts/render-all.sh | kubeconform -strict -ignore-missing-schemas -summary
    else echo "SKIP: kubeconform tidak terpasang"; fi
  fi
else echo "SKIP: chart belum ada"; fi

if find policies/tests -name 'kyverno-test.yaml' 2>/dev/null | grep -q .; then
  if command -v kyverno >/dev/null; then
    echo "==> kyverno test"
    kyverno test policies/tests/
  else echo "SKIP: kyverno CLI tidak terpasang"; fi
else echo "SKIP: belum ada kyverno-test.yaml"; fi

echo "Validasi selesai."
