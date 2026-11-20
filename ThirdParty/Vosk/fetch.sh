#!/bin/bash
# Fetches the pinned Vosk library and small English model into a vendor
# directory (default build/vendor/Vosk) and verifies their SHA-256.
#   <dest>/libvosk.dylib   from the official vosk 0.3.44 macOS wheel (universal2)
#   <dest>/model/          vosk-model-small-en-us-0.15
set -euo pipefail

DEST="${1:-build/vendor/Vosk}"
WHEEL_URL="https://files.pythonhosted.org/packages/44/19/5e8299237bc2005c3d155d3b48adba6fd6484465ad5c970302fc1d37947d/vosk-0.3.44-py3-none-macosx_10_6_universal2.whl"
WHEEL_SHA256="029d0b3d6a5cff874c575b8a5814a4cccfb37608cff52e846c02a8c67a882801"
MODEL_URL="https://alphacephei.com/vosk/models/vosk-model-small-en-us-0.15.zip"
MODEL_SHA256="30f26242c4eb449f948e42cb302dd7a686cb29a3423a8367f99ff41780942498"
STAMP="$WHEEL_SHA256 $MODEL_SHA256"

if [[ -f "$DEST/.pinned" && "$(cat "$DEST/.pinned")" == "$STAMP" ]]; then exit 0; fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
curl -fsSL --retry 3 -o "$work/vosk.whl" "$WHEEL_URL"
echo "$WHEEL_SHA256  $work/vosk.whl" | shasum -a 256 -c - >/dev/null
curl -fsSL --retry 3 -o "$work/model.zip" "$MODEL_URL"
echo "$MODEL_SHA256  $work/model.zip" | shasum -a 256 -c - >/dev/null

unzip -q "$work/vosk.whl" vosk/libvosk.dyld -d "$work/wheel"
unzip -q "$work/model.zip" -d "$work/model"
rm -rf "$DEST"
mkdir -p "$DEST"
cp "$work/wheel/vosk/libvosk.dyld" "$DEST/libvosk.dylib"
mv "$work/model/vosk-model-small-en-us-0.15" "$DEST/model"
echo "$STAMP" > "$DEST/.pinned"
echo "Vosk ready in $DEST"
