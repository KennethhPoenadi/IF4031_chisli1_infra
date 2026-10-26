# Membuat Secret di namespace target: image pull secret + app-secrets. Idempoten.
# Usage : ./scripts/create-secrets.sh <dev|prod>
# Lokal : ENV_FILE=.env REGISTRY_SERVER=... REGISTRY_USER=... REGISTRY_PASS=... ./scripts/create-secrets.sh dev
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

ENV_NAME="${1:?usage: create-secrets.sh <dev|prod>}"

if [ -n "${ENV_FILE:-}" ]; then
  set -a; source "$ENV_FILE"; set +a
fi

kubectl create namespace "$ENV_NAME" --dry-run=client -o yaml | kubectl apply -f -

# 1. Image pull secret ke registry GitLab
# Registry = Docker Hub (GitLab Edu ITB tidak menyediakan Container Registry).
: "${REGISTRY_SERVER:=https://index.docker.io/v1/}"
REGISTRY_USER="${REGISTRY_USER:-${DOCKERHUB_USERNAME:-}}"
REGISTRY_PASS="${REGISTRY_PASS:-${DOCKERHUB_TOKEN:-}}"
for v in REGISTRY_SERVER REGISTRY_USER REGISTRY_PASS; do
  [ -n "${!v:-}" ] || { echo "ERROR: variabel $v kosong" >&2; exit 1; }
done
kubectl create secret docker-registry gitlab-registry \
  --docker-server="$REGISTRY_SERVER" \
  --docker-username="$REGISTRY_USER" \
  --docker-password="$REGISTRY_PASS" \
  -n "$ENV_NAME" --dry-run=client -o yaml | kubectl apply -f -

# 2. Secret aplikasi
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
  -n "$ENV_NAME" --dry-run=client -o yaml | kubectl apply -f -

echo "Secret gitlab-registry dan app-secrets siap di namespace $ENV_NAME"
