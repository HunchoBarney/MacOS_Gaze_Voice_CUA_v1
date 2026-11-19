#!/usr/bin/env python3
"""jev-bench runner — inject corpus prompts through
`JevVoice --mcp-stdio --agent bench` (drive_until), verify end-state
independently, append result rows to a jsonl.

Python 3 stdlib only. Sequential always. Task failures are data (rows),
not crashes — exit 2 is reserved for hard harness errors (bad corpus,
missing binary on a real run, unknown --task id).

  python3 bench/run.py [--task ID]* [--tag T]*
      [--set local-safe|test-user|all] [--runs N] [--out PATH]
      [--binary PATH] [--timeout SEC=120] [--stub] [--dry-run] [--verbose]
      [--tasks-dir PATH]

--stub or BENCH_STUB=1 selects bench/lib/stub_server.py as the backend.
--dry-run = setup + verify only (no MCP spawn); rows carry status
"dry_run". requires=="human" tasks are never injected — printed skip only.
"""

import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.mcp_stdio import MCPError, MCPStdio, require_api_key, resolve_binary
from lib.results import load_corpus, make_row
from lib.verifiers import verify

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_TASKS = REPO_ROOT / "bench" / "tasks"
STUB_SERVER = REPO_ROOT / "bench" / "lib" / "stub_server.py"
SETUP_TIMEOUT = 60


def out_default():
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    return REPO_ROOT / "bench" / "results" / ("results-%s.jsonl" % stamp)


def parse_args(argv):
    p = argparse.ArgumentParser(prog="bench/run.py", description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--task", action="append", default=[], metavar="ID")
    p.add_argument("--tag", action="append", default=[], metavar="T")
    p.add_argument("--set", default=os.environ.get("BENCH_SET", "local-safe"),
                   choices=("local-safe", "test-user", "all"),
                   dest="bench_set")
    p.add_argument("--runs", type=int, default=None)
    p.add_argument("--out", default=None)
    p.add_argument("--binary", default=None)
    p.add_argument("--timeout", type=float, default=120.0)
    p.add_argument("--stub", action="store_true")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--verbose", action="store_true")
    p.add_argument("--tasks-dir", default=str(DEFAULT_TASKS))
    return p.parse_args(argv)


def select(tasks, ids, tags, bench_set):
    """-> (chosen, skipped[(task, reason)]). human is never selected."""
    allowed = {"local-safe", "test-user"} if bench_set == "all" \
        else {bench_set}
    explicit = bool(ids or tags)
    wanted = set(tags)
    chosen, skipped = [], []
    for t in tasks:
        if explicit and t["id"] not in ids and \
                not (set(t.get("tags", [])) & wanted):
            continue
        if t["requires"] == "human":
            skipped.append((t, 'requires "human" — recorded, never injected'))
        elif t["requires"] not in allowed:
            skipped.append((t, 'requires "%s" not in --set %s'
                            % (t["requires"], bench_set)))
        else:
            chosen.append(t)
    if ids:
        known = {t["id"] for t in tasks}
        missing = [i for i in ids if i not in known]
        if missing:
            raise ValueError("unknown --task id(s): %s" % ", ".join(missing))
    return chosen, skipped


def run_setup(task, verbose=False):
    """Run the task's reset script via bash, cwd=repo root. None on
    success, else an evidence string (row status setup_error)."""
    setup = task.get("setup")
    if not setup:
        return None
    path = REPO_ROOT / setup
    try:
        out = subprocess.run(["bash", str(path)], cwd=str(REPO_ROOT),
                             capture_output=True, text=True,
                             timeout=SETUP_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return "setup %s failed to run: %s" % (setup, exc)
    if verbose and (out.stdout.strip() or out.stderr.strip()):
        print("  setup %s: %s %s"
              % (setup, out.stdout.strip(), out.stderr.strip()))
    if out.returncode != 0:
        return "setup %s rc=%s: %s" % (
            setup, out.returncode, (out.stderr or out.stdout).strip()[:200])
    return None


_spawn_seq = [0]


def spawn_client(stub, binary, env):
    # Unique slug per child: the daemon tombstones a session label to its
    # dead proxy owner, and a reused slug can wedge every later call on a
    # killed transport (P1 finding — see phases/P1-bench.md Surprises).
    _spawn_seq[0] += 1
    slug = "bench-%d-%d" % (os.getpid(), _spawn_seq[0])
    argv = [sys.executable, str(STUB_SERVER)] if stub else \
        [binary, "--mcp-stdio", "--agent", slug]
    client = MCPStdio(argv, env=env, cwd=str(REPO_ROOT))
    try:
        client.start()
        client.initialize()
    except Exception:
        client.close()
        raise
    return client


def emit_row(row, writer, n, runs):
    writer.write(json.dumps(row, separators=(",", ":")) + "\n")
    writer.flush()
    print("%s run %d/%d -> %s verdict=%s verified=%s %.0fms"
          % (row["task"], n, runs, row["status"], row["verdict"],
             row["verified"], row["wall_ms"]))


def run_task(task, runs, writer, *, stub, binary, env, timeout,
             dry_run, verbose):
    tid = task["id"]
    if not stub and not dry_run:
        for n in range(1, runs + 1):
            emit_row(make_row(
                tid, n, 0.0, "", True, "error",
                "BLOCKED: trusted operator handoff unavailable",
                status="blocked:operator_handoff"), writer, n, runs)
        return
    client = None

    def ensure_client():
        nonlocal client
        if client is None or client.proc is None or \
                client.proc.poll() is not None:
            client = spawn_client(stub, binary, env)  # may raise MCPError

    for n in range(1, runs + 1):
        err = run_setup(task, verbose)
        if dry_run:
            if err:
                row = make_row(tid, n, 0.0, "", True, "error", err,
                               status="setup_error")
            else:
                v = verify(task["success"], "", None)
                row = make_row(tid, n, 0.0, "", False, v["verdict"],
                               v["evidence"], status="dry_run")
            emit_row(row, writer, n, runs)
            continue
        if err:
            emit_row(make_row(tid, n, 0.0, "", True, "error", err,
                              status="setup_error"), writer, n, runs)
            continue
        t0 = time.perf_counter()
        wall_ms = 0.0
        try:
            ensure_client()
            text, is_error, wall_ms = client.drive_until(
                task["prompt"], app=task.get("app"), timeout=timeout)
        except (MCPError, OSError) as exc:
            wall_ms = (time.perf_counter() - t0) * 1000.0
            if client is not None:
                client.close()
            client = None  # respawn next run
            emit_row(make_row(tid, n, wall_ms, "", True, "error",
                              "mcp: %s" % exc), writer, n, runs)
            continue
        if verbose:
            print("  result: %r is_error=%s" % (text[:200], is_error))
        v = verify(task["success"], text, None)
        emit_row(make_row(tid, n, wall_ms, text, is_error,
                          v["verdict"], v["evidence"]), writer, n, runs)
    if client is not None:
        client.close()


def main(argv=None):
    args = parse_args(argv)
    try:
        tasks = load_corpus(args.tasks_dir, repo_root=REPO_ROOT)
        if not tasks:
            raise ValueError("no task files in %s" % args.tasks_dir)
        chosen, skipped = select(tasks, args.task, args.tag, args.bench_set)
    except ValueError as exc:
        print("harness error: %s" % exc, file=sys.stderr)
        return 2
    for t, why in skipped:
        print("skip %s — %s" % (t["id"], why))
    stub = args.stub or os.environ.get("BENCH_STUB", "") not in ("", "0")
    out_path = Path(args.out) if args.out else out_default()
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "a") as writer:
        for task in chosen:
            child_env = dict(os.environ)
            run_task(task, args.runs or task["runs"], writer,
                     stub=stub, binary=args.binary, env=child_env,
                     timeout=args.timeout, dry_run=args.dry_run,
                     verbose=args.verbose)
    print("results: %s" % out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
