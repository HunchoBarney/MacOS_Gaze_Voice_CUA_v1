#!/usr/bin/env bash
# Fetches the tracker's model files into public/models, hash-verified.
# Default: the MediaPipe Face Landmarker bundle (Apache-2.0). --legacy also
# fetches the unlicensed ONNX weights the --legacy-models A/B path loads;
# they are never fetched, bundled or loaded by default.
set -euo pipefail
cd "$(dirname "$0")/.."
manifests=("$PWD/scripts/required-models.sha256")
if [[ "${1:-}" == "--legacy" ]]; then
  manifests+=("$PWD/scripts/legacy-models.sha256")
fi
mkdir -p public/models
cd public/models
url_for() {
  case "$1" in
    face_landmarker.task) echo "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/1/face_landmarker.task" ;;
    *) echo "https://github.com/PINTO0309/screen-eye-tracking/releases/download/onnx/$1" ;;
  esac
}
for manifest in "${manifests[@]}"; do
  while read -r digest name; do
    if [[ ! -f "$name" ]]; then
      tmp="$(mktemp "./$name.XXXXXX")"
      trap 'rm -f "$tmp"' EXIT
      curl -fL --retry 3 -o "$tmp" "$(url_for "$name")"
      printf '%s  %s\n' "$digest" "$tmp" | shasum -a 256 -c -
      mv "$tmp" "$name"
      chmod 644 "$name"
      trap - EXIT
    fi
  done < "$manifest"
  shasum -a 256 -c "$manifest"
done
