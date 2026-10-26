# Men-deploy workload ke namespace dev/prod memakai chart generik.
#
# Pola image dari pipeline app: satu repo Docker Hub, tag "<service>-<sha>" dan "<service>-latest".
# Pipeline app hanya membangun service yang kodenya berubah, jadi tag sha TIDAK ada untuk semua service.
#
# Mode:
#   dev + DEPLOY_SERVICES + IMAGE_TAG -> selektif: hanya service itu, tag "<service>-<IMAGE_TAG>"
#   dev + IMAGE_TAG saja              -> semua service dengan tag "<service>-<IMAGE_TAG>" (hanya jika semua image ada)
#   dev tanpa variabel                -> semua service, pakai tag yang sedang berjalan (atau "<service>-latest" pertama kali)
#   prod                              -> PROMOSI: pakai tag yang sedang berjalan di dev (apa yang teruji di dev yang naik ke prod)
#
# Usage: [IMAGE_TAG=<sha>] [DEPLOY_SERVICES="aggregator notifier"] ./scripts/deploy.sh <dev|prod>
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

ENV_NAME="${1:?usage: deploy.sh <dev|prod>}"
SHA="${IMAGE_TAG:-}"
SELECTED="${DEPLOY_SERVICES:-}"
CHART=charts/microservice

./scripts/create-secrets.sh "$ENV_NAME"

if [ ! -f "$CHART/Chart.yaml" ]; then
  echo "WARN: $CHART belum ada."
  [ "${REQUIRE_CHART:-false}" = "true" ] && exit 1
  exit 0
fi

INFRA_SERVICES=(mongo rabbitmq)
APP_SERVICES=(auth-service bmkg-mock pvmbg-mock aggregator client-facing-api notifier dashboard-updater)

if [ "$ENV_NAME" = "prod" ]; then
  MODE=promote
  SELECTED=""
elif [ -n "$SELECTED" ]; then
  [ -n "$SHA" ] || { echo "ERROR: DEPLOY_SERVICES butuh IMAGE_TAG" >&2; exit 1; }
  MODE=selective
else
  MODE=full
fi
echo "Mode deploy: $MODE (env=$ENV_NAME sha=${SHA:-none} services=${SELECTED:-semua})"

current_tag() {   # tag yang sedang terpasang: current_tag <namespace> <release>
  helm get values "$2" -n "$1" -o json 2>/dev/null | jq -r '.image.tag // empty' || true
}

is_selected() {
  [ -z "$SELECTED" ] && return 0
  for x in $SELECTED; do [ "$x" = "$1" ] && return 0; done
  return 1
}

deploy() {
  local svc="$1"; shift
  local values="envs/$ENV_NAME/$svc.yaml"
  if [ ! -f "$values" ]; then
    echo "WARN: $values belum ada, skip $svc"
    return 0
  fi
  echo "==> helm $svc ($ENV_NAME)"
  helm upgrade --install "$svc" "$CHART" -n "$ENV_NAME" -f "$values" "$@" \
    --atomic --wait --timeout 5m
}

# mongo & rabbitmq (image dari mirror, tag ada di values) - tidak disentuh pada deploy selektif
if [ "$MODE" != "selective" ]; then
  for s in "${INFRA_SERVICES[@]}"; do deploy "$s"; done
fi

for s in "${APP_SERVICES[@]}"; do
  is_selected "$s" || continue
  case "$MODE" in
    selective) tag="$s-$SHA" ;;
    promote)
      tag="$(current_tag dev "$s")"
      if [ -z "$tag" ]; then echo "WARN: $s belum ada di dev, skip"; continue; fi
      ;;
    full)
      if [ -n "$SHA" ]; then
        tag="$s-$SHA"
      else
        tag="$(current_tag "$ENV_NAME" "$s")"
        tag="${tag:-$s-latest}"
      fi
      ;;
  esac
  deploy "$s" --set image.tag="$tag"
done

kubectl get pods -n "$ENV_NAME"
