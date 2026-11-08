#!/usr/bin/env bash
# Prints the image repository every workload must pull from: <registry>/<owner>/<APP_IMAGE_NAME>, lowercase
# (registries reject uppercase). Single source of truth for CI, Argo CD bootstrap, Kyverno and the mirror.
set -euo pipefail
: "${APP_IMAGE_NAME:?APP_IMAGE_NAME belum diisi}"
owner="${REGISTRY_OWNER:-${GITHUB_REPOSITORY_OWNER:-}}"
: "${owner:?REGISTRY_OWNER (atau GITHUB_REPOSITORY_OWNER) belum diisi}"
printf '%s\n' "${REGISTRY_HOST:-ghcr.io}/$owner/$APP_IMAGE_NAME" | tr '[:upper:]' '[:lower:]'
