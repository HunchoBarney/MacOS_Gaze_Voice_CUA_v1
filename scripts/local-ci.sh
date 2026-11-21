#!/bin/bash
# Local CI for Jarvis on the owner's Mac. GitHub Actions is off, so this runs
# the CI test job (make test) and posts the result as a "local-ci" commit status.
# It tests a head merged into current origin/main, the tree the PR would land
# as, and the status on the head names that main.
#
#   scripts/local-ci.sh <pr-number|sha|branch>   queue one head; poll tests requests oldest first
#   scripts/local-ci.sh poll                     test the oldest request, else an untested open head (launchd)
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

test_pid="" watchdog=""
on_signal() {
    [ -n "$test_pid" ] && stop_group "$test_pid" 10
    [ -n "$watchdog" ] && { pkill -P "$watchdog" sleep; kill "$watchdog"; } 2>/dev/null
    [ -n "${sha:-}" ] && post "$sha" error "cancelled on the Mac"
    exit 130
}

# Runs make test on one commit merged into current main, without committing
# the merge. The caller holds the lock.
run_sha() {
    sha=$1
    local log=$LOGS/$sha.log short=${1:0:12} main tree rc
    mkdir -p "$LOGS"
    : >"$log"
    post "$sha" pending "checking out" || { say "could not post status for $sha"; return 1; }

    say "checking out $sha" | tee -a "$log"
    if [ ! -d "$CHECKOUT/.git" ]; then
        git clone --quiet --filter=blob:none "https://github.com/$REPO.git" "$CHECKOUT" >>"$log" 2>&1 || {
            post "$sha" error "clone failed · log $short.log"; return 1; }
        git -C "$CHECKOUT" config credential.https://github.com.helper "!$GH auth git-credential"
    fi
    if ! { git -C "$CHECKOUT" fetch --quiet --no-tags origin "+refs/heads/main:refs/remotes/origin/main" "$sha" &&
           git -C "$CHECKOUT" checkout --quiet --force --detach origin/main &&
           git -C "$CHECKOUT" clean -ffdxq -e .build -e node_modules; } >>"$log" 2>&1; then
        post "$sha" error "checkout failed · log $short.log"; return 1
    fi
    main=$(git -C "$CHECKOUT" rev-parse --short=7 origin/main)
    tree=$(git -C "$CHECKOUT" merge-tree --write-tree origin/main "$sha" 2>>"$log"); rc=$?
    if [ "$rc" -eq 1 ]; then
        say "$sha conflicts with main $main" | tee -a "$log"
        git -C "$CHECKOUT" merge-tree --write-tree --name-only origin/main "$sha" 2>&1 | sed '1d' >>"$log"
        post "$sha" error "conflicts with main $main"
        return 1
    fi
    if [ "$rc" -ne 0 ] || ! git -C "$CHECKOUT" read-tree -u --reset "$tree" >>"$log" 2>&1; then
        post "$sha" error "could not merge into main $main · log $short.log"; return 1
    fi
    say "testing $sha merged into main $main (tree $tree)" | tee -a "$log"

    # Captain gate (2026-11-20): a tree without #598's Keychain test guard
    # would raise Keychain dialogs on the owner's screen. Refuse to test it.
    if ! git -C "$CHECKOUT" grep -q JARVIS_LIVE_KEYCHAIN "$tree" -- Sources; then
        say "no Keychain test guard in $sha merged into main $main" | tee -a "$log"
        post "$sha" error "the merge with main $main lacks the #598 Keychain test guard"
        return 1
    fi

    if [ ! -x "$LANE_SH" ]; then
        say "no build lane at $LANE_SH" | tee -a "$log"
        post "$sha" error "no build lane at $LANE_SH; will retry"
        requeue "$sha"
        return 1
    fi
    # The build lane serves local CI ahead of every normal job, in this
    # checkout rather than the lane's mirror.
    post "$sha" pending "queued in the build lane for make test"
    say "make test at $sha" | tee -a "$log"
    local start=$SECONDS
    set -m
    (cd "$CHECKOUT" && LANE_PRIORITY=high LANE_NO_MIRROR=1 JARVIS_LANE_TIMEOUT=$LANE_TIMEOUT \
        exec nice -n 10 "$LANE_SH" make test) >>"$log" 2>&1 &
    test_pid=$!
    set +m
    rm -f "$CI_HOME/timed-out"
    (sleep $((LANE_TIMEOUT + TEST_TIMEOUT)) && touch "$CI_HOME/timed-out" && stop_group "$test_pid" 30) >/dev/null 2>&1 &
    watchdog=$!
    wait "$test_pid"; rc=$?
    test_pid=""
    if [ -e "$CI_HOME/timed-out" ]; then
        wait "$watchdog"
    else
        pkill -P "$watchdog" sleep 2>/dev/null; kill "$watchdog" 2>/dev/null
    fi
    watchdog=""
    local minutes=$(((SECONDS - start + 59) / 60)) counts
    if grep -aq '^lane: gave up after' "$log"; then
        say "the build lane did not free up in $LANE_TIMEOUT s" | tee -a "$log"
        post "$sha" error "build lane busy for $((LANE_TIMEOUT / 60)) min; will retry"
        requeue "$sha"
        return 1
    fi
    counts=$(summary "$log")
    if [ "$rc" -eq 0 ] && ! [[ $counts == swift* && $counts == *vitest* ]]; then
        say "make test exited 0 but the log has no complete swift and vitest count" | tee -a "$log"
        rc=1 counts="no complete test count in the log"
    fi
    say "make test exited $rc after $minutes min on main $main: $counts" | tee -a "$log"
    if [ "$rc" -eq 0 ]; then
        post "$sha" success "success on main $main · ${counts:-make test passed} · ${minutes} min"
    elif [ -e "$CI_HOME/timed-out" ]; then
        post "$sha" failure "timed out on main $main after $minutes min · log $short.log"
    else
        post "$sha" failure "failed on main $main${counts:+ · $counts} · log $short.log"
    fi
    return "$rc"
}

# Open same-repository PRs (Dependabot only with the local-ci label) and main:
# "<timestamp> <sha> <label> <draft>".
candidates() {
    "$GH" pr list -R "$REPO" --state open --limit 100 \
        --json number,headRefOid,updatedAt,author,labels,isCrossRepository,isDraft \
        --jq '.[] | select(.isCrossRepository | not)
              | select((.author.login | test("dependabot") | not) or any(.labels[]; .name == "local-ci"))
              | "\(.updatedAt) \(.headRefOid) pr#\(.number) \(.isDraft)"'
    "$GH" api "repos/$REPO/commits/main" --jq '"\(.commit.committer.date) \(.sha) main false"'
}

# Queues a head again after a failure that says it will retry.
requeue() {
    mkdir -p "$CI_HOME/requested" && date -u +%Y-%m-%dT%H:%M:%SZ >"$CI_HOME/requested/$1"
}

# Heads queued by hand, oldest request first: "<requested at> <sha> <pr>".
# The PR is the one the head belonged to when it was requested, if known.
requested() {
    local f at pr
    for f in "$CI_HOME"/requested/*; do
        [ -f "$f" ] || continue
        read -r at pr <"$f"
        echo "$at ${f##*/} $pr"
    done | sort -k1,1 -k2,2
}

# Prints the newer head of the PR a requested head belonged to, if that PR
# has moved on. Without a recorded PR, a head that is in open PRs but heads
# none of them has been replaced.
newer_head() {
    if [ -n "$2" ]; then
        "$GH" pr view "$2" -R "$REPO" --json headRefOid,state \
            --jq "select(.state == \"OPEN\" and .headRefOid != \"$1\") | .headRefOid"
    else
        "$GH" api "repos/$REPO/commits/$1/pulls" \
            --jq "map(select(.state == \"open\")) | select(length > 0 and all(.head.sha != \"$1\")) | .[0].head.sha"
    fi
}

# PR numbers listed one per line in $CI_HOME/held wait for their owner's
# retest and are never tested unless requested.
held() {
    [ "${1#pr#}" != "$1" ] && grep -qx "${1#pr#}" "$CI_HOME/held" 2>/dev/null
}

# When poll first listed an open head, in epoch seconds. Unrequested heads
# are tested oldest first by this, so new pushes can't starve an older one.
first_seen() {
    local f=$CI_HOME/seen/$1
    [ -s "$f" ] || { mkdir -p "$CI_HOME/seen" && date +%s >"$f"; }
    cat "$f"
}

# Requests come first, oldest request first; a request whose PR has a newer
# head is dropped untested. Only with no request left does poll test an open
# head, and only one with no $CONTEXT status that is not a draft or held.
poll() {
    take_lock || { say "another local-ci job is running"; return 0; }
    trap release_lock EXIT
    local list seen ts sha label draft pr newer status
    find "$CI_HOME/seen" "$CI_HOME/requested" -type f -mtime +30 -delete 2>/dev/null
    while read -r ts sha pr; do
        [ -n "$sha" ] || continue
        rm -f "$CI_HOME/requested/$sha"
        newer=$(newer_head "$sha" "$pr")
        if [ -n "$newer" ]; then
            say "dropping request $sha: ${pr:+pr#$pr }has a newer head $newer"
            post "$sha" error "not tested: replaced by newer head ${newer:0:7}"
            continue
        fi
        say "testing requested $sha"
        run_sha "$sha"
        return
    done <<<"$(requested)"
    list=$(candidates) || { say "could not list heads"; return 1; }
    while read -r seen ts sha label draft; do
        [ -n "$sha" ] || continue
        [ "$draft" = true ] && continue
        held "$label" && continue
        status=$(latest_status "$sha") && [ -z "$status" ] || continue
        say "testing $label $sha"
        run_sha "$sha"
        return
    done <<<"$(while read -r ts sha label draft; do
                   [ -n "$sha" ] && echo "$(first_seen "$sha") $ts $sha $label $draft"
               done <<<"$list" | sort -k1,1n -k2,2)"
    say "no requests, and every open head has a $CONTEXT status"
}

trap on_signal TERM INT HUP

case ${1:-} in
    "" | -h | --help) sed -n '2,7p' "$0"; exit 2 ;;
    poll) poll ;;
    summary) summary "${2:?usage: local-ci.sh summary <log>}" ;;
    *)
        target=$(resolve "$1") && [ -n "$target" ] || { echo "cannot resolve $1" >&2; exit 2; }
        [ "$target" = fork ] && { echo "refusing PR #$1: its head is in a fork" >&2; exit 2; }
        # Queue it for poll rather than racing other callers for the lock,
        # with the PR it heads so poll can drop it once that PR moves on.
        case $1 in
            [0-9]|[0-9][0-9]|[0-9][0-9][0-9]|[0-9][0-9][0-9][0-9]) pr=$1 ;;
            *) pr=$("$GH" api "repos/$REPO/commits/$target/pulls" \
                   --jq "map(select(.state == \"open\" and .head.sha == \"$target\"))[0].number // empty" 2>/dev/null) ;;
        esac
        post "$target" pending "queued for local CI" || { echo "could not post a status for $target" >&2; exit 1; }
        mkdir -p "$CI_HOME/requested"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $pr" >"$CI_HOME/requested/$target"
        say "queued $1 ($target); poll tests requests oldest first, so watch its $CONTEXT status"
        ;;
esac
