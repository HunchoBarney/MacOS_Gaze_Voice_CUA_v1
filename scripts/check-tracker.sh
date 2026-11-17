#!/usr/bin/env bash
# Report how the eye tracker resolves for a Jev Voice.app bundle — the same
# candidate order TrackerHost.trackerDirectory() uses:
#
#   1. JARVIS_EYE_TRACKER_DIR           explicit env override
#   2. <app>/../../EyeTracking          dev sibling checkout
#   3. ~/Library/Application Support/JevVoice/EyeTracking
#                                       installed layout (symlink or copy)
#   4. <app>/Contents/Resources/EyeTracker
#                                       bundled payload (bundle-tracker.sh;
#                                       EyeTracking symlink there aliases it)
#
# "resolves" per the Swift side = package.json exists; completeness of the
# payload (built renderer, launcher, models, electron binary) is reported so
# a hollow directory shows as degraded rather than healthy.
#
# Usage: check-tracker.sh [Jev Voice.app] [--brief]
# Exit:  0 = at least one candidate resolves to a complete-enough payload,
#        1 = nothing resolvable (caller may warn without failing the build).
set -euo pipefail

BRIEF=0
APP=""
for arg in "$@"; do
	case "$arg" in
		--brief) BRIEF=1 ;;
		*) APP="$arg" ;;
	esac
done
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -n "$APP" ]] || APP="$ROOT/build/Jev Voice.app"

# probe <label> <dir> — prints one verdict line; echoes "ok" on stdout-feed
RESOLVED=""
DEGRADED=""

probe() {
	local label="$1" dir="$2" status="missing" detail=""
	# Display paths absolutized when they exist — relative forms like
	# ./EyeTracking read as noise in the report. Resolve the parent only so
	# a symlinked dir still shows its own (literal) path.
	if [[ -e "$dir" || -L "$dir" ]]; then
		dir="$(cd "$(dirname "$dir")" 2>/dev/null && pwd -P)/$(basename "$dir")"
	fi
	if [[ -e "$dir/package.json" ]]; then
		status="ok"
		local missing=()
		[[ -f "$dir/scripts/start-prod.cjs" ]] || missing+=("scripts/start-prod.cjs")
		[[ -f "$dir/dist/index.html" ]] || missing+=("dist/index.html")
		[[ -x "$dir/node_modules/.bin/electron" || -L "$dir/node_modules/.bin/electron" ]] || missing+=("node_modules/.bin/electron")
		if ! ls "$dir"/node_modules/electron/dist/Electron.app >/dev/null 2>&1 \
			&& ! ls "$dir"/node_modules/.pnpm/electron@*/node_modules/electron/dist/Electron.app >/dev/null 2>&1; then
			missing+=("Electron.app")
		fi
		local nmodels
		nmodels="$(find "$dir/dist/models" -name '*.onnx' 2>/dev/null | wc -l | tr -d ' ')"
		[[ "$nmodels" == "0" ]] && missing+=("dist/models/*.onnx")
		[[ -x "$dir/bin/node" ]] || detail+=" (no bundled node — needs system node)"
		if [[ ${#missing[@]} -gt 0 ]]; then
			status="degraded"
			detail=" missing:${missing[*]/#/ }$detail"
		else
			detail=" complete${detail}"
		fi
		if [[ -L "$dir" ]]; then
			detail+=" [symlink -> $(readlink "$dir")]"
		elif [[ -f "$dir/TRACKER_BUNDLE.json" ]]; then
			detail+=" [bundled $(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("stagedAt","?"))' "$dir/TRACKER_BUNDLE.json" 2>/dev/null || echo '?')]"
		fi
		if [[ "$status" == "ok" ]]; then RESOLVED="${RESOLVED:-$label}";
		elif [[ "$status" == "degraded" ]]; then DEGRADED="${DEGRADED:-$label}"; fi
	fi
	if [[ "$BRIEF" == "1" ]]; then
		[[ "$status" == "missing" ]] || echo "  $status  $label"
	else
		printf '  %-9s %s\n            %s%s\n' "$status" "$label" "$dir" "$detail"
	fi
}

[[ "$BRIEF" == "1" ]] || echo "check-tracker: $APP"

probe "env:JARVIS_EYE_TRACKER_DIR" "${JARVIS_EYE_TRACKER_DIR:-/nonexistent-unset}"
probe "sibling checkout" "$(dirname "$(dirname "$APP")")/EyeTracking"
probe "app-support install" "$HOME/Library/Application Support/JevVoice/EyeTracking"
probe "bundled EyeTracker" "$APP/Contents/Resources/EyeTracker"
[[ -L "$APP/Contents/Resources/EyeTracking" ]] \
	&& probe "bundled EyeTracking (alias)" "$APP/Contents/Resources/EyeTracking"

if [[ -n "$RESOLVED" ]]; then
	echo "check-tracker: resolved via $RESOLVED"
	exit 0
elif [[ -n "$DEGRADED" ]]; then
	echo "check-tracker: only a degraded payload resolves ($DEGRADED) — gaze will fail at runtime" >&2
	exit 0  # resolvable at the package.json level; honest-but-present
else
	echo "check-tracker: no tracker payload resolves — gaze verbs will refuse" >&2
	exit 1
fi
