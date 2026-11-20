#!/bin/bash
# Local CI for Jarvis on the owner's Mac. GitHub Actions is off, so this runs
# the CI test job (make test) and posts the result as a "local-ci" commit status.
#
#   scripts/local-ci.sh <pr-number|sha|branch>   test one head now
#   scripts/local-ci.sh poll                     test the newest untested head (launchd)
set -uo pipefail

REPO=HunchoBarney/MacOS_Gaze_Voice_CUA_v1
CONTEXT=local-ci
CI_HOME=${LOCAL_CI_HOME:-$HOME/.capy/work/local-ci}
CHECKOUT=$CI_HOME/checkout
LOGS=$CI_HOME/logs
LOCK=$CI_HOME/lock
LANE_TIMEOUT=${LOCAL_CI_LANE_TIMEOUT:-3600}
TEST_TIMEOUT=${LOCAL_CI_TEST_TIMEOUT:-5400}
RETRY_ERROR_AFTER=3600
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
GH=${GH:-$(command -v gh || echo "$HOME/.local/bin/gh")}

say() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
lane_busy() { pgrep -x 'swift-build|swift-test|swift-frontend|xcodebuild' >/dev/null; }

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
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then return 1; fi
    rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null && echo $$ >"$LOCK/pid"
}

release_lock() {
    [ "$(cat "$LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$LOCK"
}

resolve() {
    case $1 in
        [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9])
            "$GH" pr view "$1" -R "$REPO" --json headRefOid --jq .headRefOid ;;
        *) "$GH" api "repos/$REPO/commits/$1" --jq .sha ;;
    esac
}

summary() {
    local log=$1 part total=0 failed=0 skipped="" out=""
    part=$(grep -aoE 'Executed [0-9]+ tests?, with .*[0-9]+ failures?' "$log" | tail -1)
    if [ -n "$part" ]; then
        total=$(echo "$part" | sed -E 's/Executed ([0-9]+).*/\1/')
        failed=$(echo "$part" | grep -oE '[0-9]+ failures?' | grep -oE '^[0-9]+')
        skipped=$(echo "$part" | grep -oE '[0-9]+ tests? skipped' | grep -oE '^[0-9]+' || true)
    fi
    part=$(grep -aoE 'Test run with [0-9]+ tests? .*' "$log" | tail -1)
    if [ -n "$part" ]; then
        total=$((total + $(echo "$part" | sed -E 's/Test run with ([0-9]+).*/\1/')))
        failed=$((failed + $(echo "$part" | grep -oE '[0-9]+ issues?' | grep -oE '^[0-9]+' || echo 0)))
    fi
    [ "$total" -gt 0 ] && out="swift $total/$failed fail${skipped:+ ($skipped skipped)}"
    part=$(grep -aE '^ *Tests +.*\([0-9]+\)' "$log" | tail -1)
    if [ -n "$part" ]; then
        local passed all
        passed=$(echo "$part" | grep -oE '[0-9]+ passed' | grep -oE '[0-9]+' || echo 0)
        all=$(echo "$part" | grep -oE '\([0-9]+\)' | tr -d '()')
        out="${out:+$out · }vitest ${passed:-0}/$all"
    fi
    echo "$out"
}

test_pid=""
on_signal() {
    [ -n "$test_pid" ] && kill -TERM -- "-$test_pid" 2>/dev/null
    [ -n "${sha:-}" ] && post "$sha" error "cancelled on the Mac"
    exit 130
}

# Runs make test on one commit. The caller holds the lock.
run_sha() {
    sha=$1
    local log=$LOGS/$sha.log short=${1:0:12}
    mkdir -p "$LOGS"
    : >"$log"
    trap on_signal TERM INT HUP
    post "$sha" pending "waiting for the build lane" || { say "could not post status for $sha"; return 1; }

    local waited=0
    while lane_busy; do
        if [ "$waited" -ge "$LANE_TIMEOUT" ]; then
            say "build lane busy for $LANE_TIMEOUT s" | tee -a "$log"
            post "$sha" error "build lane busy for $((LANE_TIMEOUT / 60)) min; will retry"
            return 1
        fi
        sleep 30; waited=$((waited + 30))
    done

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

    post "$sha" pending "running make test"
    say "make test at $sha" | tee -a "$log"
    local start=$SECONDS rc
    set -m
    (cd "$CHECKOUT" && exec nice -n 10 taskpolicy -c utility make test) >>"$log" 2>&1 &
    test_pid=$!
    set +m
    (sleep "$TEST_TIMEOUT" && kill -TERM -- "-$test_pid") >/dev/null 2>&1 &
    local watchdog=$!
    wait "$test_pid"; rc=$?
    test_pid=""
    pkill -P "$watchdog" sleep 2>/dev/null; kill "$watchdog" 2>/dev/null
    local minutes=$(((SECONDS - start + 59) / 60)) counts
    counts=$(summary "$log")
    say "make test exited $rc after $minutes min: $counts" | tee -a "$log"
    if [ "$rc" -eq 0 ]; then
        post "$sha" success "${counts:-make test passed} · ${minutes} min"
    elif [ "$minutes" -ge $((TEST_TIMEOUT / 60)) ]; then
        post "$sha" failure "timed out after $minutes min · log $short.log"
    else
        post "$sha" failure "make test failed${counts:+ · $counts} · log $short.log"
    fi
    return "$rc"
}

# Open same-repository PRs (Dependabot only with the local-ci label) and main,
# newest first: "<timestamp> <sha> <label>".
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

poll() {
    if lane_busy; then say "build lane busy; next tick"; return 0; fi
    take_lock || { say "another local-ci job is running"; return 0; }
    trap release_lock EXIT
    local list ts sha label
    list=$(candidates) || { say "could not list heads"; return 1; }
    while read -r ts sha label; do
        [ -n "$sha" ] || continue
        if needs_run "$sha"; then
            say "testing $label $sha"
            run_sha "$sha"
            return
        fi
    done <<<"$(echo "$list" | sort -r)"
    say "every head has a $CONTEXT status"
}

case ${1:-} in
    "" | -h | --help) sed -n '2,6p' "$0"; exit 2 ;;
    poll) poll ;;
    *)
        target=$(resolve "$1") && [ -n "$target" ] || { echo "cannot resolve $1" >&2; exit 2; }
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
