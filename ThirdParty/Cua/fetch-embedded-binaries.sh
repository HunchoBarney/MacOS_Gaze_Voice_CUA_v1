#!/bin/bash
# Stage the pinned executables that `make app` embeds into Jarvis.app.
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

# --- cua-driver: upstream source at the pinned commit plus our reviewed
# patch (host-connections-only.patch), built here and pinned by the
# artefact's own SHA-256. The build is reproducible: a locked dependency
# graph, the toolchain upstream pins in rust-toolchain.toml, a fixed git
# revision, every machine-specific path remapped, and one fixed build
# directory: Cargo hashes the absolute path of the path dependencies under
# libs/cua/crates into their crate metadata, so a build anywhere else gets a
# different binary. A cached build that
# matches the pin is reused. Needs rustup (it installs the pinned
# toolchain on first use) and network for the clone and crates.
DRIVER_SHA="$(field cua-driver sha256)"
DRIVER_OUT="$DEST/cua-driver"
if ! { [ -f "$DRIVER_OUT" ] && [ "$(sha256 "$DRIVER_OUT")" = "$DRIVER_SHA" ]; }; then
  COMMIT="$(field cua-driver commit)"
  PATCH="$ROOT/$(field cua-driver patch)"
  verify "$PATCH" "$(field cua-driver patch_sha256)" "cua-driver patch"
  SRC="/private/tmp/jarvis-cua-driver-$COMMIT"
  if [ ! -d "$SRC/.git" ]; then
    rm -rf "$SRC"
    git clone --quiet --filter=blob:none --no-checkout --depth 1 \
      --branch "$(field cua-driver tag)" "$(field cua-driver repository)" "$SRC"
    git -C "$SRC" sparse-checkout set --no-cone /libs/cua-driver/rust/ \
      /libs/cua/Cargo.toml /libs/cua/crates/cua-agent-setup/ /libs/cua/crates/cua-home/ /libs/cua/crates/cua-telemetry/ \
      /libs/cua/skills/ /libs/images/sandbox-images.json /libs/cua/crates/cua-teleport/src/ux/targets.json
  fi
  [ "$(git -C "$SRC" rev-parse HEAD)" = "$COMMIT" ] || {
    echo "cua-driver $(field cua-driver tag) is not the pinned commit $COMMIT. Refusing to build it." >&2
    exit 1
  }
  git -C "$SRC" checkout --quiet --force HEAD
  git -C "$SRC" apply "$PATCH"
  RUST="$SRC/libs/cua-driver/rust"
  TARGET="$SRC-target"
  ( cd "$RUST" && CARGO_TARGET_DIR="$TARGET" CUA_DRIVER_GIT_SHA="$COMMIT" \
      RUSTFLAGS="--remap-path-prefix=$SRC=/cua --remap-path-prefix=$TARGET=/target --remap-path-prefix=$HOME/.cargo=/cargo --remap-path-prefix=$HOME/.rustup=/rustup" \
      cargo build --release --locked -p cua-driver )
  cp "$TARGET/release/cua-driver" "$DRIVER_OUT"
fi
verify "$DRIVER_OUT" "$DRIVER_SHA" "cua-driver"
chmod +x "$DRIVER_OUT"

# --- codex: @openai/codex darwin-arm64 vendored runtime. The npm layout
# keeps the native binary at <root>/bin/codex with codex-package.json,
# codex-path/ and codex-resources/ resolved relative to that package root,
# so the whole tree is staged and the bundle entrypoint is a second link to
# the same binary. A cache counts as complete only when both names exist and
# are one file; anything else is re-extracted.
CODEX_SHA="$(field codex sha256)"
CODEX_OUT="$DEST/CodexRuntime"
CODEX_BIN="$CODEX_OUT/$(field codex entrypoint)"
if ! { [ -f "$CODEX_OUT/codex" ] && [ -f "$CODEX_BIN" ] && [ "$CODEX_OUT/codex" -ef "$CODEX_BIN" ] \
       && [ "$(sha256 "$CODEX_OUT/codex")" = "$CODEX_SHA" ]; }; then
  TARBALL="$CACHE/$(basename "$(field codex url)")"
  fetch "$(field codex url)" "$TARBALL"
  verify "$TARBALL" "$(field codex tarball_sha256)" "codex tarball"
  rm -rf "$CACHE/codex" "$CODEX_OUT"
  mkdir -p "$CACHE/codex" "$CODEX_OUT"
  tar -xzf "$TARBALL" -C "$CACHE/codex" "$(field codex vendor_root)"
  cp -R "$CACHE/codex/$(field codex vendor_root)/." "$CODEX_OUT/"
  ln -f "$CODEX_BIN" "$CODEX_OUT/codex"
fi
verify "$CODEX_OUT/codex" "$CODEX_SHA" "codex"
chmod +x "$CODEX_BIN"

echo "vendored cua-driver $(field cua-driver version) + codex $(field codex version) → $DEST"
