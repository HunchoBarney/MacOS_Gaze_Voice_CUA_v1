#!/usr/bin/env python3
"""Inspect only candidate artifacts, never audio, build caches or credentials."""
import json
from pathlib import Path
import re
import subprocess

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[1]


def main():
    pinned = json.loads((PACKAGE / "Package.resolved").read_text())["pins"]
    assert len(pinned) == 1 and pinned[0]["identity"] == "fluidaudio"
    assert pinned[0]["state"]["version"] == "0.17.5"
    tracked = subprocess.check_output(
        ["git", "ls-files", "spikes/speech-bakeoff"], cwd=ROOT, text=True,
    ).splitlines()
    assert not any(path.endswith((".wav", ".pcm")) or "/recordings/" in path for path in tracked)
    patterns = re.compile(
        r"sk-(?:proj-)?[A-Za-z0-9_-]{32,}|Bearer [A-Za-z0-9._-]{24,}|"
        r"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"
    )
    findings = []
    inspected = 0
    for path in PACKAGE.rglob("*"):
        relative = path.relative_to(PACKAGE)
        if any(part in {".build", "__pycache__", "recordings"} for part in relative.parts):
            continue
        if path.is_symlink() or not path.is_file():
            continue
        if path.suffix not in {".swift", ".py", ".json", ".md", ".txt", ".log", ".resolved"}:
            continue
        inspected += 1
        for number, line in enumerate(path.read_text(errors="replace").splitlines(), 1):
            if patterns.search(line):
                findings.append(f"{relative}:{number}")  # Never print candidate secret contents.
    assert not findings, f"credential-shaped strings need review (values withheld): {findings}"
    print(f"PASS: FluidAudio 0.17.5, no tracked audio, no credential-shaped strings in {inspected} candidate text files")


if __name__ == "__main__":
    main()
