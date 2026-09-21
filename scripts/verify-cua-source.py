#!/usr/bin/env python3
"""Verify preserved Cua source files without reading its broken local Git metadata."""
import argparse
import hashlib
import json
from pathlib import Path
import sys


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="Cua source root (not the Jarvis root)")
    args = parser.parse_args()
    integration = Path(__file__).resolve().parent.parent / "ThirdParty" / "Cua"
    manifest = json.loads((integration / "source-manifest.json").read_text())
    patch = integration / "local-integration.patch"
    if hashlib.sha256(patch.read_bytes()).hexdigest() != manifest["patch_sha256"]:
        sys.exit("Integration patch does not match its recorded hash")
    failures = []
    executables = set(manifest["executable_files"])
    for name, expected in manifest["files"].items():
        path = args.source / name
        if (not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected
                or bool(path.stat().st_mode & 0o111) != (name in executables)):
            failures.append(name)
    if failures:
        sys.exit("Missing or changed source files:\n" + "\n".join(failures))
    print(f"Verified {len(manifest['files'])} preserved source files and integration patch")
    print("Additional upstream files are allowed; binaries, models and runtime acceptance are not checked.")


if __name__ == "__main__":
    main()
