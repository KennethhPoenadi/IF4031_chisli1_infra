set -euo pipefail

if [ $# -eq 0 ]; then echo "usage: $0 image:tag [image:tag ...]" >&2; exit 1; fi

PLATFORM_ARCH="${PLATFORM_ARCH:-amd64}"
REGISTRY_USER="${REGISTRY_USER:-}"
REGISTRY_PASS="${REGISTRY_PASS:-}"

MODE=prefix
if [ -n "${MIRROR_REPO:-}" ]; then
  MODE=repo
  BASE="$MIRROR_REPO"
elif [ -n "${MIRROR_PREFIX:-}" ]; then
  BASE="$MIRROR_PREFIX"
else
  echo "ERROR: set MIRROR_REPO atau MIRROR_PREFIX (mis. ghcr.io/<owner>)" >&2
  exit 1
fi
BASE="$(printf '%s' "$BASE" | tr '[:upper:]' '[:lower:]')"
HOST="${MIRROR_REGISTRY:-${BASE%%/*}}"

if [ -n "$REGISTRY_USER" ] && [ -n "$REGISTRY_PASS" ]; then
  echo "$REGISTRY_PASS" | docker login "$HOST" -u "$REGISTRY_USER" --password-stdin
else
  echo "ERROR: kredensial registry kosong (REGISTRY_USER/REGISTRY_PASS)" >&2
  exit 1
fi

for img in "$@"; do
  [[ "$img" == *:* ]] || { echo "ERROR: $img harus punya tag (mis. mongo:7.0)" >&2; exit 1; }
  name="${img%%:*}"
  tag="${img##*:}"
  if [ "$MODE" = repo ]; then
    dests=("$BASE:${name//\//-}-$tag" "$BASE:${name//\//-}-latest")
  else
    dests=("$BASE/$name:$tag")
  fi
  pulled=0
  for dest in "${dests[@]}"; do
    # Lewati hanya bila tag sudah ada DAN arsitekturnya cocok; image arm64 hasil mirror lama harus ditimpa.
    if existing="$(docker manifest inspect -v "$dest" 2>/dev/null)" \
       && grep -q "\"architecture\": \"${PLATFORM_ARCH}\"" <<<"$existing"; then
      echo "SKIP $dest sudah ada ($PLATFORM_ARCH)"
      continue
    fi
    if [ "$pulled" = 0 ]; then docker pull --platform "linux/${PLATFORM_ARCH}" "$img"; pulled=1; fi
    docker tag "$img" "$dest"
    docker push --quiet "$dest"
    echo "OK -> $dest"
  done
done
