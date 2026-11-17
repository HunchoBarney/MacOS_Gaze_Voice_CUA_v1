#!/usr/bin/env bash
# Fetches the ONNX models the tracker expects into public/models/.
#
# The model list is scraped from the --*-model defaults in
# electron/main.cjs so it cannot drift from the code, and the download base
# URL is read off the GitHub release link in README.md (the
# PINTO0309/screen-eye-tracking "onnx" release). Files already present are
# skipped; a sibling <model>.sha256 containing just the hex digest is
# verified when one exists — upstream publishes none, so verification only
# activates if the repo starts documenting hashes.
#
# If no release URL can be determined from the repo the script prints the
# exact manual step instead of failing silently.
set -euo pipefail

cd "$(dirname "$0")/.."
MODEL_DIR="public/models"
MAIN="electron/main.cjs"
README="README.md"

base_url=""
if [[ -f "$README" ]]; then
  base_url="$(grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/releases/download/[^/[:space:]]+' "$README" | head -n 1 || true)"
fi

models=()
if [[ -f "$MAIN" ]]; then
  while IFS= read -r name; do
    models+=("$name")
  done < <(grep -oE 'public/models/[A-Za-z0-9_.-]+\.onnx' "$MAIN" | sed -e 's|^public/models/||' | sort -u)
fi

if [[ ${#models[@]} -eq 0 ]]; then
  echo "fetch-models: found no public/models/*.onnx references in $MAIN — nothing to fetch." >&2
  exit 1
fi

if [[ -z "$base_url" ]]; then
  cat >&2 <<EOF
fetch-models: could not determine a GitHub release URL from $README.
Download these files manually and place them in $MODEL_DIR/:
EOF
  printf '  %s\n' "${models[@]}" >&2
  echo "Upstream release page: https://github.com/PINTO0309/screen-eye-tracking/releases (tag: onnx)." >&2
  exit 1
fi

mkdir -p "$MODEL_DIR"
failures=0
for name in "${models[@]}"; do
  target="$MODEL_DIR/$name"
  if [[ -f "$target" ]]; then
    echo "skip (present): $name"
    continue
  fi
  url="$base_url/$name"
  tmp="$target.download"
  echo "fetch: $url"
  if ! curl -fL --retry 3 --connect-timeout 15 -o "$tmp" "$url"; then
    rm -f "$tmp"
    echo "  FAILED — download manually: $url -> $target" >&2
    failures=$((failures + 1))
    continue
  fi
  mv "$tmp" "$target"
  if [[ -f "$target.sha256" ]]; then
    expected="$(awk '{print $1}' "$target.sha256" | tr -d '[:space:]')"
    actual="$(shasum -a 256 "$target" | awk '{print $1}')"
    if [[ "$actual" != "$expected" ]]; then
      echo "  FAILED — sha256 mismatch for $name (expected $expected, got $actual); removed." >&2
      rm -f "$target"
      failures=$((failures + 1))
      continue
    fi
    echo "  sha256 verified: $name"
  fi
done

if [[ $failures -gt 0 ]]; then
  echo "fetch-models: $failures model(s) could not be fetched — use the manual URLs above." >&2
  exit 1
fi
echo "fetch-models: all models present in $MODEL_DIR/."
