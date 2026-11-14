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
      # ScaledObject KEDA membuat HPA sendiri, sehingga dihitung setara HPA.
      if printf '%s\n' "$rendered" | grep -q '^kind: ScaledObject$'; then
        if printf '%s\n' "$rendered" | grep -q '^kind: HorizontalPodAutoscaler$'; then
          echo "ERROR: $env_name/$service memiliki HPA dan ScaledObject sekaligus" >&2
          exit 1
        fi
        echo "PASS: $env_name/$service memiliki Deployment dan ScaledObject (KEDA)"
        checked=$((checked + 1))
        continue
      fi
      if ! printf '%s\n' "$rendered" | grep -q '^kind: HorizontalPodAutoscaler$'; then
        echo "ERROR: $env_name/$service memiliki Deployment tanpa HPA" >&2
        exit 1
      fi

      echo "PASS: $env_name/$service memiliki Deployment dan HPA"
      checked=$((checked + 1))
    fi
  done
done

if [ "$checked" -ne 20 ]; then
  echo "ERROR: jumlah Deployment aplikasi dengan HPA atau ScaledObject adalah $checked, seharusnya 20" >&2
  exit 1
fi

echo "Validasi autoscaling selesai: $checked Deployment memiliki HPA atau ScaledObject."
