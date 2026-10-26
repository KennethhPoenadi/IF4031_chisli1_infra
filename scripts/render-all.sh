#!/usr/bin/env bash
# Render semua workload (dev + prod) ke stdout, untuk divalidasi CI: ./scripts/render-all.sh | kubeconform -strict -summary
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${IMAGE_TAG:-validate}
for env in dev prod; do
  for f in envs/$env/*.yaml; do
    s=$(basename "$f" .yaml)
    echo "---"
    helm template "$s" charts/microservice -n "$env" -f "$f" --set "image.tag=$s-$TAG"
  done
done
