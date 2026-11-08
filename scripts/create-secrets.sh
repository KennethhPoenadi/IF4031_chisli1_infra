set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

ENV_NAME="${1:?usage: create-secrets.sh <dev|prod>}"
NAMESPACE="$(ns_for "$ENV_NAME")"

if [ -n "${ENV_FILE:-}" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# Pull credentials for the image registry. Use a read-only token (GHCR: classic PAT with only read:packages).
: "${REGISTRY_SERVER:=ghcr.io}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_PASS="${REGISTRY_PASS:-}"
for v in REGISTRY_SERVER REGISTRY_USER REGISTRY_PASS; do
  [ -n "${!v:-}" ] || { echo "ERROR: variabel $v kosong" >&2; exit 1; }
done
kubectl create secret docker-registry registry-credentials \
  --docker-server="$REGISTRY_SERVER" \
  --docker-username="$REGISTRY_USER" \
  --docker-password="$REGISTRY_PASS" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

args=()
missing=()
while read -r key; do
  [[ -z "$key" || "$key" == \#* ]] && continue
  if [ -n "${!key:-}" ]; then
    args+=("--from-literal=$key=${!key}")
  else
    missing+=("$key")
  fi
done < scripts/secret-keys.txt

if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: variabel belum diisi: ${missing[*]}" >&2
  exit 1
fi

kubectl create secret generic app-secrets "${args[@]}" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "Secret registry-credentials dan app-secrets siap di namespace $NAMESPACE (environment $ENV_NAME)"
