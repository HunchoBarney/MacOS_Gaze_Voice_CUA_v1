#!/bin/bash
set -euo pipefail

trial_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source_app="$trial_root/node_modules/electron/dist/Electron.app"
bundle_id="com.karanvirkang.screeneyetrackingtrial"
trial_name="Screen Eye Tracking Trial"
camera_description="Screen Eye Tracking Trial uses the built-in camera to estimate gaze locally on this Mac. Camera video is not connected to Jev."
trial_app="${1:-$trial_root/../build/Screen Eye Tracking Trial.app}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This packager only supports macOS." >&2
  exit 1
fi

if [[ ! -d "$source_app" ]]; then
  (cd "$trial_root" && corepack pnpm rebuild electron)
fi

if [[ ! -d "$source_app" ]]; then
  echo "Pinned Electron.app is missing after rebuild." >&2
  exit 1
fi

if [[ -e "$trial_app" ]]; then
  echo "Refusing to overwrite existing path: $trial_app" >&2
  exit 1
fi

mkdir -p "$(dirname "$trial_app")"
ditto "$source_app" "$trial_app"

main_plist="$trial_app/Contents/Info.plist"
plutil -replace CFBundleIdentifier -string "$bundle_id" "$main_plist"
plutil -replace CFBundleName -string "$trial_name" "$main_plist"
plutil -replace CFBundleDisplayName -string "$trial_name" "$main_plist"
plutil -replace NSCameraUsageDescription -string "$camera_description" "$main_plist"

set_helper_identity() {
  local helper_path="$1"
  local helper_bundle_id="$2"
  local helper_name="$3"
  local helper_plist="$trial_app/Contents/Frameworks/$helper_path/Contents/Info.plist"
  plutil -replace CFBundleIdentifier -string "$helper_bundle_id" "$helper_plist"
  plutil -replace CFBundleName -string "$helper_name" "$helper_plist"
}

set_helper_identity "Electron Helper.app" "$bundle_id.helper" "$trial_name Helper"
set_helper_identity "Electron Helper (GPU).app" "$bundle_id.helper.GPU" "$trial_name Helper (GPU)"
set_helper_identity "Electron Helper (Renderer).app" "$bundle_id.helper.Renderer" "$trial_name Helper (Renderer)"
set_helper_identity "Electron Helper (Plugin).app" "$bundle_id.helper.Plugin" "$trial_name Helper (Plugin)"

# The trial has no Developer ID certificate. Ad-hoc sign the copied bundle so
# its changed property lists and nested helper identities verify together.
codesign --force --deep --sign - --identifier "$bundle_id" "$trial_app"
codesign --verify --deep --strict --verbose=2 "$trial_app"

echo "Packaged: $trial_app"
echo "Bundle ID: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$main_plist")"
echo "Camera description: $(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$main_plist")"
