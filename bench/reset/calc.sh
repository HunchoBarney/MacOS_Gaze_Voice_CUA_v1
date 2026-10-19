#!/usr/bin/env bash
# calc.open / calc.compute reset — Calculator closed, no error if absent.
set -u
osascript -e 'tell application "Calculator" to quit' 2>/dev/null || true
