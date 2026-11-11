set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

ENV_NAME="${1:?usage: create-secrets.sh <dev|prod>}"
NAMESPACE="$(ns_for "$ENV_NAME")"

if [ -n "${ENV_FILE:-}" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

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
  optional=false
  if [[ "$key" == *\? ]]; then optional=true; key="${key%\?}"; fi
  if [ -n "${!key:-}" ]; then
    args+=("--from-literal=$key=${!key}")
  elif [ "$optional" = false ]; then
    missing+=("$key")
  fi
done < scripts/secret-keys.txt

if [ ${#missing[@]} -gt 0 ]; then
  echo "ERROR: variabel belum diisi: ${missing[*]}" >&2
  exit 1
fi

kubectl create secret generic app-secrets "${args[@]}" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [ -n "${LLM_API_KEY:-}" ] && [ -n "${LLM_BASE_URL:-}" ] && [ -n "${LLM_MODEL:-}" ]; then
  kubectl create secret generic llm-credentials \
    --from-literal=LLM_BASE_URL="$LLM_BASE_URL" \
    --from-literal=LLM_MODEL="$LLM_MODEL" \
    --from-literal=LLM_API_KEY="$LLM_API_KEY" \
    -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret llm-credentials siap di namespace $NAMESPACE"
else
  echo "LLM_* tidak lengkap: llm-credentials dilewati (analisis memakai templat)"
fi

echo "Secret registry-credentials dan app-secrets siap di namespace $NAMESPACE (environment $ENV_NAME)"
