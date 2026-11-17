#!/usr/bin/env bash
# Retired: the former reset discarded every TextEdit document.
set -eu
echo "Blocked: TextEdit automation requires an identity-bound owned fixture; no documents were changed." >&2
exit 2
