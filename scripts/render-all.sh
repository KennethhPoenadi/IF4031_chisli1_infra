#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh
TAG=${IMAGE_TAG:-validate}
for env in dev prod; do
  for f in envs/$env/*.yaml; do
    s=$(basename "$f" .yaml)
    echo "---"
    if [ "$s" = sensor-pantai ]; then
      helm template "$s" charts/microservice -n "$(ns_for "$env")" -f "$f"
    else
      helm template "$s" charts/microservice -n "$(ns_for "$env")" -f "$f" --set "image.repository=validate/app" --set "image.tag=$s-$TAG"
    fi
  done
done
