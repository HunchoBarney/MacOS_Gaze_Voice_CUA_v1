import argparse
import math
import os
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path


def terminate(child):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        child.wait()


def run(command, directory, minimum, stop):
    if shutil.disk_usage(directory).free < minimum * 2**30:
        print("Insufficient build space; no child was started.", file=sys.stderr)
        return 75
    child = subprocess.Popen(command, start_new_session=True)
    deadline = time.monotonic() + 3600
    try:
        while True:
            if shutil.disk_usage(directory).free < stop * 2**30:
                print("Insufficient build space; stopping this build's process group.",
                      file=sys.stderr)
                terminate(child)
                return 75
            if time.monotonic() >= deadline:
                print("Build exceeded its one-hour deadline.", file=sys.stderr)
                terminate(child)
                return 124
            try:
                return child.wait(timeout=0.25)
            except subprocess.TimeoutExpired:
                pass
    finally:
        if child.poll() is None:
            terminate(child)


def interrupted(signum, frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--directory", type=Path, required=True)
    parser.add_argument("--minimum-free-gib", type=float, default=5)
    parser.add_argument("--stop-free-gib", type=int, default=1)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not all(math.isfinite(value) and value >= 0
                              for value in (args.minimum_free_gib, args.stop_free_gib)):
        parser.error("A command and finite nonnegative space budgets are required.")
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return run(command, args.directory, args.minimum_free_gib, args.stop_free_gib)
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
