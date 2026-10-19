#!/usr/bin/env bash
# chrome.open-example reset — close any window whose active tab is on
# example.com's URL (Chrome exposes `URL of active tab of every window`).
set -u
osascript <<'OSA' 2>/dev/null || true
tell application "Google Chrome"
	repeat with w in every window
		try
			if URL of active tab of w contains "example.com" then close active tab of w
		end try
	end repeat
end tell
OSA
