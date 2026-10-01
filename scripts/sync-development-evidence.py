#!/usr/bin/env python3
"""Copy the small evidence/manifest layer of development/JevVoice into this checkout.

The development asset pile lives outside the repo (or in a sibling folder) and
its binaries stay gitignored. Text records (.json/.md/.txt/.log) are tracked —
see .gitignore — so this script materializes them into the checkout for commit.

iCloud-evicted ("dataless") files materialize on read; reads block on the fetch,
so running this while iCloud is reachable pulls them down and copies them in.

Usage: python3 scripts/sync-development-evidence.py [--source <pile>/development/JevVoice]
"""

from __future__ import annotations

import argparse
import os
import sys

TEXT_EXTS = {".json", ".md", ".txt", ".log"}
SKIP_PARTS = {"cua-source"}
SKIP_SUFFIX = ".app"


def iter_files(root: str):
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [
            d
            for d in dirnames
            if d not in SKIP_PARTS and not d.endswith(SKIP_SUFFIX) and d != "checkout"
        ]
        for name in filenames:
            if os.path.splitext(name)[1] in TEXT_EXTS:
                yield os.path.relpath(os.path.join(dirpath, name), root)


def main() -> int:
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source",
        default=os.environ.get(
            "JARVIS_DEVELOPMENT_SOURCE",
            os.path.join(os.path.dirname(repo), "JarvisMacOSv1", "development", "JevVoice"),
        ),
    )
    args = parser.parse_args()
    src, dst = args.source, os.path.join(repo, "development", "JevVoice")

    ok = fail = 0
    for rel in iter_files(src):
        out = os.path.join(dst, rel)
        try:
            with open(os.path.join(src, rel), "rb") as f:
                data = f.read()
        except OSError:
            fail += 1
            continue
        if not data:
            continue
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with open(out, "wb") as f:
            f.write(data)
        ok += 1

    print(f"synced {ok} files into {dst}; {fail} could not be read (iCloud-evicted?)")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
