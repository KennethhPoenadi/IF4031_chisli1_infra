set -euo pipefail
cd "$(dirname "$0")/.."

ENV_NAME="${1:?usage: set-tags.sh <dev|prod> [sha]}"
SHA="${2:-}"
APP_SERVICES=(auth-service bmkg-mock pvmbg-mock aggregator client-facing-api notifier dashboard-updater situation-analyst satellite-ingestor)

PUSH_URL="${GITOPS_PUSH_URL:-}"
if [ -z "$PUSH_URL" ]; then
  server="${GITHUB_SERVER_URL:?GITHUB_SERVER_URL kosong (jalankan di GitHub Actions atau set GITOPS_PUSH_URL)}"
  repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY kosong}"
  PUSH_URL="${server/https:\/\//https://x-access-token:${GITOPS_TOKEN:?GITOPS_TOKEN belum diisi}@}/$repo.git"
fi

if [ -n "${CI:-}" ]; then
  git fetch "$PUSH_URL" main
  git reset --hard FETCH_HEAD
fi

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

GIT_NAME="${GITHUB_ACTOR:-xops-ci}"
GIT_EMAIL="${GITHUB_ACTOR:+$GITHUB_ACTOR@users.noreply.github.com}"
git -c user.name="$GIT_NAME" -c user.email="${GIT_EMAIL:-ci@xops.local}" \
  commit -m "chore($ENV_NAME): set image tags ${SHA:-from dev} [skip ci]"

git fetch "$PUSH_URL" main
git rebase FETCH_HEAD
git push "$PUSH_URL" HEAD:main
