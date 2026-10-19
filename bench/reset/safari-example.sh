#!/usr/bin/env bash
# safari.open-example reset — close any tab already on example.com.
# try/ignore inside so a no-match never fails the reset.
set -u
osascript <<'OSA' 2>/dev/null || true
tell application "Safari"
	try
		close (every tab of every window whose URL contains "example.com")
	end try
end tell
OSA
