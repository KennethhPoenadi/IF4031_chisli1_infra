# Menyalin image pihak ketiga (mongo, rabbitmq) ke registry kelompok,
# supaya lolos aturan "hanya image dari registry kita".
#
# Dua mode tujuan (pilih salah satu):
#   MIRROR_REPO=docker.io/<ns>/<repo-app>   -> satu repo, tag "<nama>-<tag>"
#        mongo:7.0  ->  docker.io/<ns>/<repo-app>:mongo-7.0      (REKOMENDASI: sama dengan pola image app,
#                                                                  dan hemat jatah repo private Docker Hub)
#   MIRROR_PREFIX=docker.io/<ns>             -> repo terpisah per image
#        mongo:7.0  ->  docker.io/<ns>/mongo:7.0
# Jika keduanya kosong dan DOCKERHUB_USERNAME ada, dipakai MIRROR_PREFIX=docker.io/$DOCKERHUB_USERNAME.
#
# Kredensial (hak PUSH): REGISTRY_USER/REGISTRY_PASS, atau DOCKERHUB_USERNAME/DOCKERHUB_TOKEN
# (variabel yang sama dengan pipeline app).
# Gunakan versi image yang SAMA dengan docker-compose.yml di repo app.
set -euo pipefail

if [ $# -eq 0 ]; then echo "usage: $0 image:tag [image:tag ...]" >&2; exit 1; fi

REGISTRY_USER="${REGISTRY_USER:-${DOCKERHUB_USERNAME:-}}"
REGISTRY_PASS="${REGISTRY_PASS:-${DOCKERHUB_TOKEN:-}}"

MODE=prefix
if [ -n "${MIRROR_REPO:-}" ]; then
  MODE=repo
  BASE="$MIRROR_REPO"
elif [ -n "${MIRROR_PREFIX:-}" ]; then
  BASE="$MIRROR_PREFIX"
elif [ -n "${DOCKERHUB_USERNAME:-}" ]; then
  BASE="docker.io/$DOCKERHUB_USERNAME"
else
  echo "ERROR: set MIRROR_REPO atau MIRROR_PREFIX (mis. docker.io/<namespace>)" >&2
  exit 1
fi
HOST="${MIRROR_REGISTRY:-${BASE%%/*}}"

if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASS" ]; then
  echo "$REGISTRY_PASS" | docker login "$HOST" -u "$REGISTRY_USER" --password-stdin
else
  echo "ERROR: kredensial registry kosong (REGISTRY_USER/REGISTRY_PASS atau DOCKERHUB_USERNAME/DOCKERHUB_TOKEN)" >&2
  exit 1
fi

for img in "$@"; do
  [[ "$img" == *:* ]] || { echo "ERROR: $img harus punya tag (mis. mongo:7.0)" >&2; exit 1; }
  name="${img%%:*}"
  tag="${img##*:}"
  if [ "$MODE" = repo ]; then
    dest="$BASE:${name//\//-}-$tag"
  else
    dest="$BASE/$name:$tag"
  fi
  docker pull "$img"
  docker tag "$img" "$dest"
  docker push "$dest"
  echo "OK -> $dest"
done
