#!/usr/bin/env bash
set -euo pipefail
: "${APP_IMAGE_NAME:?APP_IMAGE_NAME belum diisi}"
owner="${REGISTRY_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
: "${owner:?REGISTRY_OWNER (atau GITHUB_REPOSITORY_OWNER) belum diisi}"
printf '%s\n' "${REGISTRY_HOST:-ghcr.io}/$owner/$APP_IMAGE_NAME" | tr '[:upper:]' '[:lower:]'
