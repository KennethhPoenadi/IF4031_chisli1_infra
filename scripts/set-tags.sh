set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: set-tags.sh <dev|prod> [sha]}"
SHA="${2:-}"
APP_SERVICES=(auth-service bmkg-mock pvmbg-mock aggregator client-facing-api notifier dashboard-updater)

mkdir -p "envs/$ENV_NAME/tags"
for s in "${APP_SERVICES[@]}"; do
  if [ "$ENV_NAME" = "dev" ]; then
    : "${SHA:?dev butuh sha image}"
    tag="$s-$SHA"
  else
    src="envs/dev/tags/$s.yaml"
    if [ ! -f "$src" ]; then echo "WARN: $s belum ada di dev, skip"; continue; fi
    tag="$(sed -n 's/^  tag: //p' "$src")"
  fi
  printf 'image:\n  tag: %s\n' "$tag" > "envs/$ENV_NAME/tags/$s.yaml"
done

git add "envs/$ENV_NAME/tags"
if git diff --cached --quiet; then echo "Tag sudah terbaru, tidak ada perubahan"; exit 0; fi

git -c user.name="${GITLAB_USER_NAME:-xops-ci}" -c user.email="${GITLAB_USER_EMAIL:-ci@xops.local}" \
  commit -m "chore($ENV_NAME): set image tags ${SHA:-from dev} [skip ci]"

PUSH_URL="${GITOPS_PUSH_URL:-}"
if [ -z "$PUSH_URL" ]; then
  base="${CI_PROJECT_URL:?CI_PROJECT_URL kosong}"
  PUSH_URL="${base/https:\/\//https://oauth2:${GITOPS_TOKEN:?GITOPS_TOKEN belum diisi}@}.git"
fi
git fetch "$PUSH_URL" main
git rebase FETCH_HEAD
git push "$PUSH_URL" HEAD:main
