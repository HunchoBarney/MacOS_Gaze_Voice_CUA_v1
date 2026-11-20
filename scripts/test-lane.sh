#!/bin/bash
# Fake-command tests for lane.sh: order, priority, stale tickets and holders,
# old-style lock, status, timeout, and release on TERM.
set -u
L=${LANE_SH:-$(cd "$(dirname "$0")" && pwd)/lane.sh}
T=$(mktemp -d)
export LANE_STATE=$T/queue JARVIS_LANE_HOME=$T/home LANE_NO_MIRROR=1 LANE_POLL=0.2 LANE_BUILDS=no-such-build-xyz
LOG=$T/log
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }
job() { echo "start $1" >>"$LOG"; sleep "$2"; echo "end $1" >>"$LOG"; }
export -f job; export LOG

# 1. FIFO with a high-priority jump
"$L" bash -c 'job A 3' >/dev/null & sleep 0.6
"$L" bash -c 'job B 0.3' >/dev/null & sleep 0.3
"$L" bash -c 'job C 0.3' >/dev/null & sleep 0.3
LANE_PRIORITY=high "$L" bash -c 'job D 0.3' >/dev/null & sleep 0.8
"$L" --status >"$T/status"
wait
order=$(grep start "$LOG" | awk '{print $2}' | tr -d '\n')
check "order is A D B C (got $order)" '[ "$order" = ADBC ]'
check "no overlap" '[ "$(paste -sd" " "$LOG")" = "start A end A start D end D start B end B start C end C" ]'
check "status names the holder" 'grep -q "^holder: pid .*job A" "$T/status"'
check "status lists D first, then B, C" '[ "$(grep -E "^[0-9]\." "$T/status" | sed -E "s/.*job ([A-Z]).*/\1/" | tr -d "\n")" = DBC ]'
check "status marks D high" 'grep -q "(high).*job D" "$T/status"'
check "queue and lock empty afterwards" '[ -z "$(ls "$LANE_STATE" | grep -E "^[01]-")" ] && [ ! -d "$JARVIS_LANE_HOME/lock" ]'

# 2. A waiter that dies leaves no ticket in the way
: >"$LOG"
"$L" bash -c 'job E 1' >/dev/null & sleep 0.4
"$L" bash -c 'job F 0.2' >/dev/null & F=$!; sleep 0.4
kill -9 $F 2>/dev/null; sleep 0.1
"$L" bash -c 'job G 0.2' >/dev/null
wait 2>/dev/null
check "dead waiter skipped (got $(grep -c start "$LOG") starts)" '[ "$(grep start "$LOG" | awk "{print \$2}" | tr -d "\n")" = EG ]'

# 3. A holder killed with -9 is reclaimed
: >"$LOG"
"$L" bash -c 'job H 30' >/dev/null & H=$!; sleep 0.6
kill -9 $H; pkill -f "job H 30"; sleep 0.1
start=$(date +%s)
"$L" bash -c 'job I 0.1' >/dev/null
check "stale holder reclaimed within 2 s" '[ $(( $(date +%s) - start )) -le 2 ] && grep -q "end I" "$LOG"'

# 4. An old-style lane-test.sh lock holds new jobs back
: >"$LOG"
sleep 1.5 & OLD=$!
mkdir -p "$JARVIS_LANE_HOME/lock"; echo $OLD >"$JARVIS_LANE_HOME/lock/pid"
"$L" bash -c 'echo "start J $(date +%s)" >>"$LOG"' >/dev/null &
sleep 0.5
check "waits while the old-style lock is live" '! grep -q "start J" "$LOG"'
"$L" --status >"$T/status2"
check "status reports the old-style holder" 'grep -q "old-style" "$T/status2"'
wait
check "runs once it is released" 'grep -q "start J" "$LOG"'

# 5. Timeout
"$L" bash -c 'sleep 3' >/dev/null & sleep 0.4
JARVIS_LANE_TIMEOUT=1 "$L" true 2>"$T/err"; code=$?
check "timeout exits 1 (got $code)" '[ "$code" = 1 ] && grep -q "gave up" "$T/err"'
wait

# 6. TERM releases the ticket, the lock and the child
"$L" bash -c 'sleep 31 & sleep 30; echo late >>"$LOG"' >/dev/null & K=$!; sleep 1
kill -TERM $K; wait $K 2>/dev/null; sleep 0.3
check "lock released on TERM" '[ ! -d "$JARVIS_LANE_HOME/lock" ]'
check "ticket released on TERM" '[ -z "$(ls "$LANE_STATE" | grep -E "^[01]-")" ]'
check "child killed on TERM" '! pgrep -f "sleep 30; echo late" >/dev/null'
check "grandchild killed on TERM" '! pgrep -fx "sleep 31" >/dev/null'

# 7. Exit code passes through
"$L" bash -c 'exit 7' >/dev/null; code=$?
check "exit code passes through (got $code)" '[ "$code" = 7 ]'

# 8. A holder waiting on another build keeps its place when a high ticket arrives
: >"$LOG"
printf 'int main(int c, char **v) { sleep(atoi(v[1])); return 0; }' \
    | cc -x c -include stdlib.h -include unistd.h -o "$T/fb$$" -
"$T/fb$$" 2 & FB=$!
LANE_BUILDS=fb$$ JARVIS_LANE_TIMEOUT=20 "$L" bash -c 'job P 0.2' >/dev/null & sleep 0.8
check "normal job holds the lock while the build runs" '[ -d "$JARVIS_LANE_HOME/lock" ] && ! grep -q "start P" "$LOG"'
LANE_BUILDS=fb$$ JARVIS_LANE_TIMEOUT=20 LANE_PRIORITY=high "$L" bash -c 'job Q 0.2' >/dev/null &
start=$(date +%s)
wait
check "both run, holder first, within 10 s (got $(grep start "$LOG" | awk '{print $2}' | tr -d '\n'))" '[ "$(grep start "$LOG" | awk "{print \$2}" | tr -d "\n")" = PQ ] && [ $(( $(date +%s) - start )) -le 10 ]'

# 9. Rewriting the installed script in place doesn't break a waiting job
: >"$LOG"
cp "$L" "$T/lane-copy.sh"
"$T/lane-copy.sh" bash -c 'job R 2' >/dev/null & sleep 1.2
"$T/lane-copy.sh" bash -c 'job S 0.2' >/dev/null 2>"$T/err9" & sleep 0.6
printf 'echo broken; if true; then\n' >"$T/lane-copy.sh"
wait
check "waiting job survives an in-place edit (got $(grep start "$LOG" | awk '{print $2}' | tr -d '\n'))" '[ "$(grep start "$LOG" | awk "{print \$2}" | tr -d "\n")" = RS ] && ! grep -q "syntax error" "$T/err9"'

# 10. Starting a job leaves a live job's private copy alone
mkdir -p "$T/tmp"
TMPDIR=$T/tmp "$L" bash -c 'sleep 1.5' >/dev/null & V=$!; sleep 0.5
TMPDIR=$T/tmp "$L" true >/dev/null & sleep 0.5
check "live job's private copy kept" 'ls "$T/tmp"/lane.$V.* >/dev/null 2>&1'
wait
check "private copies removed afterwards" '[ -z "$(ls "$T/tmp")" ]'

rm -rf "$T"
exit $fail
