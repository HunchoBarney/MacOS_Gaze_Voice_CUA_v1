#!/usr/bin/env bash
# Installs the e2e runner and builds its macOS engine from the pinned commit.
# Run it only after the owner's go (handoffs/e2e-go.md). Everything lands in
# e2e/node_modules and e2e/vendor; the engine downloads agent-desktop into
# ~/Library/Caches/e2e on the first run. scripts/uninstall.sh removes all of it.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=../engine.pin
. "$here/engine.pin"
short=${E2E_ENGINE_COMMIT:0:7}
version="0.0.0-pr$E2E_PR.$short"
tarball="$here/vendor/e2e-dev-desktop-$version.tgz"
pnpm() { corepack pnpm "$@"; }

if [ ! -f "$tarball" ]; then
    src="$here/vendor/src"
    rm -rf "$src" "$here/vendor/packages" && mkdir -p "$src"
    git -C "$src" init -q
    git -C "$src" fetch -q --depth 1 "$E2E_REPO" "$E2E_ENGINE_COMMIT" \
        || git -C "$src" fetch -q --depth 1 "$E2E_REPO" "refs/pull/$E2E_PR/head"
    git -C "$src" checkout -q FETCH_HEAD
    [ "$(git -C "$src" rev-parse HEAD)" = "$E2E_ENGINE_COMMIT" ] \
        || { echo "install: e2e#$E2E_PR moved past $E2E_ENGINE_COMMIT; update engine.pin after reading the new commits" >&2; exit 1; }

    # Build the engine package alone, against the published core it was written for.
    stage="$here/vendor/packages/desktop"
    mkdir -p "$here/vendor/packages"
    cp -R "$src/packages/desktop" "$stage"
    cp "$src/tsconfig.base.json" "$here/vendor/tsconfig.base.json"
    node -e '
        const fs = require("node:fs");
        const [file, version, core] = process.argv.slice(1);
        const p = JSON.parse(fs.readFileSync(file, "utf8"));
        p.version = version;
        p.devDependencies["@e2e-dev/core"] = core;
        p.devDependencies.e2e = core;
        p.scripts = {};
        fs.writeFileSync(file, JSON.stringify(p, null, 2) + "\n");
    ' "$stage/package.json" "$version" "$E2E_CORE_VERSION"
    (cd "$stage" && pnpm install --ignore-scripts --config.lockfile=false >/dev/null \
        && node_modules/.bin/tsc --project tsconfig.build.json \
        && printf '{"version":"%s"}\n' "$version" > dist/.build.json \
        && pnpm pack --pack-destination "$here/vendor" >/dev/null)
    rm -rf "$src" "$here/vendor/packages" "$here/vendor/tsconfig.base.json"
fi
[ -f "$tarball" ] || { echo "install: the engine build left no $tarball" >&2; exit 1; }

cd "$here"
pnpm install --ignore-scripts
pnpm run typecheck
echo "installed e2e $E2E_CORE_VERSION and @e2e-dev/desktop $version (e2e-inc/e2e@$short)"
echo "next: pnpm exec e2e doctor (from e2e/) checks agent-desktop and the runner's permissions"
