#!/usr/bin/env bash
# TCC survival patch for the dev Electron.app.
#
# macOS attributes a camera request to whichever bundled process TCC sees —
# on an unpatched Electron.app that attribution can land on a helper
# (Electron Helper*.app), whose Info.plist has no NSCameraUsageDescription.
# A camera request with no usage string is not a denial; it is a native
# SIGABRT. Stamping the key into every bundled plist turns orphaned or
# self-attributed camera requests into a normal user prompt, and renaming
# the main bundle makes that prompt show a real product name.
#
# Plist edits invalidate the seal, so the bundle is re-signed ad-hoc. In
# this iCloud-synced Documents checkout the seal CANNOT be written in
# place — fileproviderd/FinderInfo xattrs inside the bundle trip codesign's
# "detritus not allowed" refusal (com.apple.provenance is not even
# removable). The reliable path is: stage a copy in /tmp (xattr-free), patch
# + sign + verify there, then swap it back via rename.
#
# Idempotent: when every key is present and the signature already verifies,
# the script is a no-op fast path.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="node_modules/electron/dist/Electron.app"
USAGE="Jev Voice uses the camera for eye tracking."
PRODUCT="Jev Voice Eye Tracking"

if [[ ! -d "$APP" ]]; then
  echo "patch-electron-app: $APP not found — run \`pnpm install\` first." >&2
  exit 1
fi

# add_usage_key <plist> — append NSCameraUsageDescription only when absent.
add_usage_key() {
  local plist="$1"
  if /usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" "$plist" >/dev/null 2>&1; then
    return 0
  fi
  /usr/libexec/PlistBuddy -c "Add :NSCameraUsageDescription string $USAGE" "$plist"
  echo "  +NSCameraUsageDescription: $plist"
}

is_fully_patched() {
  local root="$1"
  /usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" "$root/Contents/Info.plist" >/dev/null 2>&1 || return 1
  local helper_plist
  for helper_plist in "$root"/Contents/Frameworks/Electron\ Helper*.app/Contents/Info.plist; do
    [[ -e "$helper_plist" ]] || continue
    /usr/libexec/PlistBuddy -c "Print :NSCameraUsageDescription" "$helper_plist" >/dev/null 2>&1 || return 1
  done
  [[ "$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$root/Contents/Info.plist" 2>/dev/null || true)" == "$PRODUCT" ]]
}

# Fast path — nothing to patch and the seal is intact.
if is_fully_patched "$APP" && codesign -v "$APP" >/dev/null 2>&1; then
  echo "patch-electron-app: already patched and signed — nothing to do."
  exit 0
fi

# Stage in /tmp: same-volume rename back keeps this atomic, and /tmp files
# carry none of the sync-daemon xattrs that make codesign refuse the seal.
STAGE="$(mktemp -d /tmp/electron-app-patch.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
cp -RX "$APP" "$STAGE/Electron.app"
PATCHED="$STAGE/Electron.app"

add_usage_key "$PATCHED/Contents/Info.plist"
for helper_plist in "$PATCHED"/Contents/Frameworks/Electron\ Helper*.app/Contents/Info.plist; do
  [[ -e "$helper_plist" ]] || continue
  add_usage_key "$helper_plist"
done

current_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "$PATCHED/Contents/Info.plist" 2>/dev/null || true)"
if [[ "$current_name" != "$PRODUCT" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleName $PRODUCT" "$PATCHED/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleName string $PRODUCT" "$PATCHED/Contents/Info.plist"
  echo "  CFBundleName: ${current_name:-<unset>} -> $PRODUCT"
fi

# Any plist mutation breaks the previous seal; without the re-sign the
# patched bundle refuses to launch at all.
codesign --force --deep -s - "$PATCHED"
codesign -v "$PATCHED"

# Same-directory renames are atomic; keep the original as a backup so a
# failed install can never leave node_modules without an Electron.app.
BACKUP="${APP}.pre-patch-backup"
rm -rf "$BACKUP"
mv "$APP" "$BACKUP"
if mv "$PATCHED" "$APP"; then
  rm -rf "$BACKUP"
else
  mv "$BACKUP" "$APP" 2>/dev/null || true
  echo "patch-electron-app: install of the patched bundle failed — original restored." >&2
  exit 1
fi
trap - EXIT
rmdir "$STAGE" 2>/dev/null || true

codesign -v "$APP"
echo "patch-electron-app: patched, re-signed, and installed $APP"
