#!/bin/bash
# SwiftPM copies .metal resources into each target's bundle but only Xcode
# compiles them. This compiles every bundle's shaders into its
# default.metallib, which ShaderLibrary.bundle(.module) loads. Needs Apple's
# Metal Toolchain (xcodebuild -downloadComponent MetalToolchain).
#   scripts/lab-metallib.sh .build/debug
set -euo pipefail
BIN=${1:?usage: lab-metallib.sh <build products dir>}
xcrun -sdk macosx -f metal >/dev/null
for bundle in "$BIN"/*.bundle; do
    shaders=$(find "$bundle" -name '*.metal')
    [ -n "$shaders" ] || continue
    stale=0
    for shader in $shaders; do
        [ "$bundle/default.metallib" -nt "$shader" ] || stale=1
    done
    [ "$stale" = 1 ] || continue
    work=$(mktemp -d)
    for shader in $shaders; do
        xcrun -sdk macosx metal -c "$shader" -o "$work/$(basename "$shader" .metal).air"
    done
    xcrun -sdk macosx metallib "$work"/*.air -o "$bundle/default.metallib"
    rm -rf "$work"
    echo "lab-metallib: $(basename "$bundle")"
done
