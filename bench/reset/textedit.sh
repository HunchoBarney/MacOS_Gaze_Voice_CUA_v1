#!/usr/bin/env bash
# textedit.type reset — all TextEdit documents closed without saving.
set -u
osascript -e 'tell application "TextEdit" to close every document saving no' 2>/dev/null || true
