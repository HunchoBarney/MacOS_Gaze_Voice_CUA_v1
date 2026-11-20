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
    LOCAL_CI_HOME=$home GH=$dir/gh-$1 LOCAL_CI_LANE=$dir/lane-$1 LOCAL_CI_LANE_TIMEOUT=1 \
        "$here/local-ci.sh" "$sha" >/dev/null 2>&1
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

home=$(ci_run no-lane 0)
rm -f "$dir/lane-no-lane"
LOCAL_CI_HOME=$home GH=$dir/gh-no-lane LOCAL_CI_LANE=$dir/lane-no-lane \
    "$here/local-ci.sh" "$(git -C "$dir/origin-no-lane" rev-parse HEAD)" >/dev/null 2>&1
check "$home" gh.log "state=error -f context=local-ci -f description=no build lane at"
if grep -q state=failure "$home/gh.log"; then
    echo "FAIL a missing lane must not post failure"; failures=$((failures + 1))
fi

exit $((failures > 0))
