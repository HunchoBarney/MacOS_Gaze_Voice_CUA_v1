#!/bin/bash
# Stage the pinned executables that `make app` embeds into Jev Voice.app.
# Versions and SHA-256 pins live in source-manifest.json under
# "vendored_binaries"; every artifact is verified before staging and any
# mismatch fails the build — the same posture as the runtime driver pin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANIFEST="$ROOT/ThirdParty/Cua/source-manifest.json"
DEST="$(mkdir -p "${1:-$ROOT/build/vendor}" && cd "${1:-$ROOT/build/vendor}" && pwd)"
CACHE="$DEST/cache"
mkdir -p "$CACHE"

field() {
  python3 - "$MANIFEST" "$1" "$2" <<'PY'
import json, sys
entry = json.load(open(sys.argv[1]))["vendored_binaries"][sys.argv[2]]
print(entry.get(sys.argv[3], ""))
PY
}

sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }

verify() { # path expected label
  [ -f "$1" ] || { echo "vendored $3 missing: $1" >&2; exit 1; }
  [ "$(sha256 "$1")" = "$2" ] || {
    echo "$3 differs from the pinned build ($1). Refusing to embed it." >&2
    exit 1
  }
}

fetch() { # url dest
  curl -fL --retry 3 --retry-delay 2 -o "$2" "$1"
}

# --- cua-driver: the pinned v0.34.0 release build, embedded so TCC grants
# attribute to Jev Voice instead of the standalone CuaDriver app. The
# installed app copy satisfies the pin offline; otherwise fetch the release
# tarball and extract the signed app-bundle binary (the bare top-level
# tarball member is a different build and does NOT match the pin).
DRIVER_SHA="$(field cua-driver sha256)"
DRIVER_OUT="$DEST/cua-driver"
if ! { [ -f "$DRIVER_OUT" ] && [ "$(sha256 "$DRIVER_OUT")" = "$DRIVER_SHA" ]; }; then
  INSTALLED="$(field cua-driver installed)"
  if [ -n "$INSTALLED" ] && [ -f "$INSTALLED" ] && [ "$(sha256 "$INSTALLED")" = "$DRIVER_SHA" ]; then
    cp "$INSTALLED" "$DRIVER_OUT"
  else
    TARBALL="$CACHE/$(basename "$(field cua-driver url)")"
    fetch "$(field cua-driver url)" "$TARBALL"
    verify "$TARBALL" "$(field cua-driver tarball_sha256)" "cua-driver tarball"
    rm -rf "$CACHE/cua-driver"
    mkdir -p "$CACHE/cua-driver"
    tar -xzf "$TARBALL" -C "$CACHE/cua-driver" "$(field cua-driver member)"
    cp "$CACHE/cua-driver/$(field cua-driver member)" "$DRIVER_OUT"
  fi
fi
verify "$DRIVER_OUT" "$DRIVER_SHA" "cua-driver"
chmod +x "$DRIVER_OUT"

# --- codex: @openai/codex darwin-arm64 vendored runtime. The npm layout
# keeps the native binary at <root>/bin/codex with codex-package.json,
# codex-path/ and codex-resources/ resolved relative to that package root,
# so the whole tree is staged and the bundle entrypoint is a second link to
# the same binary.
CODEX_SHA="$(field codex sha256)"
CODEX_OUT="$DEST/CodexRuntime"
if ! { [ -f "$CODEX_OUT/codex" ] && [ "$(sha256 "$CODEX_OUT/codex")" = "$CODEX_SHA" ]; }; then
  TARBALL="$CACHE/$(basename "$(field codex url)")"
  fetch "$(field codex url)" "$TARBALL"
  verify "$TARBALL" "$(field codex tarball_sha256)" "codex tarball"
  rm -rf "$CACHE/codex" "$CODEX_OUT"
  mkdir -p "$CACHE/codex" "$CODEX_OUT"
  tar -xzf "$TARBALL" -C "$CACHE/codex" "$(field codex vendor_root)"
  cp -R "$CACHE/codex/$(field codex vendor_root)/." "$CODEX_OUT/"
  ln -f "$CODEX_OUT/$(field codex entrypoint)" "$CODEX_OUT/codex"
fi
verify "$CODEX_OUT/codex" "$CODEX_SHA" "codex"
chmod +x "$CODEX_OUT/codex" "$CODEX_OUT/$(field codex entrypoint)"

echo "vendored cua-driver $(field cua-driver version) + codex $(field codex version) → $DEST"
