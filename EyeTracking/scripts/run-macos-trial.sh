#!/bin/bash
set -euo pipefail

trial_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
trial_app="${TRIAL_APP_PATH:-$trial_root/../build/Screen Eye Tracking Trial.app}"
# HD-vs-VGA A/B protocol: flip --camera-resolution to HD and rerun
# `--accuracy-test` on the same 9-point protocol. Adopt HD only if the median
# error improves AND `inference_ms` p95 stays under ~80ms on this machine
# (--enable-inference-time prints it). Record the winner here when measured.
run_args=(
  --runtime onnxweb
  --display-size-inch 14.2
  --camera-resolution VGA \
  --camera-fov 62
  --web-inference-worker dedicated
  --gaze-projection-mode binocular-screen
  --calibration-file "$trial_root/.gaze_calibration.binocular-screen.json"
  --enable-inference-time
)

if [[ "${1:-}" == "--calibrate" ]]; then
  run_args+=(--calibrate)
  shift
fi

if [[ "${1:-}" == "--accuracy-test" ]]; then
  run_args+=(--accuracy-test)
  shift
fi

if [[ "${1:-}" == "--show-preview" ]]; then
  run_args+=(--show-preview)
  shift
fi

if [[ "$#" -ne 0 ]]; then
  echo "Usage: $0 [--calibrate] [--accuracy-test] [--show-preview]" >&2
  exit 2
fi

if [[ ! -x "$trial_app/Contents/MacOS/Electron" ]]; then
  echo "Trial app is missing. Run scripts/package-macos-trial.sh first." >&2
  exit 1
fi

cd "$trial_root"
GAZE_ELECTRON_BIN="$trial_app/Contents/MacOS/Electron" node scripts/dev.cjs "${run_args[@]}"
