#!/bin/bash
# The crew's build lane, served in order.
#
#   lane.sh                         make test on the caller's worktree, in the lane checkout
#   lane.sh <command...>            any command, in the lane checkout
#   lane.sh --status                holder, its command and age, then the queue in order
#
# Waiters take numbered tickets and run strictly in ticket order;
# LANE_PRIORITY=high (local CI, main-blocking jobs) goes ahead of every
# normal ticket but never preempts a running job. The job at the head of the
# queue also takes the mkdir lock scripts/lane-test.sh uses, so old-style
# callers see the lane as busy, and it waits for other heavy builds
# (pgrep -x) before it starts. Tickets and the lock are released on every
# exit; a ticket or lock whose process is gone is reclaimed.
#
# Like scripts/lane-test.sh it mirrors the caller's worktree into the one
# long-lived checkout and runs the command there. LANE_NO_MIRROR=1 runs the
# command where it was started instead (local CI's own checkout).
#
#   JARVIS_LANE_TIMEOUT   seconds to wait for the lane (default 3600)
#   JARVIS_LANE_HOME      lane checkout and lock (default ~/.capy/work/build-lane)
#   LANE_STATE            queue directory (default ~/.capy/work/lane/queue)
set -uo pipefail

LANE_HOME=${JARVIS_LANE_HOME:-$HOME/.capy/work/build-lane}
LANE=$LANE_HOME/checkout
LOCK=$LANE_HOME/lock
QUEUE=${LANE_STATE:-$HOME/.capy/work/lane/queue}
TIMEOUT=${JARVIS_LANE_TIMEOUT:-3600}
POLL=${LANE_POLL:-2}
BUILDS=${LANE_BUILDS:-'swift-build|swift-test|swift-frontend|xcodebuild'}

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }
field() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
age() { local s=$(( $(date +%s) - $1 )); printf '%dm%02ds' $((s / 60)) $((s % 60)); }
tickets() { ls "$QUEUE" 2>/dev/null | grep -E '^[01]-' | sort; }

# Remove tickets whose waiter is gone.
prune() {
    local t
    for t in $(tickets); do
        local pid; pid=$(field "$QUEUE/$t" pid)
        [ -n "$pid" ] && ! alive "$pid" && rm -f "$QUEUE/$t"
    done
}

status() {
    mkdir -p "$QUEUE"
    prune
    local holder; holder=$(cat "$LOCK/pid" 2>/dev/null)
    if alive "$holder"; then
        local cmd started
        cmd=$(cat "$LOCK/cmd" 2>/dev/null || ps -o command= -p "$holder")
        started=$(cat "$LOCK/started" 2>/dev/null)
        if [ -n "$started" ]; then
            echo "holder: pid $holder, running $(age "$started"): $cmd"
        else
            echo "holder: pid $holder (old-style lane-test.sh), up $(ps -o etime= -p "$holder" | tr -d ' '): $cmd"
        fi
    else
        echo "holder: none"
    fi
    local n=0 t prio
    for t in $(tickets); do
        [ "$(field "$QUEUE/$t" pid)" = "$holder" ] && continue
        n=$((n + 1))
        prio=normal; [ "${t%%-*}" = 0 ] && prio=high
        echo "$n. ticket $((10#${t#*-})) ($prio), pid $(field "$QUEUE/$t" pid), waiting $(age "$(field "$QUEUE/$t" queued)"): $(field "$QUEUE/$t" cmd)"
    done
    [ "$n" -eq 0 ] && echo "queue: empty"
    return 0
}

[ "${1:-}" = "--status" ] && { status; exit 0; }

if [ "${LANE_NO_MIRROR:-0}" = 1 ]; then
    SRC=$PWD
else
    SRC=$(git rev-parse --show-toplevel) || exit 2
fi
[ $# -gt 0 ] || set -- make test

# Take a ticket: a short mkdir mutex guards the counter.
mkdir -p "$QUEUE"
spins=0
until mkdir "$QUEUE/.mutex" 2>/dev/null; do
    holder=$(cat "$QUEUE/.mutex/pid" 2>/dev/null)
    if { [ -n "$holder" ] && ! alive "$holder"; } \
        || { [ -z "$holder" ] && [ $(( $(date +%s) - $(stat -f %m "$QUEUE/.mutex" 2>/dev/null || date +%s) )) -gt 5 ]; }; then
        rm -rf "$QUEUE/.mutex"; continue
    fi
    spins=$((spins + 1))
    [ "$spins" -gt 600 ] && { echo "lane: queue mutex stuck" >&2; exit 1; }
    sleep 0.1
done
echo $$ >"$QUEUE/.mutex/pid"
seq=$(( $(cat "$QUEUE/.seq" 2>/dev/null || echo 0) + 1 ))
echo "$seq" >"$QUEUE/.seq"
prio=1; [ "${LANE_PRIORITY:-}" = high ] && prio=0
TICKET=$QUEUE/$prio-$(printf '%010d' "$seq")
write_ticket() {
    printf 'pid=%s\nqueued=%s\ncmd=%s\nsrc=%s\n' "$$" "$QUEUED" "$*" "$SRC" >"$QUEUE/.ticket-$$"
    mv "$QUEUE/.ticket-$$" "$TICKET"
}
QUEUED=$(date +%s)
write_ticket "$@"
rm -rf "$QUEUE/.mutex"

CHILD=
LOCKED=0
cleanup() {
    [ -n "$CHILD" ] && kill -TERM -- "-$CHILD" 2>/dev/null
    rm -f "$TICKET" "$QUEUE/.ticket-$$"
    [ "$LOCKED" = 1 ] && rm -rf "$LOCK"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

take_lock() {
    mkdir -p "$LANE_HOME"
    if ! mkdir "$LOCK" 2>/dev/null; then
        alive "$(cat "$LOCK/pid" 2>/dev/null)" && return 1
        rm -rf "$LOCK"
        mkdir "$LOCK" 2>/dev/null || return 1
    fi
    LOCKED=1
    echo $$ >"$LOCK/pid"
    printf '%s\n' "$*" >"$LOCK/cmd"
    date +%s >"$LOCK/started"
}

start=$(date +%s)
announced=0
while :; do
    prune
    [ -e "$TICKET" ] || write_ticket "$@"
    # A job that holds the lock keeps its place; only the head may take it.
    if [ "$LOCKED" = 1 ] \
        || { [ "$(tickets | head -1)" = "$(basename "$TICKET")" ] && take_lock "$@"; }; then
        pgrep -x "$BUILDS" >/dev/null || break
    fi
    if [ $(( $(date +%s) - start )) -ge "$TIMEOUT" ]; then
        echo "lane: gave up after $TIMEOUT s; $(status | head -1)" >&2
        exit 1
    fi
    if [ "$announced" = 0 ]; then
        echo "lane: ticket $seq queued behind $(( $(tickets | wc -l) - 1 )) job(s)"
        announced=1
    fi
    sleep "$POLL"
done
waited=$(( $(date +%s) - start ))
[ "$waited" -gt 0 ] && echo "lane: waited $waited s for the lane"

if [ "${LANE_NO_MIRROR:-0}" != 1 ]; then
    mkdir -p "$LANE"
    rsync -rlpD --checksum --delete \
        --exclude=/.git --exclude=/.build/ --exclude=/build/ \
        --exclude=node_modules/ --exclude=/EyeTracking/dist/ \
        "$SRC/" "$LANE/" || exit 1
    echo "lane: $SRC at $(git -C "$SRC" rev-parse --short HEAD)$(git -C "$SRC" diff --quiet HEAD -- || echo ' plus uncommitted changes') → $LANE"
    cd "$LANE" || exit 1
fi
# Its own process group, so stopping the lane stops everything it started.
set -m
"$@" &
CHILD=$!
set +m
wait "$CHILD"
code=$?
CHILD=
exit "$code"
