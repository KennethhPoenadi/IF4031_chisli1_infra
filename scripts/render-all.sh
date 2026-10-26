#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
TAG=${IMAGE_TAG:-validate}
for env in dev prod; do
  for f in envs/$env/*.yaml; do
    s=$(basename "$f" .yaml)
    echo "---"
    helm template "$s" charts/microservice -n "$env" -f "$f" --set "image.repository=validate/app" --set "image.tag=$s-$TAG"
  done
done
