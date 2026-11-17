#!/usr/bin/env bash
# Stage the eye tracker into the app bundle (or another destination) so a
# bare `Jev Voice.app` can run gaze without a sibling checkout, a symlink,
# or env vars.
#
# Produces a tracker root whose layout mirrors an EyeTracking checkout —
# TrackerHost spawns `node scripts/start-prod.cjs` with the tracker root as
# cwd, so the bundled copy keeps every relative resolution the checkout
# uses (dist/ for the renderer, public/ for model sources, electron/*.cjs
# for the entry point, node_modules/.bin/electron for the launcher):
#
#   <app>/Contents/Resources/EyeTracker/      bundled tracker root (canonical)
#     package.json                            copied unmodified ("main" entry)
#     electron/**                             main-process sources, as-is
#     scripts/**                              start-prod.cjs + friends, as-is
#     dist/**                                 built renderer (vite output:
#                                             index.html, assets/, models/,
#                                             runtime-assets/)
#     public/models -> ../dist/models         dev reads sources from public/;
#                                             the checkout copies them into
#                                             dist/ at build time, so the link
#                                             satisfies both without ~400M of
#                                             duplication
#     node_modules/
#       .bin/electron                         clean shim — the pnpm-generated
#                                             one hardcodes this checkout's
#                                             absolute path in NODE_PATH
#       .pnpm/<closure dirs>                  pnpm virtual store subset —
#                                             electron + the runtime require()
#                                             closure of electron/*.cjs,
#                                             internal symlinks preserved
#       .pnpm/node_modules                    pnpm's hoisted-link dir (32K);
#                                             copied wholesale so no staged
#                                             symlink dangles
#       electron -> .pnpm/electron@…/…        top-level links, same targets
#       ws / @nut-tree-fork/nut-js /          as the checkout carries
#       onnxruntime-web
#     bin/node                                real node binary (self-contained
#                                             Mach-O) — TrackerHost's
#                                             nodeBinary() can prefer it
#     TRACKER_BUNDLE.json                     stamp: versions + fingerprint
#   <app>/Contents/Resources/EyeTracking -> EyeTracker
#                                             alias: TrackerHost today probes
#                                             resourceURL/EyeTracking — the
#                                             link keeps both names resolving
#                                             to the one payload.
#
# Modes:
#   bundle-tracker.sh <app.app>          strict — fail if the payload can't
#                                        be produced (make bundle-tracker)
#   bundle-tracker.sh --if-present <app> stage when the checkout can produce
#                                        a complete payload, else warn and
#                                        exit 0 (make stage auto-include)
#   bundle-tracker.sh --dest <dir>       write the tracker root at <dir>
#                                        instead of inside an app — the
#                                        installed-layout path
#                                        (~/Library/Application Support/
#                                        JevVoice/EyeTracking), which is
#                                        writable at runtime so calibration
#                                        files don't dirty the bundle
#
# Env: TRACKER_SRC (default <repo>/EyeTracking) picks the source checkout;
# SKIP_TRACKER_BUNDLE=1 skips only opportunistic staging.
set -euo pipefail

MODE="require"
APP=""
DEST=""
while [[ $# -gt 0 ]]; do
	case "$1" in
		--if-present) MODE="if-present"; shift ;;
		--require)    MODE="require"; shift ;;
		--app)        APP="$2"; shift 2 ;;
		--dest)       DEST="$2"; shift 2 ;;
		-h|--help)    sed -n '2,15p' "$0"; exit 0 ;;
		*)            APP="$1"; shift ;;
	esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRACKER_SRC="${TRACKER_SRC:-$ROOT/EyeTracking}"
[[ -n "$APP" ]] || APP="$ROOT/build/Jev Voice.app"
[[ -n "$DEST" ]] || DEST="$APP/Contents/Resources/EyeTracker"

log()  { echo "bundle-tracker: $*"; }
warn() { echo "bundle-tracker: WARNING — $*" >&2; }
skip() { warn "$1 — tracker payload NOT staged"; [[ "$MODE" == "if-present" ]] && exit 0; exit 1; }

if [[ "${SKIP_TRACKER_BUNDLE:-}" == "1" ]]; then
	[[ "$MODE" == "if-present" ]] || { echo "strict tracker staging cannot be skipped" >&2; exit 1; }
	log "SKIP_TRACKER_BUNDLE=1 — skipped"
	exit 0
fi

# --- preflight: can the checkout produce a complete payload? ----------------

[[ -f "$TRACKER_SRC/package.json" ]]            || skip "no tracker checkout at $TRACKER_SRC"
[[ -f "$TRACKER_SRC/electron/main.cjs" ]]       || skip "$TRACKER_SRC/electron/main.cjs missing"
[[ -f "$TRACKER_SRC/scripts/start-prod.cjs" ]]  || skip "$TRACKER_SRC/scripts/start-prod.cjs missing"
[[ -f "$TRACKER_SRC/dist/index.html" ]]         || skip "$TRACKER_SRC/dist missing — run \`make tracker-deps\` (pnpm build) first"
[[ -d "$TRACKER_SRC/node_modules/.pnpm" ]]      || skip "$TRACKER_SRC/node_modules missing — run \`make tracker-deps\` (pnpm install) first"

# NM is the realpath-resolved node_modules — the closure walk compares
# resolved paths, and TRACKER_SRC may itself be a link (app support).
NM="$(cd "$TRACKER_SRC/node_modules" && pwd -P)"
PNPM="$NM/.pnpm"

# Runtime require() roots of electron/*.cjs — the only packages the main
# process resolves: electron (the launcher + .app), ws (external API),
# @nut-tree-fork/nut-js (click control), onnxruntime-web (require.resolve'd
# for its wasm dir). Renderer deps are baked into dist/ by vite already.
SEEDS=("electron" "ws" "@nut-tree-fork/nut-js" "onnxruntime-web")
for seed in "${SEEDS[@]}"; do
	[[ -e "$NM/$seed" || -L "$NM/$seed" ]] || skip "node_modules/$seed missing in $TRACKER_SRC"
done
[[ -d "$NM/electron/dist/Electron.app" ]] || skip "Electron.app missing at $NM/electron/dist — run \`corepack pnpm rebuild electron\` in EyeTracking"

if [[ -z "$(ls -A "$TRACKER_SRC/dist/models" 2>/dev/null || true)" ]]; then
	warn "dist/models is empty — the tracker will boot but report model errors; run \`make tracker-deps\` to fetch ONNX models"
fi

# --- fingerprint: skip a restage when nothing that feeds it changed ---------
# Cheap honest check — not a hash of 800M: the inputs that actually change
# the payload (build outputs, entry points, dep closure names, model set).

fingerprint() {
	{
		# The script's own mtime — a fixed/changed bundler must restage.
		stat -f '%N %m %z' "${BASH_SOURCE[0]}" \
			"$TRACKER_SRC/package.json" \
			"$TRACKER_SRC/dist/index.html" \
			"$TRACKER_SRC/electron/main.cjs" \
			"$TRACKER_SRC/scripts/start-prod.cjs" 2>/dev/null
		stat -f '%N %m %z' "$TRACKER_SRC"/dist/models/*.onnx 2>/dev/null || true
		ls "$PNPM" 2>/dev/null || true
	} | shasum -a 256 | awk '{print $1}'
}

STAMP="$DEST/TRACKER_BUNDLE.json"
NEW_FP="$(fingerprint)"
if [[ -f "$STAMP" ]] && grep -q "\"fingerprint\": \"$NEW_FP\"" "$STAMP" 2>/dev/null; then
	log "payload at $DEST is current — nothing to do"
	exit 0
fi

# --- closure walk: every .pnpm dir the runtime seeds can reach --------------
# pnpm_dir_of <link> → echoes the .pnpm/<dir> a symlink resolves into, or
# ".pnpm/node_modules" for the hoisted store, or nothing for in-package links.

pnpm_dir_of() {
	local link="$1" target abs rest
	[[ -L "$link" ]] || return 1
	target="$(readlink "$link")"
	case "$target" in
		/*) abs="$target" ;;
		*)  abs="$(cd "$(dirname "$link")" 2>/dev/null && cd "$(dirname "$target")" 2>/dev/null && pwd -P)/$(basename "$target")" ;;
	esac
	[[ -n "$abs" && "$abs" == "$PNPM/"* ]] || return 1
	rest="${abs#"$PNPM"/}"
	case "$rest" in
		node_modules/*) echo ".pnpm/node_modules" ;;
		*/node_modules/*) echo "${rest%%/node_modules/*}" ;;
	esac
}

QUEUE="$(mktemp /tmp/bundle-tracker-queue.XXXXXX)"
SEEN="$(mktemp /tmp/bundle-tracker-seen.XXXXXX)"
trap 'rm -f "$QUEUE" "$SEEN"' EXIT
enqueue() { grep -Fqx "$1" "$SEEN" 2>/dev/null || { echo "$1" >> "$QUEUE"; echo "$1" >> "$SEEN"; }; }

for seed in "${SEEDS[@]}"; do
	pdir="$(pnpm_dir_of "$NM/$seed")" || true
	[[ -n "$pdir" ]] && enqueue "$pdir"
done

i=0
while [[ $i -lt $(wc -l < "$QUEUE" | tr -d ' ') ]]; do
	i=$((i + 1))
	D="$(sed -n "${i}p" "$QUEUE")"
	[[ "$D" == ".pnpm/node_modules" ]] && continue  # copied wholesale below
	while IFS= read -r link; do
		pdir="$(pnpm_dir_of "$link")" || true
		[[ -n "$pdir" ]] && enqueue "$pdir"
	done < <(find "$PNPM/$D/node_modules" -mindepth 1 -maxdepth 2 -type l 2>/dev/null)
done
if [[ ! -s "$SEEN" ]]; then
	skip "dependency closure resolved to nothing — is this a pnpm node_modules?"
fi
log "node_modules closure: $(wc -l < "$SEEN" | tr -d ' ') .pnpm dirs"

# --- assemble ----------------------------------------------------------------

case "$DEST" in
	"$APP"/*) [[ -d "$APP" ]] || skip "app bundle $APP not staged — run \`make stage\` first" ;;
esac
mkdir -p "$(dirname "$DEST")"
STAGE="${DEST}.staging.$$"
trap 'rm -rf "$STAGE"; rm -f "$QUEUE" "$SEEN"' EXIT
rm -rf "$STAGE"
mkdir -p "$STAGE/node_modules/.bin" "$STAGE/node_modules/.pnpm"

# --norsrc/-X: strip what can be stripped. com.apple.provenance survives any
# copy (fileproviderd owns it) — that's the documented in-checkout signing
# caveat, not something staging can fix.
cp -X "$TRACKER_SRC/package.json" "$STAGE/package.json"
ditto --norsrc "$TRACKER_SRC/electron" "$STAGE/electron"
ditto --norsrc "$TRACKER_SRC/scripts" "$STAGE/scripts"
ditto --norsrc "$TRACKER_SRC/dist" "$STAGE/dist"
# Prod resolves model SOURCES under public/ then copies them into dist/ —
# the sources are the same files vite already copied, so link them.
mkdir -p "$STAGE/public"
ln -sfn "../dist/models" "$STAGE/public/models"

# pnpm's hoisted dir (.pnpm/node_modules): Node walks UP into it when a
# package's own node_modules lacks a name — peer/hoisted transitives (e.g.
# @nut-tree-fork/shared for libnut) live there, never in a dep link, so the
# closure walk alone misses it. Always copy; it's a few K of symlinks, and
# links to unbundled dev packages just dangle untraversed.
[[ -d "$PNPM/node_modules" ]] && \
	ditto --norsrc "$PNPM/node_modules" "$STAGE/node_modules/.pnpm/node_modules"
while IFS= read -r D; do
	[[ "$D" == ".pnpm/node_modules" ]] && continue  # already copied above
	ditto --norsrc "$PNPM/$D" "$STAGE/node_modules/.pnpm/$D"
done < "$SEEN"

# Top-level links, scoped parents included — same targets as the checkout.
for seed in "${SEEDS[@]}"; do
	target="$(readlink "$NM/$seed")"
	mkdir -p "$STAGE/node_modules/$(dirname "$seed")"
	ln -sfn "$target" "$STAGE/node_modules/$seed"
done

# Clean launcher — the pnpm .bin shim exports NODE_PATH pinned to this
# checkout's absolute path, which would make a shipped bundle resolve modules
# out of the dev tree. The shim only needs to exec cli.js beside it.
cat > "$STAGE/node_modules/.bin/electron" <<'EOF'
#!/bin/sh
# Relocatable electron launcher (replaces the pnpm shim — see bundle-tracker.sh).
exec "$(dirname "$0")/../../bin/node" "$(dirname "$0")/../electron/cli.js" "$@"
EOF
chmod +x "$STAGE/node_modules/.bin/electron"

# onnxruntime-web is require.resolve'd only for its wasm assets dir; the
# wasm/mjs payloads the renderer fetches already live in dist/runtime-assets.
# Keep the package minimal: manifest (exports map) + the resolved file.
ORT_SEED_LINK="$STAGE/node_modules/onnxruntime-web"
if [[ -L "$ORT_SEED_LINK" ]]; then
	ORT_PKG="$STAGE/node_modules/.pnpm/$(readlink "$NM/onnxruntime-web" | sed -n 's|.*\.pnpm/\([^/]*\)/node_modules/.*|\1|p')/node_modules/onnxruntime-web"
	ORT_RESOLVED=""
	if command -v node >/dev/null 2>&1; then
		ORT_RESOLVED="$(cd "$TRACKER_SRC" && node -e 'try{console.log(require.resolve("onnxruntime-web/wasm"))}catch(e){process.exit(1)}' 2>/dev/null || true)"
	fi
	if [[ -n "$ORT_RESOLVED" && -f "$ORT_RESOLVED" && -d "$ORT_PKG" ]]; then
		mkdir -p "$STAGE/dist/runtime-assets/onnxruntime-web"
		cp -X "$(dirname "$ORT_RESOLVED")"/ort-wasm-simd-threaded.*.{wasm,mjs} \
			"$(dirname "$ORT_RESOLVED")"/ort-wasm-simd-threaded.{wasm,mjs} "$STAGE/dist/runtime-assets/onnxruntime-web/"
		find "$ORT_PKG/dist" -type f -delete 2>/dev/null || true
		mkdir -p "$ORT_PKG/dist"
		cp -X "$ORT_RESOLVED" "$ORT_PKG/dist/$(basename "$ORT_RESOLVED")"
		log "onnxruntime-web pruned to manifest + $(basename "$ORT_RESOLVED") (runtime assets ship in dist/)"
	fi
fi

# A bundled node removes the last external dependency — TrackerHost resolves
# nodeBinary() and can prefer <trackerDir>/bin/node once it knows to look.
NODE_BIN=""
for c in "$(command -v node 2>/dev/null || true)" /opt/homebrew/bin/node /usr/local/bin/node; do
	[[ -n "$c" && -x "$c" ]] && NODE_BIN="$c" && break
done
if [[ -n "$NODE_BIN" ]]; then
	NODE_REAL="$(python3 -c 'import os,sys;print(os.path.realpath(sys.argv[1]))' "$NODE_BIN")"
	mkdir -p "$STAGE/bin"
	cp -X "$NODE_REAL" "$STAGE/bin/node"
fi

# TCC: every bundled plist needs NSCameraUsageDescription or a camera request
# attributed to an unpatched helper is a SIGABRT, not a prompt. Same stamp
# EyeTracking/scripts/patch-electron-app.sh applies to the dev copy, done
# here on the STAGED bundle so it works even when tracker-deps was skipped.
# Fast path first: a checkout that already ran tracker-deps carries patched
# plists and a valid seal — nothing to do (and an in-checkout re-sign would
# hit the provenance detritus tripwire anyway).
STAGED_EAPP="$STAGE/node_modules/electron/dist/Electron.app"
[[ -d "$STAGED_EAPP" ]] || STAGED_EAPP="$STAGE/node_modules/.pnpm/electron@"*/node_modules/electron/dist/Electron.app
if [[ -d "$STAGED_EAPP" ]]; then
	USAGE="Jev Voice uses the camera for eye tracking."
	PRODUCT="Jev Voice Eye Tracking"
	patched=1
	for plist in "$STAGED_EAPP/Contents/Info.plist" "$STAGED_EAPP"/Contents/Frameworks/Electron\ Helper*.app/Contents/Info.plist; do
		[[ -f "$plist" ]] || continue
		/usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" "$plist" >/dev/null 2>&1 || patched=0
	done
	if [[ $patched == 1 ]] && codesign -v "$STAGED_EAPP" >/dev/null 2>&1; then
		log "Electron.app already patched + sealed — kept as-is"
	else
		for plist in "$STAGED_EAPP/Contents/Info.plist" "$STAGED_EAPP"/Contents/Frameworks/Electron\ Helper*.app/Contents/Info.plist; do
			[[ -f "$plist" ]] || continue
			/usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" "$plist" >/dev/null 2>&1 \
				|| /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string $USAGE" "$plist"
		done
		/usr/libexec/PlistBuddy -c "Set :CFBundleName $PRODUCT" "$STAGED_EAPP/Contents/Info.plist" 2>/dev/null \
			|| /usr/libexec/PlistBuddy -c "Add :CFBundleName string $PRODUCT" "$STAGED_EAPP/Contents/Info.plist"
		# Plist edits break the previous seal; ad-hoc is correct here — the
		# outer sign-app.sh re-signs every Mach-O under Resources anyway.
		codesign --force --deep -s - "$STAGED_EAPP" >/dev/null 2>&1 \
			&& log "Electron.app: usage descriptions stamped, ad-hoc re-signed" \
			|| warn "codesign of staged Electron.app failed (in-checkout provenance detritus is expected here) — outer signing covers it"
	fi
else
	warn "no Electron.app in the staged payload — the tracker cannot launch"
fi

python3 - "$STAGE/TRACKER_BUNDLE.json" "$NEW_FP" "$TRACKER_SRC" <<'PYEOF'
import json, os, sys, time
stamp, fp, src = sys.argv[1], sys.argv[2], sys.argv[3]
def pkg_ver(p):
    try:
        return json.load(open(p))["version"]
    except Exception:
        return None
root = os.path.dirname(stamp)
nm = os.path.join(src, "node_modules")
def read_ver(name):
    try:
        return pkg_ver(os.path.join(nm, name, "package.json"))
    except Exception:
        return None
json.dump({
    "name": "EyeTracker",
    "layout": 1,
    "trackerVersion": pkg_ver(os.path.join(src, "package.json")),
    "electronVersion": read_ver("electron"),
    "nodeVersion": None,
    "stagedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    "fingerprint": fp,
}, open(stamp, "w"), indent=2)
PYEOF

xattr -cr "$STAGE" 2>/dev/null || true
# Dev-package hoisted links (chai, @types, rolldown…) intentionally dangle
# inside the bundle — runtime never traverses them, but a dangling symlink
# inside a signed .app fails `codesign --verify --deep --strict` outright.
find "$STAGE" -type l ! -exec test -e {} \; -delete 2>/dev/null || true
rm -rf "$DEST"
mv "$STAGE" "$DEST"

# Inside an app bundle also publish the EyeTracking alias — TrackerHost's
# current resolver probes resourceURL/EyeTracking; EyeTracker is the name
# the bundled-resolution seam uses.
case "$DEST" in
	*/Contents/Resources/EyeTracker)
		alias_dir="$(dirname "$DEST")/EyeTracking"
		if [[ ! -e "$alias_dir" || -L "$alias_dir" ]]; then
			ln -sfn "EyeTracker" "$alias_dir"
		fi
		;;
esac

log "staged $(du -sh "$DEST" | cut -f1) at $DEST"
if [[ -z "$NODE_BIN" ]]; then
	warn "no node binary found — payload relies on TrackerHost finding system node"
fi
exit 0
