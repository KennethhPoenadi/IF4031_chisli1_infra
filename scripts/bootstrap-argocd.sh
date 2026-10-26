set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

REPO_URL="${GITOPS_REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  REPO_URL="${CI_PROJECT_URL:+$CI_PROJECT_URL.git}"
  REPO_URL="${REPO_URL:-$(git remote get-url origin | sed -E 's#//[^@/]+@#//#')}"
fi
APP_IMAGE_NAME="${APP_IMAGE_NAME:-if4054-2026-t1-13523008-13523029-13523040}"
IMAGE_REPO="${IMAGE_REPO:-${DOCKERHUB_USERNAME:?DOCKERHUB_USERNAME belum diisi}/$APP_IMAGE_NAME}"

for env in dev prod; do ./scripts/create-secrets.sh "$env"; done

if [ -n "${GITOPS_TOKEN:-}" ]; then
  kubectl -n argocd create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username=oauth2 \
    --from-literal=password="$GITOPS_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kubectl apply -f -
fi

sed -e "s#__REPO_URL__#$REPO_URL#" -e "s#__IMAGE_REPO__#$IMAGE_REPO#" argocd/applicationset.yaml | kubectl apply -f -
kubectl get applications -n argocd
