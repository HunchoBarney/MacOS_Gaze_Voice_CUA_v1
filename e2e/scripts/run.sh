#!/usr/bin/env bash
# Runs Jarvis's e2e flows on a signed build, then puts the Mac back the way
# it was: Jarvis's settings and Keychain entries, apps it had running, the
# output volume, the Fn key and every temporary file. Run it through make e2e,
# which holds scripts/with-desktop-lock.py for the whole run.
#
#   JARVIS_E2E_APP      the signed Jarvis.app to test (default ~/jarvis-local/Jarvis.app)
#   JARVIS_E2E_TRIGGER  fn (default) holds Fn; wake starts turns with "Hey Jarvis"
#   JARVIS_E2E_AUDIO    speakers (default) plays the lines aloud into the built-in
#                       microphone; blackhole routes them through BlackHole 2ch
#   JARVIS_E2E_ONLY     run one flow: first-run, fn-command, show-names-click,
#                       screen-question or wake-word
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
bundle=com.karanvirkang.jarvis
app=${JARVIS_E2E_APP:-$HOME/jarvis-local/Jarvis.app}
trigger=${JARVIS_E2E_TRIGGER:-fn}
audio=${JARVIS_E2E_AUDIO:-speakers}
only=${JARVIS_E2E_ONLY:-}
started=$(date +%s)
die() { echo "e2e: $*" >&2; exit 2; }

# --- Preflight: nothing changes on the Mac until all of these pass. -------
[ "$(uname -s)" = Darwin ] || die "macOS only"
[ -x "$here/node_modules/.bin/e2e" ] || die "not installed: make e2e-install (only after the owner's go)"
[ -d "$app" ] || die "no Jarvis at $app; set JARVIS_E2E_APP to a signed build"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")" = "$bundle" ] \
    || die "$app is not $bundle"
codesign --verify --strict "$app" || die "$app fails codesign --verify"
case "$trigger" in fn | wake) ;; *) die "JARVIS_E2E_TRIGGER is fn or wake" ;; esac
case "$audio" in
speakers)
    # The lines go out of the built-in speakers and into the built-in microphone.
    routes=$(system_profiler SPAudioDataType -json | python3 -c '
import json, sys
items = [d for g in json.load(sys.stdin)["SPAudioDataType"] for d in g.get("_items", [])]
def default(key):
    return next((d for d in items if d.get(key) == "spaudio_yes"), {})
for key in ("coreaudio_default_audio_output_device", "coreaudio_default_audio_input_device"):
    d = default(key)
    print(d.get("coreaudio_device_transport", "") == "coreaudio_device_type_builtin", d.get("_name", "none"))
')
    while read -r builtin name; do
        [ "$builtin" = True ] || die "the default audio devices must be the Mac's own speakers and microphone (now: $name)"
    done <<<"$routes"
    export JARVIS_E2E_MICROPHONE=""
    ;;
blackhole)
    system_profiler SPAudioDataType | grep -q "BlackHole 2ch" || die "BlackHole 2ch is not installed"
    export JARVIS_E2E_MICROPHONE=BlackHole2ch_UID JARVIS_E2E_SAY_DEVICE="BlackHole 2ch"
    ;;
*) die "JARVIS_E2E_AUDIO is speakers or blackhole" ;;
esac
if [ "$trigger" = fn ] && [ "$(defaults read com.apple.HIToolbox AppleFnUsageType 2>/dev/null || echo 0)" != 0 ]; then
    echo "e2e: note: Keyboard → \"Press 🌐 key to\" is not \"Do Nothing\"; a held Fn may also open that" >&2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/jarvis-e2e.XXXXXX")
helper="$tmp/e2e-helper"
board="$tmp/Jarvis E2E Board.app"

# --- Save what the run can change. -----------------------------------------
had_defaults=0
if defaults export "$bundle" "$tmp/defaults.plist" 2>/dev/null; then had_defaults=1; fi
had_keys=" "
for account in typesafeAPIKey openAIAPIKey; do
    if security find-generic-password -s "$bundle" -a "$account" >/dev/null 2>&1; then had_keys="$had_keys$account "; fi
done
volume=$(osascript -e 'output volume of (get volume settings)')
muted=$(osascript -e 'output muted of (get volume settings)')
calculator_was_open=0

restore() {
    status=$?
    trap - EXIT INT TERM
    set +e
    echo "e2e: restoring the Mac"
    if [ -x "$helper" ]; then
        "$helper" fn up
        "$helper" quit "$bundle" 15
        "$helper" quit com.karanvirkang.jarvis.e2e-board 5
        "$helper" quit com.apple.calculator 5
    fi
    [ -d "$board" ] && /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$board" 2>/dev/null
    # import merges, so clear the domain first.
    defaults delete "$bundle" 2>/dev/null
    [ "$had_defaults" = 1 ] && defaults import "$bundle" "$tmp/defaults.plist"
    for account in typesafeAPIKey openAIAPIKey; do
        case "$had_keys" in *" $account "*) ;; *) security delete-generic-password -s "$bundle" -a "$account" >/dev/null 2>&1 ;; esac
    done
    osascript -e "set volume output volume $volume" -e "set volume output muted $muted"
    [ "$calculator_was_open" = 1 ] && open -g -b com.apple.calculator
    if [ -s "$tmp/owner-jarvis" ]; then
        while IFS= read -r path; do [ -n "$path" ] && open -g "$path"; done <"$tmp/owner-jarvis"
    fi
    rm -rf "$tmp"
    echo "e2e: done in $(($(date +%s) - started)) s; report in $here/.e2e"
    exit "$status"
}
trap restore EXIT
trap 'exit 130' INT TERM

# --- Build the helper and the board (a few seconds). -----------------------
xcrun swiftc -O -o "$helper" "$here/tools/MacHelper.swift"
mkdir -p "$board/Contents/MacOS"
cp "$here/fixtures/Board-Info.plist" "$board/Contents/Info.plist"
xcrun swiftc -O -o "$board/Contents/MacOS/Board" "$here/fixtures/Board.swift"
codesign --force --sign - "$board" >/dev/null 2>&1

# --- Clear the stage: Jarvis allows one copy, and the flows open Calculator. --
"$helper" paths "$bundle" >"$tmp/owner-jarvis"
if [ -s "$tmp/owner-jarvis" ]; then
    echo "e2e: quitting the running Jarvis; it reopens when the run ends"
    "$helper" quit "$bundle" 15 || [ "$("$helper" count "$bundle")" = 0 ] || die "the running Jarvis didn't quit"
fi
if [ "$("$helper" count com.apple.calculator)" != 0 ]; then
    calculator_was_open=1
    "$helper" quit com.apple.calculator 5
fi
if [ "$audio" = speakers ]; then osascript -e 'set volume output volume 50' -e 'set volume output muted false'; fi

# --- Run. Each target is one e2e run; a failure doesn't stop the rest. -----
export JARVIS_E2E_APP="$app" JARVIS_E2E_TRIGGER="$trigger" JARVIS_E2E_TMP="$tmp" \
    JARVIS_E2E_HELPER="$helper" JARVIS_E2E_BOARD="$board" E2E_TELEMETRY_DISABLED=1
cd "$here"
failed=0
flow() { # flow <target> <name>...
    local target=$1 name files=()
    shift
    for name in "$@"; do
        if [ -z "$only" ] || [ "$only" = "$name" ]; then files+=("tests/$name.e2e.ts"); fi
    done
    [ ${#files[@]} -gt 0 ] || return 0
    echo "e2e: $target: ${files[*]}"
    node_modules/.bin/e2e run --target "$target" "${files[@]}" || failed=1
}
flow first-run first-run
if [ "$trigger" = fn ]; then
    flow jarvis fn-command show-names-click screen-question
else
    flow jarvis-standby show-names-click screen-question
fi
flow jarvis-standby wake-word
exit "$failed"
