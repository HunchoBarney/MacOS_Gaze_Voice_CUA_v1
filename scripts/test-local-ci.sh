#!/bin/bash
# Checks the counts local CI reads from a make test log (coloured vitest
# summaries, both vitest blocks, the parallel swift count) and that a head's
# make test queues through the build lane at high priority.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
esc=$'\x1b'
failures=0
export LC_ALL=en_US.UTF-8

vitest_block() {
    printf '%s[2m Test Files %s[22m %s[1m%s[32m1 passed%s[39m%s[22m%s[90m (1)%s[39m\n' "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc" "$esc"
    printf '%s[2m      Tests %s[22m %s%s[90m (%s)%s[39m\n' "$esc" "$esc" "$1" "$esc" "$2" "$esc"
}

expect() {
    local got
    got=$("$here/local-ci.sh" summary "$dir/$1")
    if [ "$got" = "$2" ]; then
        echo "ok   $1: $got"
    else
        echo "FAIL $1: expected '$2', got '$got'"
        failures=$((failures + 1))
    fi
}

{
    echo "[1/2] Testing JarvisAppTests.ATests/testOne"
    echo "[2/2] Testing JarvisAppTests.ATests/testTwo"
    echo "✔ Test run with 0 tests in 0 suites passed after 0.001 seconds."
    vitest_block "${esc}[1m${esc}[32m263 passed${esc}[39m${esc}[22m" 263
    vitest_block "${esc}[1m${esc}[32m29 passed${esc}[39m${esc}[22m" 29
} >"$dir/passing.log"
expect passing.log "swift 2/0 fail · vitest 292/292"

{
    echo "[1/2] Testing JarvisAppTests.ATests/testOne"
    echo "[2/2] Testing JarvisAppTests.ATests/testTwo"
    echo "Test Case '-[JarvisAppTests.ATests testTwo]' failed (0.1 seconds)."
    vitest_block "${esc}[1m${esc}[32m263 passed${esc}[39m${esc}[22m" 263
    vitest_block "${esc}[1m${esc}[31m1 failed${esc}[39m${esc}[22m${esc}[2m | ${esc}[22m${esc}[1m${esc}[32m28 passed${esc}[39m${esc}[22m" 29
} >"$dir/failing.log"
expect failing.log "swift 2/1 fail · vitest 291/292"

{
    printf 'raw output \xff\xfe\n'
    cat "$dir/passing.log"
} >"$dir/invalid-utf8.log"
expect invalid-utf8.log "swift 2/0 fail · vitest 292/292"

{
    echo "[1/2] Testing JarvisAppTests.ATests/testOne"
} >"$dir/cut-short.log"
expect cut-short.log ""

# A head's make test goes through the build lane at high priority in local
# CI's own checkout, and its counts become the commit status. gh, git's
# remote and the lane are fakes; nothing leaves the Mac.
ci_run() {
    local home=$dir/ci-$1 lane_exit=$2
    mkdir -p "$home"
    git init -q -b main "$dir/origin-$1"
    if [ "${3:-guard}" = guard ]; then
        mkdir -p "$dir/origin-$1/Sources"
        echo 'let optIn = "JARVIS_LIVE_KEYCHAIN"' >"$dir/origin-$1/Sources/Guard.swift"
        git -C "$dir/origin-$1" add Sources
    fi
    git -C "$dir/origin-$1" -c user.name=ci -c user.email=ci@example.invalid commit -q --allow-empty -m fixture
    local sha; sha=$(git -C "$dir/origin-$1" rev-parse HEAD)
    git clone -q "$dir/origin-$1" "$home/checkout"
    cat >"$dir/gh-$1" <<EOF
#!/bin/bash
echo "\$*" >>"$home/gh.log"
case "\$*" in *"commits/$sha --jq .sha"*) echo $sha ;; esac
EOF
    cat >"$dir/lane-$1" <<EOF
#!/bin/bash
echo "priority=\$LANE_PRIORITY no_mirror=\$LANE_NO_MIRROR pwd=\$PWD args=\$*" >"$home/lane.log"
if [ $lane_exit -ne 0 ]; then echo "lane: gave up after 1 s; holder: pid 1"; exit 1; fi
cat "$dir/passing.log"
EOF
    chmod +x "$dir/gh-$1" "$dir/lane-$1"
    for mode in "$sha" poll; do
        LOCAL_CI_HOME=$home GH=$dir/gh-$1 LOCAL_CI_LANE=$dir/lane-$1 LOCAL_CI_LANE_TIMEOUT=1 \
            "$here/local-ci.sh" "$mode" >/dev/null 2>&1
    done
    echo "$home"
}

check() {
    if grep -q -- "$3" "$1/$2"; then
        echo "ok   $(basename "$1") $2 has: $3"
    else
        echo "FAIL $(basename "$1") $2 lacks: $3"
        failures=$((failures + 1))
    fi
}

home=$(ci_run passes 0)
check "$home" lane.log "priority=high no_mirror=1 pwd=$home/checkout args=make test"
check "$home" gh.log "state=success -f context=local-ci -f description=swift 2/0 fail · vitest 292/292"

home=$(ci_run lane-busy 1)
check "$home" gh.log "state=error -f context=local-ci -f description=build lane busy"
if grep -q state=failure "$home/gh.log"; then
    echo "FAIL a lane that never freed up must not post failure"; failures=$((failures + 1))
fi

home=$(ci_run no-guard 0 none)
check "$home" gh.log "state=error -f context=local-ci -f description=merge main first"
if [ -e "$home/lane.log" ]; then
    echo "FAIL a head without the Keychain test guard must never reach the lane"; failures=$((failures + 1))
fi

home=$(ci_run no-lane 0)
rm -f "$dir/lane-no-lane"
for mode in "$(git -C "$dir/origin-no-lane" rev-parse HEAD)" poll; do
    LOCAL_CI_HOME=$home GH=$dir/gh-no-lane LOCAL_CI_LANE=$dir/lane-no-lane "$here/local-ci.sh" "$mode" >/dev/null 2>&1
done
check "$home" gh.log "state=error -f context=local-ci -f description=no build lane at"
if grep -q state=failure "$home/gh.log"; then
    echo "FAIL a missing lane must not post failure"; failures=$((failures + 1))
fi

# poll tests the head it first listed longest ago, not the most recently
# updated one, and skips heads that already have a status. gh is a fake that
# lists the heads below; the checkout has no remote, so the chosen head fails
# to fetch at once and nothing runs.
poll_pick() {
    "$here/local-ci.sh" poll 2>/dev/null </dev/null \
        | sed -n 's/.* testing \([^ ]*\) .*/\1/p' | head -1
}

poll_setup() {
    local home=$dir/poll-$1
    mkdir -p "$home/seen"
    git init -q "$home/checkout"
    cat >"$dir/gh-poll-$1" <<EOF
#!/bin/bash
case "\$*" in
    "pr list"*) cat "$home/heads" ;;
    *commits/main\ *) echo "2026-11-20T00:00:00Z mmmm main" ;;
    *commits/*/statuses*) args="\$*"; sha=\${args#*commits/}; sha=\${sha%%/*}
        grep -qx "\$sha" "$home/done" 2>/dev/null && echo "success 2026-11-20T00:00:00Z" ;;
esac
exit 0
EOF
    chmod +x "$dir/gh-poll-$1"
}

pick_is() {
    local got
    got=$(LOCAL_CI_HOME=$dir/poll-$1 GH=$dir/gh-poll-$1 poll_pick)
    if [ "$got" = "$2" ]; then
        echo "ok   poll-$1 picks $2"
    else
        echo "FAIL poll-$1: expected $2, got '$got'"; failures=$((failures + 1))
    fi
}

poll_setup starve
printf '%s\n' \
    "2026-11-20T05:00:00Z aaaa pr#562" \
    "2026-11-20T06:00:00Z bbbb pr#570" \
    "2026-11-20T07:00:00Z cccc pr#580" >"$dir/poll-starve/heads"
echo 1000 >"$dir/poll-starve/seen/aaaa"
echo 2000 >"$dir/poll-starve/seen/bbbb"
pick_is starve "pr#562"
echo aaaa >>"$dir/poll-starve/done"
pick_is starve "pr#570"
echo bbbb >>"$dir/poll-starve/done"
pick_is starve "main"
if [ -s "$dir/poll-starve/seen/cccc" ]; then
    echo "ok   poll-starve records when it first saw a new head"
else
    echo "FAIL poll-starve didn't record a new head"; failures=$((failures + 1))
fi

poll_setup fresh
printf '%s\n' \
    "2026-11-20T09:00:00Z dddd pr#3" \
    "2026-11-20T08:00:00Z eeee pr#2" >"$dir/poll-fresh/heads"
for s in dddd eeee mmmm; do echo 3000 >"$dir/poll-fresh/seen/$s"; done
pick_is fresh "main"
echo mmmm >"$dir/poll-fresh/done"
pick_is fresh "pr#2"

# A head queued by hand records its request and a pending status and returns
# at once; poll then tests it in first-seen order. A head that already has a
# result queues from the time of the request. This fake gh keeps every posted
# status, newest last, so poll sees what the request and each run posted.
cat >"$dir/gh-req" <<'EOF'
#!/bin/bash
h=$REQ_HOME; a="$*"
case "$a" in
    "pr list"*) cat "$h/heads" ;;
    *"-X POST"*) s=${a#*statuses/}; s=${s%% *}; st=${a#*state=}; echo "$s ${st%% *}" >>"$h/posted" ;;
    *"/statuses --jq"*) s=${a#*commits/}; s=${s%%/*}
        st=$(grep "^$s " "$h/posted" 2>/dev/null | tail -1 | cut -d" " -f2)
        [ -n "$st" ] && echo "$st $(date -u +%Y-%m-%dT%H:%M:%SZ)" ;;
    *"--jq .sha"*) s=${a#*commits/}; [ "${s%% *}" = main ] || echo "${s%% *}" ;;
esac
exit 0
EOF
chmod +x "$dir/gh-req"

req() { REQ_HOME=$dir/req-$1 LOCAL_CI_HOME=$dir/req-$1 GH=$dir/gh-req "$here/local-ci.sh" "$2" </dev/null 2>/dev/null; }
req_pick_is() {
    local got
    got=$(REQ_HOME=$dir/req-$1 LOCAL_CI_HOME=$dir/req-$1 GH=$dir/gh-req poll_pick)
    if [ "$got" = "$2" ]; then
        echo "ok   req-$1 picks $2"
    else
        echo "FAIL req-$1: expected $2, got '$got'"; failures=$((failures + 1))
    fi
}
req_check() {
    if eval "$2"; then echo "ok   req-$1"; else echo "FAIL req-$1"; failures=$((failures + 1)); fi
}

mkdir -p "$dir/req-new/seen" && git init -q "$dir/req-new/checkout"
echo "2026-11-20T05:00:00Z aaaa pr#1" >"$dir/req-new/heads"
echo 2000 >"$dir/req-new/seen/aaaa"
echo 1000 >"$dir/req-new/seen/rrrr"
start=$(date +%s)
out=$(req new rrrr)
req_check "new: returns at once without taking the lock (got: $out)" \
    '[ $(($(date +%s) - start)) -le 5 ] && [ ! -d "$dir/req-new/lock" ] && grep -q "queued rrrr" <<<"$out"'
req_check "new: records the request and posts pending" \
    '[ -s "$dir/req-new/requested/rrrr" ] && grep -qx "rrrr pending" "$dir/req-new/posted"'
req_pick_is new requested
req_check "new: poll clears the request it tests" '[ ! -e "$dir/req-new/requested/rrrr" ]'
req_pick_is new "pr#1"

mkdir -p "$dir/req-rerun/seen" && git init -q "$dir/req-rerun/checkout"
echo "2026-11-20T05:00:00Z bbbb pr#2" >"$dir/req-rerun/heads"
echo 2000 >"$dir/req-rerun/seen/bbbb"
echo 500 >"$dir/req-rerun/seen/aaaa"
echo "aaaa success" >"$dir/req-rerun/posted"
req rerun aaaa >/dev/null
req_check "rerun: a tested head queues from the request" '[ "$(cat "$dir/req-rerun/seen/aaaa")" -ge "$start" ]'
req_pick_is rerun "pr#2"
req_pick_is rerun requested

mkdir -p "$dir/req-nopost/seen" && git init -q "$dir/req-nopost/checkout"
: >"$dir/req-nopost/heads"
echo "cccc success" >"$dir/req-nopost/posted"
sed 's/^\(    \*"-X POST"\*)\).*/\1 exit 1 ;;/' "$dir/gh-req" >"$dir/gh-nopost" && chmod +x "$dir/gh-nopost"
REQ_HOME=$dir/req-nopost LOCAL_CI_HOME=$dir/req-nopost GH=$dir/gh-nopost "$here/local-ci.sh" cccc </dev/null >/dev/null 2>&1
rc=$?
req_check "nopost: a request whose status can't be posted fails and records nothing" \
    '[ $rc -eq 1 ] && [ ! -e "$dir/req-nopost/requested/cccc" ]'

exit $((failures > 0))
