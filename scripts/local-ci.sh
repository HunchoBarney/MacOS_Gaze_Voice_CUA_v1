#!/bin/bash
# Local CI for Jarvis on the owner's Mac. GitHub Actions is off, so this runs
# the CI test job (make test) and posts the result as a "local-ci" commit status.
#
#   scripts/local-ci.sh <pr-number|sha|branch>   test one head now
#   scripts/local-ci.sh poll                     test the untested head that has waited longest (launchd)
#   scripts/local-ci.sh summary <log>            print the counts it would post for a log
set -uo pipefail

REPO=HunchoBarney/MacOS_Gaze_Voice_CUA_v1
CONTEXT=local-ci
CI_HOME=${LOCAL_CI_HOME:-$HOME/.capy/work/local-ci}
CHECKOUT=$CI_HOME/checkout
LOGS=$CI_HOME/logs
LOCK=$CI_HOME/lock
LANE_TIMEOUT=${LOCAL_CI_LANE_TIMEOUT:-3600}
LANE_SH=${LOCAL_CI_LANE:-$HOME/.capy/work/lane/lane.sh}
TEST_TIMEOUT=${LOCAL_CI_TEST_TIMEOUT:-5400}
RETRY_ERROR_AFTER=3600
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
GH=${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

post() {
    "$GH" api -X POST "repos/$REPO/statuses/$1" -f state="$2" -f context="$CONTEXT" \
        -f description="$(printf '%.140s' "$3")" >/dev/null
}

latest_status() {
    "$GH" api "repos/$REPO/commits/$1/statuses" \
        --jq "map(select(.context == \"$CONTEXT\"))[0] // empty | \"\(.state) \(.created_at)\""
}

take_lock() {
    mkdir -p "$CI_HOME"
    if mkdir "$LOCK" 2>/dev/null; then echo $$ >"$LOCK/pid"; return 0; fi
    local holder
    holder=$(cat "$LOCK/pid" 2>/dev/null)
    if [ -n "$holder" ] && ps -p "$holder" -o command= 2>/dev/null | grep -q local-ci; then return 1; fi
    rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

release_lock() {
    [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
}

resolve() {
    case $1 in
        [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9])
            "$GH" pr view "$1" -R "$REPO" --json headRefOid,isCrossRepository \
                --jq 'if .isCrossRepository then "fork" else .headRefOid end' ;;
        *) "$GH" api "repos/$REPO/commits/$1" --jq .sha ;;
    esac
}

# "swift <total>/<failed> fail · vitest <passed>/<all>", with colour codes
# stripped first and every vitest block (EyeTracking, CredentialService)
# added up. A parallel run's
# total is the last [N/N] progress line and counts only when every test ran;
# a serial run's is XCTest's own summary.
summary() {
    local plain part total=0 failed=0 skipped="" out=""
    plain=$(LC_ALL=C sed $'s/\x1b\\[[0-9;]*[A-Za-z]//g' "$1")
    part=$(grep -aoE '^\[[0-9]+/[0-9]+\] Testing ' <<<"$plain" | tail -1)
    if [ -n "$part" ]; then
        local ran listed
        ran=$(echo "$part" | sed -E 's/^\[([0-9]+)\/.*/\1/')
        listed=$(echo "$part" | sed -E 's/^\[[0-9]+\/([0-9]+)\].*/\1/')
        [ "$ran" = "$listed" ] && total=$listed
        failed=$(grep -aoE "Test Case '-\[[^]]+\]' failed" <<<"$plain" | sort -u | wc -l | tr -d ' ')
    fi
    part=$(grep -aoE 'Executed [0-9]+ tests?, with .*[0-9]+ failures?' <<<"$plain" | tail -1)
    if [ "$total" -eq 0 ] && [ -n "$part" ]; then
        total=$(echo "$part" | sed -E 's/Executed ([0-9]+).*/\1/')
        failed=$(echo "$part" | grep -oE '[0-9]+ failures?' | grep -oE '^[0-9]+')
        skipped=$(echo "$part" | grep -oE '[0-9]+ tests? skipped' | grep -oE '^[0-9]+' || true)
    fi
    part=$(grep -aoE 'Test run with [0-9]+ tests? .*' <<<"$plain" | tail -1)
    if [ -n "$part" ]; then
        total=$((total + $(echo "$part" | sed -E 's/Test run with ([0-9]+).*/\1/')))
        failed=$((failed + $(echo "$part" | grep -oE '[0-9]+ issues?' | grep -oE '^[0-9]+' || echo 0)))
    fi
    [ "$total" -gt 0 ] && out="swift $total/$failed fail${skipped:+ ($skipped skipped)}"
    local passed=0 all=0 blocks=0 line
    while read -r line; do
        [ -n "$line" ] || continue
        blocks=$((blocks + 1))
        passed=$((passed + $(echo "$line" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)))
        all=$((all + $(echo "$line" | grep -oE '\([0-9]+\)' | tr -d '()')))
    done <<<"$(grep -aE '^ *Tests +.*\([0-9]+\)' <<<"$plain")"
    [ "$blocks" -gt 0 ] && out="${out:+$out · }vitest $passed/$all"
    echo "$out"
}

# SIGTERM a process group, then SIGKILL it if it is still alive after a grace period.
stop_group() {
    kill -TERM -- "-$1" 2>/dev/null || return 0
    local i
    for ((i = 0; i < $2; i++)); do
        kill -0 -- "-$1" 2>/dev/null || return 0
        sleep 1
    done
    kill -KILL -- "-$1" 2>/dev/null
}

test_pid=""
on_signal() {
    [ -n "$test_pid" ] && stop_group "$test_pid" 10
    [ -n "${sha:-}" ] && post "$sha" error "cancelled on the Mac"
    exit 130
}

# Runs make test on one commit. The caller holds the lock.
run_sha() {
    sha=$1
    local log=$LOGS/$sha.log short=${1:0:12}
    mkdir -p "$LOGS"
    : >"$log"
    post "$sha" pending "checking out" || { say "could not post status for $sha"; return 1; }

    say "checking out $sha" | tee -a "$log"
    if [ ! -d "$CHECKOUT/.git" ]; then
        git clone --quiet --filter=blob:none "https://github.com/$REPO.git" "$CHECKOUT" >>"$log" 2>&1 || {
            post "$sha" error "clone failed · log $short.log"; return 1; }
        git -C "$CHECKOUT" config credential.https://github.com.helper "!$GH auth git-credential"
    fi
    if ! { git -C "$CHECKOUT" fetch --quiet --no-tags origin "$sha" &&
           git -C "$CHECKOUT" checkout --quiet --force --detach "$sha" &&
           git -C "$CHECKOUT" clean -ffdxq -e .build -e node_modules; } >>"$log" 2>&1; then
        post "$sha" error "checkout failed · log $short.log"; return 1
    fi

    if [ ! -x "$LANE_SH" ]; then
        say "no build lane at $LANE_SH" | tee -a "$log"
        post "$sha" error "no build lane at $LANE_SH; will retry"
        return 1
    fi
    # The build lane serves local CI ahead of every normal job, in this
    # checkout rather than the lane's mirror.
    post "$sha" pending "queued in the build lane for make test"
    say "make test at $sha" | tee -a "$log"
    local start=$SECONDS rc
    set -m
    (cd "$CHECKOUT" && LANE_PRIORITY=high LANE_NO_MIRROR=1 JARVIS_LANE_TIMEOUT=$LANE_TIMEOUT \
        exec nice -n 10 "$LANE_SH" make test) >>"$log" 2>&1 &
    test_pid=$!
    set +m
    rm -f "$CI_HOME/timed-out"
    (sleep $((LANE_TIMEOUT + TEST_TIMEOUT)) && touch "$CI_HOME/timed-out" && stop_group "$test_pid" 30) >/dev/null 2>&1 &
    local watchdog=$!
    wait "$test_pid"; rc=$?
    test_pid=""
    if [ -e "$CI_HOME/timed-out" ]; then
        wait "$watchdog"
    else
        pkill -P "$watchdog" sleep 2>/dev/null; kill "$watchdog" 2>/dev/null
    fi
    local minutes=$(((SECONDS - start + 59) / 60)) counts
    if grep -aq '^lane: gave up after' "$log"; then
        say "the build lane did not free up in $LANE_TIMEOUT s" | tee -a "$log"
        post "$sha" error "build lane busy for $((LANE_TIMEOUT / 60)) min; will retry"
        return 1
    fi
    counts=$(summary "$log")
    if [ "$rc" -eq 0 ] && ! [[ $counts == swift* && $counts == *vitest* ]]; then
        say "make test exited 0 but the log has no complete swift and vitest count" | tee -a "$log"
        rc=1 counts="no complete test count in the log"
    fi
    say "make test exited $rc after $minutes min: $counts" | tee -a "$log"
    if [ "$rc" -eq 0 ]; then
        post "$sha" success "${counts:-make test passed} · ${minutes} min"
    elif [ -e "$CI_HOME/timed-out" ]; then
        post "$sha" failure "timed out after $minutes min · log $short.log"
    else
        post "$sha" failure "make test failed${counts:+ · $counts} · log $short.log"
    fi
    return "$rc"
}

# Open same-repository PRs (Dependabot only with the local-ci label) and main:
# "<timestamp> <sha> <label>".
candidates() {
    "$GH" pr list -R "$REPO" --state open --limit 100 \
        --json number,headRefOid,updatedAt,author,labels,isCrossRepository \
        --jq '.[] | select(.isCrossRepository | not)
              | select((.author.login | test("dependabot") | not) or any(.labels[]; .name == "local-ci"))
              | "\(.updatedAt) \(.headRefOid) pr#\(.number)"'
    "$GH" api "repos/$REPO/commits/main" --jq '"\(.commit.committer.date) \(.sha) main"'
}

needs_run() {
    local state when
    read -r state when <<<"$(latest_status "$1")"
    case $state in
        "" | pending) return 0 ;;
        error) [ $(($(date +%s) - $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$when" +%s))) -ge "$RETRY_ERROR_AFTER" ] ;;
        *) return 1 ;;
    esac
}

# When poll first listed a head, in epoch seconds. Heads are tested oldest
# first by this, so a busy stream of new pushes can't starve an older one.
first_seen() {
    local f=$CI_HOME/seen/$1
    [ -s "$f" ] || { mkdir -p "$CI_HOME/seen" && date +%s >"$f"; }
    cat "$f"
}

poll() {
    take_lock || { say "another local-ci job is running"; return 0; }
    trap release_lock EXIT
    local list seen ts sha label
    list=$(candidates) || { say "could not list heads"; return 1; }
    find "$CI_HOME/seen" -type f -mtime +30 -delete 2>/dev/null
    while read -r seen ts sha label; do
        [ -n "$sha" ] || continue
        if needs_run "$sha"; then
            say "testing $label $sha"
            run_sha "$sha"
            return
        fi
    done <<<"$(while read -r ts sha label; do
                   [ -n "$sha" ] && echo "$(first_seen "$sha") $ts $sha $label"
               done <<<"$list" | sort -k1,1n -k2,2)"
    say "every head has a $CONTEXT status"
}

trap on_signal TERM INT HUP

case ${1:-} in
    "" | -h | --help) sed -n '2,7p' "$0"; exit 2 ;;
    poll) poll ;;
    summary) summary "${2:?usage: local-ci.sh summary <log>}" ;;
    *)
        target=$(resolve "$1") && [ -n "$target" ] || { echo "cannot resolve $1" >&2; exit 2; }
        [ "$target" = fork ] && { echo "refusing PR #$1: its head is in a fork" >&2; exit 2; }
        waited=0
        until take_lock; do
            [ "$waited" -ge "$LANE_TIMEOUT" ] && { echo "another local-ci job held the lock for $LANE_TIMEOUT s" >&2; exit 1; }
            sleep 30; waited=$((waited + 30))
        done
        trap release_lock EXIT
        say "testing $1 ($target); log $LOGS/$target.log"
        run_sha "$target"
        ;;
esac
