#!/usr/bin/env python3
"""Compare non-owned changes with the phase's recorded dirty baseline."""
import fnmatch
from pathlib import Path
import re
import subprocess

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[1]
OWNED = (
    "spikes/speech-bakeoff/**", "scripts/verification-lane.sh", ".agent/PROGRESS.md",
    ".agent/phases/P2d-speech-bakeoff.md", ".agent/acceptance/P2d.json",
)


def owned(path):
    return any(fnmatch.fnmatchcase(path, pattern) for pattern in OWNED)


def sections(diff):
    parts = re.split(r"(?m)^(?=diff --git )", diff)
    output = {}
    for part in parts:
        if not part.startswith("diff --git "):
            continue
        header = part.splitlines()[0]
        path = header.split(" b/", 1)[1]
        if not owned(path):
            output[path] = part
    return output


def statuses(status):
    return {line[3:] for line in status.splitlines() if len(line) > 3 and not owned(line[3:])}


def main():
    baseline = (PACKAGE / "results/dirty-baseline.txt").read_text()
    header, _, diff = baseline.partition("diff --git ")
    before = sections("diff --git " + diff)
    current_status = subprocess.check_output(["git", "status", "--porcelain"], cwd=ROOT, text=True)
    current_diff = subprocess.check_output(["git", "diff"], cwd=ROOT, text=True)
    after = sections(current_diff)
    new_paths = statuses(current_status) - statuses(header)
    changed = [path for path in before.keys() | after.keys() if before.get(path) != after.get(path)]
    assert not new_paths, f"new non-owned paths (review concurrent work): {sorted(new_paths)}"
    assert not changed, f"non-owned baseline hunks changed (review concurrent work): {changed}"
    print(f"PASS baseline-aware scope: 0 new non-owned paths, 0 changed non-owned diff sections ({len(before)} compared)")


if __name__ == "__main__":
    main()
