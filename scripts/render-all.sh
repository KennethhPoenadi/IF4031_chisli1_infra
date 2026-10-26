# Render semua values dev/prod menjadi manifest (untuk kubeconform di CI).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f charts/microservice/Chart.yaml ] || exit 0
for env in dev prod; do
  for f in envs/$env/*.yaml; do
    [ -f "$f" ] || continue
    svc="$(basename "$f" .yaml)"
    helm template "$svc" charts/microservice -n "$env" -f "$f" --set image.tag=validate
    echo "---"
  done
done
