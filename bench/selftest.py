#!/usr/bin/env python3
"""jev-bench unit suite — stdlib unittest, no third-party deps.

  python3 bench/selftest.py     exit 0 = green
"""

import json
import os
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

BENCH = Path(__file__).resolve().parent
REPO_ROOT = BENCH.parent
sys.path.insert(0, str(BENCH))

from lib.mcp_stdio import MCPError, MCPStdio, tool_text
from lib.results import (HERO_JOBS, classify, load_corpus, make_row,
                         validate_task)
from lib.verifiers import verify
from lib.wilson import p50, p95, wilson_low

TASKS_DIR = BENCH / "tasks"
STUB = BENCH / "lib" / "stub_server.py"


class CorpusCase(unittest.TestCase):
    """(a) every tasks/*.json validates against contract section 7."""

    def test_all_tasks_valid(self):
        tasks = load_corpus(TASKS_DIR, repo_root=REPO_ROOT)
        self.assertGreaterEqual(len(tasks), 14)
        for t in tasks:
            self.assertIsNone(validate_task(t, repo_root=REPO_ROOT),
                              t.get("id"))

    def test_corpus_coverage(self):
        tasks = load_corpus(TASKS_DIR, repo_root=REPO_ROOT)
        local_safe = [t for t in tasks if t["requires"] == "local-safe"]
        self.assertGreaterEqual(len(local_safe), 5)
        self.assertEqual(set(HERO_JOBS), {t["hero_job"] for t in tasks})

    def test_no_mutating_apps_under_local_safe(self):
        for p in TASKS_DIR.glob("*.json"):
            raw = p.read_text()
            if json.loads(raw).get("requires") == "local-safe":
                self.assertIsNone(re.search(r"Mail|Calendar|Messages", raw),
                                  "%s names a mutating app" % p.name)


class MCPCase(unittest.TestCase):
    """(b) newline JSON-RPC roundtrip against the real stub subprocess."""

    def _client(self):
        c = MCPStdio([sys.executable, str(STUB)], env=dict(os.environ))
        c.start()
        return c

    def test_roundtrip(self):
        c = self._client()
        try:
            info = c.initialize()
            self.assertEqual(info["serverInfo"]["name"], "jev-bench-stub")
            tools = c.call("tools/list")
            self.assertEqual(len(tools["tools"]), 2)
            res = c.call("tools/call", {"name": "drive_until",
                                        "arguments": {"goal": "succeed"}})
            text, is_error = tool_text(res)
            self.assertEqual(text, "Done.")
            self.assertFalse(is_error)
        finally:
            c.close()
        self.assertIsNone(c.proc)

    def test_timeout_closes_and_reaps(self):
        c = self._client()
        proc = c.proc
        c.initialize()
        with self.assertRaises(MCPError):
            c.call("tools/call", {"name": "drive_until",
                                  "arguments": {"goal": "sleep"}},
                   timeout=1.5)
        self.assertIsNotNone(proc.poll())  # reaped — no zombie
        c.close()

    def test_iserror_frame(self):
        c = self._client()
        try:
            c.initialize()
            res = c.call("tools/call", {
                "name": "drive_until", "arguments": {"goal": "iserror"}})
            text, is_error = tool_text(res)
            self.assertTrue(is_error)
            self.assertIn("TYPESAFE_API_KEY", text)
        finally:
            c.close()


class ClassifierCase(unittest.TestCase):
    """(c) the complete result-text vocabulary + isError precedence."""

    CASES = [
        ("Done. tail", "done"),
        ("Already satisfied: x.", "already"),
        ("Refused. No grant or approval path changes that.",
         "refused_permanent"),
        ("Blocked: x", "blocked"),
        ("Stuck: x. tail", "stuck"),
        ("Needs input: text for x.", "needs_input"),
        ("Ambiguous: which of a, b?", "ambiguous"),
        ("Ran out of steps. x", "maxsteps"),
        ("Cancelled.", "cancelled"),
        ("some unrecognised text", "error"),
    ]

    def test_vocabulary(self):
        for text, want in self.CASES:
            self.assertEqual(classify(text, False), want, text)

    def test_iserror_wins(self):
        for text, _ in self.CASES:
            self.assertEqual(classify(text, True), "error", text)

    def test_false_done_flag(self):
        self.assertTrue(make_row("t.t", 1, 1.0, "Done.", False,
                                 "fail", "x")["false_done"])
        self.assertFalse(make_row("t.t", 1, 1.0, "Done.", False,
                                  "pass", "x")["false_done"])
        self.assertFalse(make_row("t.t", 1, 1.0, "Blocked: x", False,
                                  "fail", "x")["false_done"])


class VerifierCase(unittest.TestCase):
    """(d) verifiers on fixtures; AX/DOM via an injected runner."""

    def test_speaks_substring(self):
        s = {"kind": "speaks_substring", "expect": {"text": "Marker"}}
        self.assertEqual(verify(s, "well marker here")["verdict"], "pass")
        self.assertEqual(verify(s, "nope")["verdict"], "fail")

    def test_file_state(self):
        with tempfile.TemporaryDirectory() as d:
            p = os.path.join(d, "m.txt")
            s = {"kind": "file_state",
                 "expect": {"path": p, "must": "exists"}}
            self.assertEqual(verify(s)["verdict"], "fail")
            Path(p).write_text("jev marker")
            self.assertEqual(verify(s)["verdict"], "pass")
            s["expect"] = {"path": p, "must": "contains", "text": "marker"}
            self.assertEqual(verify(s)["verdict"], "pass")
            s["expect"] = {"path": p, "must": "absent"}
            self.assertEqual(verify(s)["verdict"], "fail")

    def test_ax_dom_frontmost_via_runner(self):
        def runner(argv):
            script = argv[-1]
            if "frontmost is true" in script:
                return 0, "Finder\n", ""
            if "exists (process" in script:
                return 0, "true\n", ""
            if "Safari" in script:
                return 0, "https://example.com/\n", ""
            if "value of" in script:
                return 0, "84\n", ""
            return 1, "", "Automation permission denied (-1743)"

        v = verify({"kind": "app_frontmost",
                    "expect": {"app": "Finder"}}, "", runner)
        self.assertEqual(v["verdict"], "pass")
        v = verify({"kind": "ax_state",
                    "expect": {"app": "Calculator", "check": "running"}},
                   "", runner)
        self.assertEqual(v["verdict"], "pass")
        v = verify({"kind": "ax_state",
                    "expect": {"app": "Calculator", "check": "not_running"}},
                   "", runner)
        self.assertEqual(v["verdict"], "fail")
        v = verify({"kind": "ax_state",
                    "expect": {"app": "Calculator",
                               "queries": ["value of x"], "contains": "84"}},
                   "", runner)
        self.assertEqual(v["verdict"], "pass")
        v = verify({"kind": "dom_state",
                    "expect": {"browser": "Safari", "text": "example.com"}},
                   "", runner)
        self.assertEqual(v["verdict"], "pass")

    def test_osascript_error_is_error_verdict(self):
        def err_runner(argv):
            return 1, "", "Automation permission denied (-1743)"
        v = verify({"kind": "dom_state",
                    "expect": {"browser": "Safari", "text": "x"}},
                   "", err_runner)
        self.assertEqual(v["verdict"], "error")
        self.assertIn("-1743", v["evidence"])


class WilsonCase(unittest.TestCase):
    """(e) Wilson lower bound + percentiles on known fixtures."""

    def test_bounds(self):
        self.assertEqual(wilson_low(0, 0), 0.0)
        self.assertAlmostEqual(wilson_low(5, 5), 0.566, places=2)
        self.assertEqual(wilson_low(0, 5), 0.0)
        self.assertAlmostEqual(wilson_low(8, 10), 0.49, places=2)

    def test_percentiles(self):
        vals = [10, 20, 30, 40, 50]
        self.assertEqual(p50(vals), 30)
        self.assertEqual(p95(vals), 48)
        self.assertIsNone(p50([]))


class RunnerCase(unittest.TestCase):
    """(f) run.py --stub --dry-run end-to-end on a fixture corpus."""

    def test_empty_selection_refuses_before_side_effects(self):
        import run
        with tempfile.TemporaryDirectory() as directory, patch.object(run, "resolve_binary") as binary, \
                patch.object(run, "require_api_key") as credentials:
            out = Path(directory) / "new" / "results.jsonl"
            for selection in (["--tag", "no-such-tag"], ["--task", "textedit.type"],
                              ["--task", "calc.open", "--set", "test-user"]):
                self.assertEqual(run.main([*selection, "--out", str(out)]), 2)
            binary.assert_not_called()
            credentials.assert_not_called()
            self.assertFalse(out.parent.exists())

    def test_dry_run_rows(self):
        import run as run_mod
        with tempfile.TemporaryDirectory() as d:
            tdir = Path(d) / "tasks"
            tdir.mkdir()
            marker = Path(d) / "marker.txt"
            marker.write_text("jev")
            (tdir / "fixture.echo.json").write_text(json.dumps({
                "id": "fixture.echo", "hero_job": "utility",
                "prompt": "succeed please", "requires": "local-safe",
                "success": {"kind": "file_state",
                            "expect": {"path": str(marker),
                                       "must": "contains",
                                       "text": "jev"}},
                "budget": {"p50_ms": 1000, "tier": "T3"},
                "tags": ["fixture"], "runs": 5}))
            out = Path(d) / "rows.jsonl"
            rc = run_mod.main(["--tasks-dir", str(tdir), "--set",
                               "local-safe", "--stub", "--dry-run",
                               "--runs", "2", "--out", str(out)])
            self.assertEqual(rc, 0)
            rows = [json.loads(l) for l in out.read_text().splitlines()
                    if l.strip()]
            self.assertEqual(len(rows), 2)
            for r in rows:
                for k in ("v", "ts", "task", "run", "wall_ms", "status",
                          "is_error", "verdict", "verified", "false_done",
                          "result_text", "evidence", "spans"):
                    self.assertIn(k, r)
            self.assertEqual(rows[0]["status"], "dry_run")
            self.assertTrue(rows[0]["verified"])

    def test_stub_live_run(self):
        import run as run_mod
        with tempfile.TemporaryDirectory() as d:
            tdir = Path(d) / "tasks"
            tdir.mkdir()
            (tdir / "fixture.echo.json").write_text(json.dumps({
                "id": "fixture.echo", "hero_job": "utility",
                "prompt": "succeed please", "requires": "local-safe",
                "success": {"kind": "speaks_substring",
                            "expect": {"text": "Done"}},
                "budget": {"p50_ms": 1000, "tier": "T3"},
                "tags": ["fixture"], "runs": 5}))
            out = Path(d) / "rows.jsonl"
            rc = run_mod.main(["--tasks-dir", str(tdir), "--set",
                               "local-safe", "--stub", "--runs", "2",
                               "--out", str(out)])
            self.assertEqual(rc, 0)
            rows = [json.loads(l) for l in out.read_text().splitlines()
                    if l.strip()]
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[0]["status"], "done")
            self.assertTrue(rows[0]["verified"])
            self.assertFalse(rows[0]["false_done"])


class ReportCase(unittest.TestCase):
    """(g) report.py on a fixture jsonl -> baseline.json fields."""

    def test_no_rows_do_not_publish_a_report(self):
        import report
        with tempfile.TemporaryDirectory() as directory:
            rows = Path(directory) / "rows.jsonl"
            rows.write_text("\n{incomplete")
            out = Path(directory) / "out"
            self.assertEqual(report.main([str(rows), "--outdir", str(out)]), 2)
            self.assertFalse(out.exists())

    def test_report(self):
        import report as report_mod
        with tempfile.TemporaryDirectory() as d:
            tdir = Path(d) / "tasks"
            tdir.mkdir()
            (tdir / "fixture.echo.json").write_text(json.dumps({
                "id": "fixture.echo", "hero_job": "utility",
                "prompt": "x", "requires": "local-safe",
                "success": {"kind": "file_state",
                            "expect": {"path": "/tmp/x", "must": "exists"}},
                "budget": {"p50_ms": 100, "tier": "T3"},
                "tags": [], "runs": 5}))
            rp = Path(d) / "rows.jsonl"
            rows = []
            for i, ok in enumerate([True, True, True, True, False]):
                rows.append(make_row(
                    "fixture.echo", i + 1, 50.0 + i,
                    "Done." if ok else "Blocked: x", False,
                    "pass" if ok else "fail", "ev"))
            rp.write_text("".join(json.dumps(r) + "\n" for r in rows))
            rc = report_mod.main([str(rp), "--outdir", d,
                                  "--tasks-dir", str(tdir)])
            self.assertEqual(rc, 0)
            base = json.loads((Path(d) / "baseline.json").read_text())
            self.assertIn("generated_at", base)
            self.assertIn("tasks", base)
            st = base["tasks"]["fixture.echo"]
            self.assertEqual(st["runs"], 5)
            self.assertEqual(st["successes"], 4)
            self.assertAlmostEqual(st["wilson_low"], wilson_low(4, 5),
                                   places=4)
            self.assertEqual(st["p50_ms"], 52.0)
            self.assertEqual(st["budget_p50_ms"], 100)
            self.assertTrue(st["meets_budget"])
            self.assertIn("T3", base["tiers"])
            self.assertTrue((Path(d) / "baseline-report.md").is_file())

    def test_only_verified_completed_runs_count_as_success(self):
        import report as report_mod
        rows = []
        for index, (status, error, verified) in enumerate([
            ("dry_run", False, True), ("error", True, True),
            ("blocked", False, True), ("needs_input", False, True),
            ("done", True, True), ("done", False, "false"),
            ("done", False, True), ("already", False, True),
        ]):
            row = make_row("calc.open", index + 1, 10, "", error,
                           "pass" if verified else "fail", "fixture", status=status)
            row["verified"] = verified
            rows.append(row)
        self.assertEqual(report_mod.task_stats(rows, {})["successes"], 2)
        self.assertEqual(report_mod.rollup(rows, "T0")["successes"], 2)
        with tempfile.TemporaryDirectory() as directory:
            data = Path(directory) / "rows.jsonl"
            data.write_text("".join(json.dumps(r) + "\n" for r in rows))
            self.assertEqual(report_mod.main([str(data), "--outdir", directory]), 0)
            baseline = json.loads((Path(directory) / "baseline.json").read_text())
            self.assertEqual(baseline["totals"]["successes"], 2)


class SafetyCase(unittest.TestCase):
    """Never run real OS resets or signing while testing their failure policy."""

    def test_disabled_textedit_reset_never_invokes_osascript(self):
        with tempfile.TemporaryDirectory() as directory:
            stub = Path(directory) / "osascript"
            marker = Path(directory) / "called"
            stub.write_text('#!/bin/sh\nprintf called > "$CAPTURE_MARKER"\n')
            stub.chmod(0o700)
            env = dict(os.environ, PATH=directory + os.pathsep + os.environ["PATH"],
                       CAPTURE_MARKER=str(marker))
            run = subprocess.run(["bash", str(BENCH / "reset/textedit.sh")],
                                 env=env, capture_output=True, text=True, timeout=10)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse(marker.exists(), "even a harmless command stub must not be reached")

    def test_signature_verification_failure_fails_packaging(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            commands = base / "commands"
            commands.mkdir()
            app = base / "Jarvis.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            (resources / "cua-driver").write_text("fixture, not executable code")
            with (app / "Contents/Info.plist").open("wb") as file:
                plistlib.dump({"CFBundleIdentifier": "fixture.signing"}, file)
            scripts = {
                "security": '#!/bin/sh\necho \'1) 123456 "Jarvis Local Dev"\'\n',
                "xattr": "#!/bin/sh\nexit 0\n",
                "codesign": '#!/bin/sh\ncase " $* " in *" --verify "*) exit 17;; esac\nexit 0\n',
            }
            for name, body in scripts.items():
                path = commands / name
                path.write_text(body)
                path.chmod(0o700)
            env = dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"])
            signer = base / "scripts/sign-app.sh"
            signer.parent.mkdir()
            signer.write_bytes((REPO_ROOT / "scripts/sign-app.sh").read_bytes())
            run = subprocess.run(["bash", str(signer), str(app)],
                                 env=env, capture_output=True, text=True, timeout=20)
            self.assertNotEqual(run.returncode, 0, "failed strict signature cannot produce a successful package")
            self.assertIn("codesign --verify --deep --strict failed", run.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
