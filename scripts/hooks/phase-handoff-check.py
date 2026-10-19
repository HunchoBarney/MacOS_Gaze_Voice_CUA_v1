#!/usr/bin/env python3
"""Stop hook: a session may not end leaving phase artifacts dirty
without a PROGRESS.md update (PLANS.md §8 handoff rule).

Reads nothing on stdin (the Stop payload carries no useful fields for
this). Inspects `git status --porcelain`:

  .agent/phases/** or .agent/acceptance/** dirty
    AND .agent/PROGRESS.md clean   -> block with reason
  otherwise                        -> pass

Exit 0 = allow stop. Exit 2 = block (reason also printed as JSON).
"""
import json
import subprocess
import sys


def dirty() -> list[str]:
    # -uall: list untracked files individually so a fully-untracked
    # .agent/ tree still surfaces .agent/phases/ paths. ` -> ` splits
    # rename lines to the destination path.
    out = subprocess.run(
        ["git", "status", "--porcelain", "-uall"],
        capture_output=True, text=True)
    if out.returncode != 0:
        return []
    paths = []
    for ln in out.stdout.splitlines():
        if len(ln) <= 3:
            continue
        p = ln[3:]
        if " -> " in p:
            p = p.split(" -> ", 1)[1]
        paths.append(p.strip().strip('"'))
    return paths


def main() -> int:
    paths = dirty()
    phase_dirty = any(
        p.startswith(".agent/phases/") or p.startswith(".agent/acceptance/")
        for p in paths)
    progress_dirty = any(p == ".agent/PROGRESS.md" for p in paths)
    if phase_dirty and not progress_dirty:
        print(json.dumps({
            "decision": "block",
            "reason": ("Phase artifacts under .agent/phases or "
                       ".agent/acceptance are dirty but .agent/PROGRESS.md "
                       "has no update. Write the handoff entry (did / "
                       "evidence / next) before stopping.")
        }))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
