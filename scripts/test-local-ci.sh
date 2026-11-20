#!/bin/bash
# Checks the counts local CI reads from a make test log: coloured vitest
# summaries, both vitest blocks (EyeTracking and CredentialService) and the
# parallel swift progress count.
set -uo pipefail
here=$(cd "$(dirname "$0")" && pwd)
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
esc=$'\x1b'
failures=0

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
    echo "[1/2] Testing JarvisAppTests.ATests/testOne"
} >"$dir/cut-short.log"
expect cut-short.log ""

exit $((failures > 0))
