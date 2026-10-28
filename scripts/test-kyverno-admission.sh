#!/usr/bin/env bash
set -euo pipefail

: "${IMAGE_REPO:?IMAGE_REPO belum diisi}"

violations_file="policies/tests/deployment-violations.yaml"
test -f "$violations_file"

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

awk -v dir="$work_dir" '
  /^---[[:space:]]*$/ { document++; next }
  { print > (dir "/violation-" document ".yaml") }
' "$violations_file"

checked=0
for manifest in "$work_dir"/violation-*.yaml; do
  resource_name="$(awk '$1 == "name:" { print $2; exit }' "$manifest")"
  rendered_manifest="$(sed "s|__IMAGE_REPO__|$IMAGE_REPO|g" "$manifest")"

  if rejection="$(printf '%s\n' "$rendered_manifest" | kubectl apply --dry-run=server -f - 2>&1)"; then
    echo "ERROR: Kyverno menerima manifest pelanggaran: $resource_name" >&2
    exit 1
  fi

  if ! printf '%s\n' "$rejection" | grep -qi kyverno; then
    echo "ERROR: $resource_name ditolak, tetapi bukan oleh Kyverno:" >&2
    printf '%s\n' "$rejection" >&2
    exit 1
  fi

  echo "PASS: Kyverno menolak $resource_name"
  checked=$((checked + 1))
done

test "$checked" -gt 0
echo "Kyverno admission check selesai: $checked manifest pelanggaran ditolak."
