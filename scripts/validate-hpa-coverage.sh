#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source scripts/env.sh

checked=0
for env_name in dev prod; do
  for values_file in "envs/$env_name"/*.yaml; do
    service="$(basename "$values_file" .yaml)"
    rendered="$(helm template "$service" charts/microservice \
      --namespace "$(ns_for "$env_name")" \
      --values "$values_file" \
      --set image.repository=validate/app \
      --set "image.tag=$service-validate")"

    if printf '%s\n' "$rendered" | grep -q '^kind: Deployment$'; then
      if ! printf '%s\n' "$rendered" | grep -q '^kind: HorizontalPodAutoscaler$'; then
        echo "ERROR: $env_name/$service memiliki Deployment tanpa HPA" >&2
        exit 1
      fi

      echo "PASS: $env_name/$service memiliki Deployment dan HPA"
      checked=$((checked + 1))
    fi
  done
done

if [ "$checked" -ne 16 ]; then
  echo "ERROR: jumlah Deployment aplikasi dengan HPA adalah $checked, seharusnya 16" >&2
  exit 1
fi

echo "Validasi HPA selesai: $checked Deployment memiliki HPA."
