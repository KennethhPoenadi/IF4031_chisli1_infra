set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/env.sh

REPO_URL="${GITOPS_REPO_URL:-}"
if [ -z "$REPO_URL" ]; then
  REPO_URL="${GITHUB_REPOSITORY:+${GITHUB_SERVER_URL:-https://github.com}/$GITHUB_REPOSITORY.git}"
  REPO_URL="${REPO_URL:-$(git remote get-url origin | sed -E 's#//[^@/]+@#//#')}"
fi
IMAGE_REPO="${IMAGE_REPO:-$(scripts/image-repo.sh)}"
IMAGE_REPO="$(printf '%s' "$IMAGE_REPO" | tr '[:upper:]' '[:lower:]')"

if [ -n "${GITOPS_TOKEN:-}" ]; then
  kubectl -n argocd create secret generic gitops-repo \
    --from-literal=type=git \
    --from-literal=url="$REPO_URL" \
    --from-literal=username=x-access-token \
    --from-literal=password="$GITOPS_TOKEN" \
    --dry-run=client -o yaml \
    | kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml \
    | kubectl apply -f -
fi

sed -e "s#__REPO_URL__#$REPO_URL#" -e "s#__IMAGE_REPO__#$IMAGE_REPO#" argocd/applicationset.yaml | kubectl apply -f -
kubectl get applications -n argocd
