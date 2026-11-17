#!/usr/bin/env bash
# calc.open / calc.compute reset — Calculator closed, no error if absent.
# `osascript quit` is async: wait for the process to actually exit so the
# next run can't observe a mid-shutdown app and claim it "already running".
set -u
osascript -e 'tell application "Calculator" to quit' 2>/dev/null || true
for _ in $(seq 1 50); do
    pgrep -x Calculator >/dev/null || exit 0
    sleep 0.1
done
exit 0
