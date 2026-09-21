#!/usr/bin/env python3
"""Serialize cooperating macOS integration commands across this user's worktrees."""
import fcntl
import os
from pathlib import Path
import subprocess
import sys


def main():
    if len(sys.argv) < 2:
        sys.exit("Usage: with-desktop-lock.py command [arguments ...]")
    directory = Path(os.environ.get("JARVIS_DESKTOP_LOCK_DIRECTORY",
                                    str(Path.home() / "Library" / "Caches" / "JarvisDevelopment")))
    directory.mkdir(parents=True, exist_ok=True)
    # Do not unlink: waiters must keep referring to the same inode.
    with (directory / "desktop.lock").open("a") as lock:
        print("Waiting for the Jarvis desktop test lock…", flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
        # Inherit the descriptor so a surviving child keeps the lock if this
        # wrapper is interrupted. Conductor terminates its process group.
        result = subprocess.run(sys.argv[1:], pass_fds=(lock.fileno(),))
        return result.returncode if result.returncode >= 0 else 128 - result.returncode


if __name__ == "__main__":
    sys.exit(main())
