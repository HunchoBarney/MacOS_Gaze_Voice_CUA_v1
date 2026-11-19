#!/usr/bin/env bash
# One-time HUMAN step: create the `jevbench` macOS test user the mutating
# bench corpus runs under. Needs sudo; refuses cleanly without it.
set -euo pipefail

checklist() {
  cat <<'LIST'

Post-create checklist (all inside the jevbench session):
  1. Log in on the console as jevbench once — creates the home dir and
     clears first-run dialogs.
  2. Install the app there: `make install-tracker` / copy "Jarvis.app"
     over, or run `make local` from a checkout in that session.
  3. Grant Jarvis: Accessibility, Screen Recording, Microphone,
     Camera (System Settings -> Privacy & Security).
  4. Sign into Mail and Chrome — the corpus drives real accounts.
  5. Run the full suite inside that session:
       BENCH_SET=all bench/run-suite.sh

LIST
}

if [[ "$(id -u)" != "0" ]]; then
  echo "create-test-user is a one-time HUMAN step and requires sudo."
  echo "Run exactly:  sudo scripts/bench/create-test-user.sh"
  checklist
  exit 1
fi

sysadminctl -addUser jevbench -fullName "Jev Bench" -password -
echo "user 'jevbench' created."
checklist
