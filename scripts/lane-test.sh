#!/bin/bash
# Run a test command in the crew's one long-lived build-lane checkout, so every
# thread reuses the same warm .build instead of building its own worktree cold.
#
#   scripts/lane-test.sh                          make test on this worktree's files
#   scripts/lane-test.sh swift test --filter X    any command, run in the lane
#
# It takes the lane lock, waits for any other heavy build to finish, mirrors
# this worktree's files (committed or not, without .git and build products)
# into the lane checkout, and runs the command there. Files are compared by
# content and copied without their timestamps, so an unchanged file keeps the
# lane's timestamp and the build stays incremental against whatever ran last.
set -uo pipefail

LANE_HOME=${JARVIS_LANE_HOME:-$HOME/.capy/work/build-lane}
LANE=$LANE_HOME/checkout
LOCK=$LANE_HOME/lock
TIMEOUT=${JARVIS_LANE_TIMEOUT:-3600}
SRC=$(git rev-parse --show-toplevel) || exit 2
[ $# -gt 0 ] || set -- make test

take_lock() {
    mkdir -p "$LANE_HOME"
    if mkdir "$LOCK" 2>/dev/null; then echo $$ >"$LOCK/pid"; return 0; fi
    local holder
    holder=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then return 1; fi
    rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

waited=0
until take_lock; do
    [ "$waited" -ge "$TIMEOUT" ] && { echo "lane-test: lane held by pid $(cat "$LOCK/pid" 2>/dev/null) for $TIMEOUT s" >&2; exit 1; }
    sleep 15; waited=$((waited + 15))
done
trap '[ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"' EXIT
while pgrep -x 'swift-build|swift-test|swift-frontend|xcodebuild' >/dev/null; do
    [ "$waited" -ge "$TIMEOUT" ] && { echo "lane-test: another build held the lane for $TIMEOUT s" >&2; exit 1; }
    sleep 15; waited=$((waited + 15))
done
[ "$waited" -gt 0 ] && echo "lane-test: waited $waited s for the lane"

mkdir -p "$LANE"
rsync -rlpD --checksum --delete \
    --exclude=/.git --exclude=/.build/ --exclude=/build/ \
    --exclude=node_modules/ --exclude=/EyeTracking/dist/ \
    "$SRC/" "$LANE/" || exit 1
echo "lane-test: $SRC at $(git -C "$SRC" rev-parse --short HEAD)$(git -C "$SRC" diff --quiet HEAD -- || echo ' plus uncommitted changes') → $LANE"
cd "$LANE" && "$@"
