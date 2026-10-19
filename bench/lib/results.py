"""Result-text classifier, result-row schema, corpus validation.

The classifier's input is a drive_until result frame's text + isError —
the complete vocabulary is pinned in .agent/phases/P1-bench.md Context
("Result vocabulary"). isError always wins.
"""

import json
import re
from datetime import datetime, timezone
from pathlib import Path

from lib.verifiers import VERIFIER_KINDS

# classify() output — rows whose status is one of these did a real
# drive_until round trip and count toward latency percentiles.
STATUSES = ("done", "already", "blocked", "refused_permanent", "stuck",
            "needs_input", "ambiguous", "maxsteps", "cancelled", "error")
# Harness-level row statuses — counted as runs (failures), never latency.
HARNESS_STATUSES = ("dry_run", "setup_error", "blocked:keychain")
HERO_JOBS = ("inbox", "browser", "gaze", "calendar", "notes", "utility")
REQUIRES = ("local-safe", "test-user", "human")
TIERS = ("T0", "T1", "T2", "T3", "TB", "T4")
TIER_BARS_MS = {"T0": 500, "T1": 1500, "T2": 3000, "T3": 4000,
                "TB": 15000, "T4": 60000}
_ID_RE = re.compile(r"^[a-z0-9]+(\.[a-z0-9-]+)+$")


def classify(text, is_error):
    """Result frame -> status. isError first, then the text vocabulary."""
    if is_error:
        return "error"
    t = (text or "").strip()
    if t.startswith("Done."):
        return "done"
    if t.startswith("Already satisfied:"):
        return "already"
    if t.endswith("No grant or approval path changes that."):
        return "refused_permanent"
    if t.startswith("Blocked:"):
        return "blocked"
    if t.startswith("Stuck:"):
        return "stuck"
    if t.startswith("Needs input:"):
        return "needs_input"
    if t.startswith("Ambiguous:"):
        return "ambiguous"
    if t.startswith("Ran out of steps."):
        return "maxsteps"
    if t.startswith("Cancelled."):
        return "cancelled"
    return "error"


def make_row(task_id, run, wall_ms, text, is_error, verdict, evidence,
             status=None):
    """One results-jsonl row (schema v1). `status` overrides classify()
    for harness-level outcomes (setup_error, blocked:keychain, dry_run)."""
    status = status if status is not None else classify(text, is_error)
    verified = verdict == "pass"
    return {
        "v": 1,
        "ts": datetime.now(timezone.utc)
              .isoformat(timespec="milliseconds").replace("+00:00", "Z"),
        "task": task_id,
        "run": run,
        "wall_ms": round(float(wall_ms), 1),
        "status": status,
        "is_error": bool(is_error),
        "verdict": verdict,
        "verified": verified,
        "false_done": status in ("done", "already") and verdict == "fail",
        "result_text": (text or "")[:500],
        "evidence": (evidence or "")[:300],
        "spans": {},
    }


def _pos_int(v):
    return isinstance(v, int) and not isinstance(v, bool) and v > 0


def validate_task(t, repo_root=None):
    """None when the task satisfies contract section 7, else the first
    violation message. repo_root enables the setup-file existence check."""
    if not isinstance(t, dict):
        return "task is not a JSON object"
    tid = t.get("id")
    if not isinstance(tid, str) or not _ID_RE.match(tid):
        return "id must be a dotted.slug like 'inbox.read-latest'"
    if t.get("hero_job") not in HERO_JOBS:
        return "hero_job must be one of %s" % (HERO_JOBS,)
    if not isinstance(t.get("prompt"), str) or not t["prompt"].strip():
        return "prompt must be a non-empty string"
    if t.get("inject", "mcp_stdio") != "mcp_stdio":
        return 'inject must be "mcp_stdio"'
    if t.get("requires") not in REQUIRES:
        return "requires must be one of %s" % (REQUIRES,)
    if "app" in t and not isinstance(t["app"], str):
        return "app must be a string"
    if "setup" in t:
        if not isinstance(t["setup"], str):
            return "setup must be a path string"
        if repo_root is not None and \
                not (Path(repo_root) / t["setup"]).is_file():
            return "setup script not found: %s" % t["setup"]
    success = t.get("success")
    if not isinstance(success, dict) or \
            success.get("kind") not in VERIFIER_KINDS:
        return "success.kind must be one of %s" % (sorted(VERIFIER_KINDS),)
    if not isinstance(success.get("expect"), dict):
        return "success.expect must be an object"
    budget = t.get("budget")
    if not isinstance(budget, dict) or not _pos_int(budget.get("p50_ms")) \
            or budget.get("tier") not in TIERS:
        return "budget needs int p50_ms>0 and tier in %s" % (TIERS,)
    if not isinstance(t.get("tags"), list):
        return "tags must be a list"
    runs = t.get("runs")
    floor = 1 if t.get("requires") == "human" else 5
    if not _pos_int(runs) or runs < floor:
        return "runs must be an int >=5 (>=1 for human tasks)"
    return None


def load_corpus(tasks_dir, repo_root=None):
    """Parse + validate every tasks/*.json. ValueError on a bad corpus."""
    tasks = []
    for path in sorted(Path(tasks_dir).glob("*.json")):
        try:
            task = json.loads(path.read_text())
        except (OSError, json.JSONDecodeError) as exc:
            raise ValueError("%s: %s" % (path.name, exc))
        err = validate_task(task, repo_root=repo_root)
        if err:
            raise ValueError("%s: %s" % (path.name, err))
        tasks.append(task)
    return tasks
