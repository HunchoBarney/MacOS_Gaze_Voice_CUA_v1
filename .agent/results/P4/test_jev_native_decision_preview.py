import importlib.util
from pathlib import Path
import unittest
from unittest.mock import Mock, patch


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_decision_preview", HERE / "jev-native-decision-preview.py")
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


class Actor:
    proc = type("Process", (), {"pid": 41})()

    def __init__(self, tool=True, fail=False):
        self.calls = []
        self.tool = tool
        self.fail = fail

    def call(self, method, params=None, timeout=None):
        self.calls.append((method, params, timeout))
        if method == "tools/list":
            return {"tools": [{"name": "suggest_action",
                              "inputSchema": {"properties": dict(goal={}, app={}, window_id={})}}]
                    if self.tool else []}
        if method != "tools/call" or params["name"] != "suggest_action":
            raise AssertionError("mutating or unexpected RPC")
        if self.fail:
            raise RuntimeError("preview_transport_failed")
        return {"content": [{"type": "text", "text": "Would press the owned control."}]}


class Session:
    def __init__(self, before=False, after=False, **actor):
        self.metadata = {"drive_requests": 0}
        self.actor = Actor(**actor)
        self.before = before
        self.after = after
        self.checks = 0
        self.starts = 0

    def call(self, name, arguments):
        if name == "list_apps":
            self.checks += 1
            pid = 78 if self.before else 77
            return {"apps": [dict(bundle_id="com.apple.calculator", pid=pid)]}
        if name == "get_window_state":
            assert arguments["pid"] == 77 and arguments["window_id"] == 12
            assert arguments["include_screenshot"] is False
            assert "timeout_ms" not in arguments
            return dict(pid=77, window_id=12, truncated=False, elements=[],
                        tree_markdown='- [1] AXStaticText = "5"')
        raise AssertionError("unexpected driver call")

    def windows(self, pid):
        assert pid == 77
        return [] if self.after and self.checks > 1 else [dict(window_id=12)]

    def start_actor(self):
        self.starts += 1
        return self.actor


class PreviewTests(unittest.TestCase):
    def setUp(self):
        self.window = dict(pid=77, window_id=12)
        self.stamp = patch.object(PROBE.REAL, "process_stamp",
            return_value="owned-stamp /System/Applications/Calculator.app/Contents/MacOS/Calculator")
        self.stamp.start()
        self.addCleanup(self.stamp.stop)

    def test_only_one_public_readonly_suggestion_and_default_budget_readback(self):
        session = Session()
        PROBE.suggest(session, self.window, "Calculate 3 plus 4 and show the result.", ["Delete"])
        self.assertEqual(session.metadata["preview_requests"], 1)
        self.assertEqual(session.metadata["drive_requests"], 0)
        self.assertEqual(session.metadata["input_actuations"], 0)
        self.assertEqual(session.starts, 1)
        self.assertEqual(len(session.actor.calls), 2)
        _, params, timeout = session.actor.calls[1]
        self.assertEqual(params, dict(name="suggest_action", arguments={
            "goal": "Calculate 3 plus 4 and show the result.",
            "app": "com.apple.calculator", "window_id": 12, "deny": ["Delete"],
        }))
        self.assertEqual(timeout, 30)
        self.assertEqual(session.metadata["preview_readback"]["pid"], 77)

    def test_scope_failure_before_model_never_starts_actor(self):
        session = Session(before=True)
        with self.assertRaisesRegex(RuntimeError, "^readonly_preview_scope_changed$"):
            PROBE.suggest(session, self.window, "controlled goal", [])
        self.assertEqual(session.starts, 0)
        self.assertEqual(session.metadata["preview_requests"], 0)
        self.assertEqual(session.metadata["scope_failure"]["expected"], self.window)

    def test_scope_failure_after_preview_retains_result_and_never_retries(self):
        session = Session(after=True)
        with self.assertRaisesRegex(RuntimeError, "^readonly_preview_scope_changed$"):
            PROBE.suggest(session, self.window, "controlled goal", [])
        self.assertEqual(session.metadata["preview_requests"], 1)
        self.assertIn("preview_result", session.metadata)
        self.assertEqual(len(session.actor.calls), 2)

    def test_missing_public_tool_does_not_fall_back_to_drive(self):
        session = Session(tool=False)
        with self.assertRaisesRegex(RuntimeError, "^readonly_preview_tool_unavailable$"):
            PROBE.suggest(session, self.window, "controlled goal", [])
        self.assertEqual(session.metadata["preview_requests"], 0)
        self.assertEqual(len(session.actor.calls), 1)

    def test_transport_failure_is_retained_without_replay(self):
        session = Session(fail=True)
        with self.assertRaisesRegex(RuntimeError, "^preview_transport_failed$"):
            PROBE.suggest(session, self.window, "controlled goal", [])
        self.assertEqual(session.metadata["preview_requests"], 1)
        self.assertEqual(session.metadata["preview_error_type"], "RuntimeError")
        self.assertEqual(len(session.actor.calls), 2)
        self.assertIn("preview_readback", session.metadata)

    def test_post_scope_failure_cannot_replace_original_preview_failure(self):
        session = Session(fail=True, after=True)
        with self.assertRaisesRegex(RuntimeError, "^preview_transport_failed$"):
            PROBE.suggest(session, self.window, "controlled goal", [])
        self.assertEqual(session.metadata["preview_error_type"], "RuntimeError")
        self.assertEqual(session.metadata["post_preview_error"]["code"], "readonly_preview_scope_changed")
        self.assertEqual(session.metadata["preview_requests"], 1)

    def test_log_collection_failure_is_recorded_without_hiding_preview_outcome(self):
        session = Session()
        session.metadata["preview_actor_pid"] = 41
        with patch.object(PROBE.subprocess, "run", side_effect=PermissionError):
            PROBE.collect_logs(session, Mock())
        self.assertEqual(session.metadata["trace_collection"]["error_type"], "PermissionError")
        self.assertFalse(session.metadata["trace_collection"]["complete"])

    def test_case_must_prove_original_scope_without_resetting_it(self):
        prior = dict(resources_clean=True, rows=[dict(case="calculator.add", requested_window_id=12)],
                     calculator_seed=dict(verified=True, observations=[self.window]))
        self.assertEqual(PROBE.case_window(prior), self.window)
        prior["calculator_seed"]["observations"].append(dict(pid=78, window_id=12))
        with self.assertRaisesRegex(RuntimeError, "^readonly_preview_case_unverified$"):
            PROBE.case_window(prior)


if __name__ == "__main__":
    unittest.main()
