#!/bin/bash
# Renders the UI gallery (gallery/README.md): the eye tracker's surfaces in
# headless Chrome (gallery/tracker), then every native surface offscreen
# through the Swift harness (Tests/JarvisGalleryTests) in the build lane.
# Output: build/gallery/renders, or $JARVIS_GALLERY_OUT.
set -euo pipefail
ROOT=$(git rev-parse --show-toplevel)
OUT=${JARVIS_GALLERY_OUT:-$ROOT/build/gallery/renders}
rm -rf "$OUT"
mkdir -p "$OUT"
export JARVIS_GALLERY_OUT="$OUT"
export JARVIS_GALLERY_COMMIT=${JARVIS_GALLERY_COMMIT:-$(git -C "$ROOT" rev-parse --short HEAD)}
if [ "${GALLERY_SKIP_TRACKER:-0}" != 1 ]; then
    node "$ROOT/gallery/tracker/render.mjs" --out "$OUT"
fi
"$ROOT/scripts/lane-test.sh" swift test --filter GalleryRenderTests
test -f "$OUT/manifest.native.json"
echo "gallery: renders in $OUT"
