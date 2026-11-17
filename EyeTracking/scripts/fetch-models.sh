#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
manifest="$PWD/scripts/required-models.sha256"
mkdir -p public/models
cd public/models
base=https://github.com/PINTO0309/screen-eye-tracking/releases/download/onnx
while read -r digest name; do
  if [[ ! -f "$name" ]]; then
    tmp="$(mktemp "./$name.XXXXXX")"
    trap 'rm -f "$tmp"' EXIT
    curl -fL --retry 3 -o "$tmp" "$base/$name"
    printf '%s  %s\n' "$digest" "$tmp" | shasum -a 256 -c -
    mv "$tmp" "$name"
    trap - EXIT
  fi
done < "$manifest"
shasum -a 256 -c "$manifest"
