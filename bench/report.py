#!/usr/bin/env python3
"""Aggregate a bench results jsonl -> baseline.json + baseline-report.md.

  python3 bench/report.py <results.jsonl> [--outdir DIR] [--tasks-dir DIR]

Per task: runs, successes (verified rows), success_rate, wilson_low (95%),
p50_ms, p95_ms, budget.p50_ms, meets_budget, false_done, status histogram.
Latency percentiles use only rows that did a real drive_until round trip
(classifier vocabulary); harness statuses count as runs/failures, never
latency. Stdlib only.
"""

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from lib.results import STATUSES, TIER_BARS_MS, load_corpus
from lib.wilson import percentile, wilson_low

REPO_ROOT = Path(__file__).resolve().parent.parent


def load_rows(path):
    rows = []
    for line in Path(path).read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            pass  # a torn line is skipped, not fatal
    return rows


def real_walls(rows):
    """wall_ms of rows that did a real drive_until round trip."""
    return [r["wall_ms"] for r in rows
            if r.get("status") in STATUSES
            and isinstance(r.get("wall_ms"), (int, float))
            and not isinstance(r.get("wall_ms"), bool)]

def successful(row):
    """A passing end-state alone does not prove a command actually completed."""
    return (row.get("verified") is True and row.get("is_error") is False
            and row.get("status") in ("done", "already"))


def task_stats(rows, task):
    n = len(rows)
    succ = sum(1 for r in rows if successful(r))
    walls = real_walls(rows)
    p50, p95 = percentile(walls, 50), percentile(walls, 95)
    budget = (task or {}).get("budget") or {}
    bp50 = budget.get("p50_ms")
    meets = (p50 <= bp50) if p50 is not None and isinstance(bp50, int) \
        else "n/a"
    hist = {}
    for r in rows:
        k = str(r.get("status", "?"))
        hist[k] = hist.get(k, 0) + 1
    return {"runs": n, "successes": succ,
            "success_rate": round(succ / n, 4) if n else 0.0,
            "wilson_low": round(wilson_low(succ, n), 4),
            "p50_ms": p50, "p95_ms": p95,
            "budget_p50_ms": bp50, "tier": budget.get("tier"),
            "meets_budget": meets,
            "false_done": sum(1 for r in rows if r.get("false_done")),
            "statuses": hist}


def rollup(rows, tier):
    n = len(rows)
    succ = sum(1 for r in rows if successful(r))
    p50 = percentile(real_walls(rows), 50)
    bar = TIER_BARS_MS.get(tier)
    return {"runs": n, "successes": succ,
            "success_rate": round(succ / n, 4) if n else 0.0,
            "wilson_low": round(wilson_low(succ, n), 4),
            "p50_ms": p50, "bar_p50_ms": bar,
            "meets_bar": (p50 <= bar) if p50 is not None and bar else "n/a",
            "false_done": sum(1 for r in rows if r.get("false_done"))}


def fmt(v, nd=0):
    if v is None or v == "n/a":
        return "n/a"
    return ("%.*f" % (nd, v)) if isinstance(v, float) else str(v)


def write_report(path, baseline, rows_by_task):
    L = ["# jev bench baseline", "",
         "Generated %s from `%s` (%d rows)."
         % (baseline["generated_at"], baseline["input"],
            baseline["totals"]["runs"]),
         "Env snapshot: `%s`" % (baseline["env_file"] or "none"), "",
         "## Per-task", "",
         "| task | tier | runs | succ | rate | wilson_low | p50_ms | "
         "p95_ms | budget_ms | meets | false_done |",
         "|---|---|---|---|---|---|---|---|---|---|---|"]
    for tid, s in baseline["tasks"].items():
        L.append("| %s | %s | %d | %d | %.2f | %.3f | %s | %s | %s | %s | %d |"
                 % (tid, s["tier"] or "?", s["runs"], s["successes"],
                    s["success_rate"], s["wilson_low"], fmt(s["p50_ms"]),
                    fmt(s["p95_ms"]), fmt(s["budget_p50_ms"]),
                    s["meets_budget"], s["false_done"]))
    L += ["", "## Tier rollups", "",
          "Release bars (p50): T0<500 T1<1500 T2<3000 T3<4000 TB<15000 "
          "T4<60000 ms.", "",
          "| tier | tasks | runs | succ | wilson_low | p50_ms | bar_ms | "
          "meets_bar |", "|---|---|---|---|---|---|---|---|"]
    for tier, s in baseline["tiers"].items():
        L.append("| %s | %d | %d | %d | %.3f | %s | %s | %s |"
                 % (tier, len(s["tasks"]), s["runs"], s["successes"],
                    s["wilson_low"], fmt(s["p50_ms"]), fmt(s["bar_p50_ms"]),
                    s["meets_bar"]))
    L += ["", "## Blocked / missing (non-pass reasons, verbatim)", ""]
    any_block = False
    for tid, rows in rows_by_task.items():
        seen = {}
        for r in rows:
            if successful(r):
                continue
            key = (r.get("status", "?"), r.get("verdict", "?"))
            seen.setdefault(key, [0, ""])
            seen[key][0] += 1
            if r.get("evidence") and not seen[key][1]:
                seen[key][1] = r["evidence"]
        for (status, verdict), (count, ev) in sorted(seen.items()):
            any_block = True
            L.append("- `%s`: %s/%s x%d — %s"
                     % (tid, status, verdict, count, ev or "(no evidence)"))
    if not any_block:
        L.append("- none — every row verified.")
    L += ["", "## What this does NOT prove", "",
          "- `wall_ms` is the MCP roundtrip only — no voice-path "
          "(Fn/ASR) latency and no per-step spans yet (reserved `spans`).",
          "- A `pass` is the independent end-state check — the result "
          "text's `Done.` is never trusted (`false_done` column).",
          "- Harness statuses (dry_run, setup_error, blocked:keychain) "
          "count as failures, never as latency samples.",
          "- The BENCH_STUB backend proves the harness, not the app.",
          "- The local-safe set says nothing about the test-user corpus "
          "until that session runs `BENCH_SET=all`.",
          ""]
    Path(path).write_text("\n".join(L))


def main(argv=None):
    p = argparse.ArgumentParser(prog="bench/report.py",
                                description=__doc__)
    p.add_argument("results")
    p.add_argument("--outdir", default=None)
    p.add_argument("--tasks-dir", default=str(REPO_ROOT / "bench" / "tasks"))
    args = p.parse_args(argv)
    results_path = Path(args.results)
    if not results_path.is_file():
        print("harness error: no results file %s" % results_path,
              file=sys.stderr)
        return 2
    outdir = Path(args.outdir) if args.outdir else results_path.parent
    rows = load_rows(results_path)
    if not rows:
        print("harness error: no result rows in %s" % results_path, file=sys.stderr)
        return 2
    outdir.mkdir(parents=True, exist_ok=True)
    corpus = {}
    try:
        for t in load_corpus(args.tasks_dir):  # fs checks off: report-only
            corpus[t["id"]] = t
    except ValueError as exc:
        print("warning: corpus not loaded (%s) — budgets n/a" % exc,
              file=sys.stderr)
    order, rows_by_task = [], {}
    for r in rows:
        tid = str(r.get("task", "?"))
        if tid not in rows_by_task:
            order.append(tid)
            rows_by_task[tid] = []
        rows_by_task[tid].append(r)
    for tid in sorted(corpus):  # corpus tasks with no rows still listed
        rows_by_task.setdefault(tid, [])
    tasks = {tid: task_stats(rows_by_task[tid], corpus.get(tid))
             for tid in order}
    by_tier = {}
    for tid, s in tasks.items():
        by_tier.setdefault(s["tier"] or "?", []).append(tid)
    tiers = {}
    for tier, tids in sorted(by_tier.items()):
        tier_rows = [r for tid in tids for r in rows_by_task[tid]]
        s = rollup(tier_rows, tier if tier != "?" else None)
        s["tasks"] = tids
        tiers[tier] = s
    n = len(rows)
    succ = sum(1 for r in rows if successful(r))
    env_files = sorted(outdir.glob("env-*.json"))
    baseline = {
        "generated_at": datetime.now(timezone.utc)
            .isoformat(timespec="seconds").replace("+00:00", "Z"),
        "input": str(results_path),
        "env_file": env_files[-1].name if env_files else None,
        "tasks": tasks, "tiers": tiers,
        "totals": {"runs": n, "successes": succ,
                   "success_rate": round(succ / n, 4) if n else 0.0,
                   "wilson_low": round(wilson_low(succ, n), 4),
                   "false_done": sum(1 for r in rows
                                    if r.get("false_done"))},
    }
    json_path = outdir / "baseline.json"
    md_path = outdir / "baseline-report.md"
    json_path.write_text(json.dumps(baseline, indent=2, sort_keys=True) + "\n")
    write_report(md_path, baseline, rows_by_task)
    print("baseline: %s" % json_path)
    print("report:   %s" % md_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
