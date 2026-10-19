#!/usr/bin/env bash
# The one serialized verification runner (PLANS.md §4). Writers never
# build a half-frozen tree — every build/test goes through this script,
# in order, failing on the first red step.
#
# Usage: scripts/verification-lane.sh [swift|eyes|all]   (default: all)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

scope="${1:-all}"

run_swift() {
  echo "== [1/3] swift test =="
  swift test
}

run_eyes() {
  echo "== [2/3] EyeTracking typecheck =="
  (cd EyeTracking && npm run typecheck)
  echo "== [3/3] EyeTracking vitest =="
  (cd EyeTracking && npx vitest run)
}

case "$scope" in
  swift) run_swift ;;
  eyes) run_eyes ;;
  all) run_swift; run_eyes ;;
  *) echo "usage: $0 [swift|eyes|all]" >&2; exit 2 ;;
esac

echo "verification lane green"
