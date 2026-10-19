#!/usr/bin/env python3
"""Enforce a phase's owned-paths list (PLANS.md §5, ExecPlan "Owned paths").

Reads the ```text fenced "Owned paths" block of .agent/phases/P<n>-*.md
(one repo-relative path or glob per line) and compares it to git state.

Modes:
  check-owned-paths.py P<n>          staged files only — "is this
                                     milestone commit in-bounds?"
  check-owned-paths.py P<n> --all    all dirty files — for clean-baseline
                                     worktrees where every dirty path is
                                     the phase's own write

Exit 0 = OK. Exit 1 = violations or unreadable plan. Exit 2 = bad usage.
"""
import fnmatch
import re
import subprocess
import sys
from pathlib import Path


def repo_root() -> Path:
    out = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True, text=True, check=True)
    return Path(out.stdout.strip())


def load_owned(phase: str, root: Path) -> list[str]:
    plans = sorted((root / ".agent" / "phases").glob(f"{phase}-*.md"))
    plans += sorted((root / ".agent" / "phases").glob(f"{phase}.md"))
    if not plans:
        raise SystemExit(f"no ExecPlan found for phase {phase}")
    text = plans[0].read_text()
    m = re.search(r"## Owned paths\s+```text\s+(.*?)```", text, re.S)
    if not m:
        raise SystemExit(f"{plans[0].name}: no ```text Owned paths block")
    owned = []
    for line in m.group(1).splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            owned.append(line)
    return owned


def owned_match(path: str, owned: list[str]) -> bool:
    for pat in owned:
        if pat.endswith("/**"):
            base = pat[:-3].rstrip("/")
            if path == base or path.startswith(base + "/"):
                return True
        elif fnmatch.fnmatch(path, pat) or path == pat:
            return True
    return False


def staged_paths(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "diff", "--cached", "--name-only", "--diff-filter=ACMRD"],
        cwd=root, capture_output=True, text=True, check=True)
    return [p for p in out.stdout.splitlines() if p.strip()]


def dirty_paths(root: Path) -> list[str]:
    out = subprocess.run(
        ["git", "status", "--porcelain"], cwd=root,
        capture_output=True, text=True, check=True)
    paths = []
    for line in out.stdout.splitlines():
        if len(line) < 4:
            continue
        p = line[3:]
        if " -> " in p:
            p = p.split(" -> ", 1)[1]
        paths.append(p.strip().strip('"'))
    return paths


def main() -> int:
    argv = sys.argv[1:]
    check_all = "--all" in argv
    argv = [a for a in argv if a != "--all"]
    if len(argv) != 1:
        print(__doc__.strip())
        return 2
    phase = argv[0]
    root = repo_root()
    owned = load_owned(phase, root)
    paths = dirty_paths(root) if check_all else staged_paths(root)
    scope = "dirty" if check_all else "staged"
    violations = [p for p in paths if not owned_match(p, owned)]
    if violations:
        print(f"OWNED-PATHS VIOLATIONS for {phase} ({scope} files):")
        for v in violations:
            print(f"  {v}")
        return 1
    print(f"OK — {len(paths)} {scope} file(s) inside {phase} owned set "
          f"({len(owned)} patterns)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
