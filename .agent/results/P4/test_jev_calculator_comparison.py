import importlib.util
import hashlib
import json
from contextlib import ExitStack
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("calculator_comparison", HERE / "jev-everyday-apps.py")
EVERYDAY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVERYDAY)
QUALIFICATION_SPEC = importlib.util.spec_from_file_location("calculator_qualification", HERE / "jev-vision-qualification.py")
QUALIFICATION = importlib.util.module_from_spec(QUALIFICATION_SPEC)
QUALIFICATION_SPEC.loader.exec_module(QUALIFICATION)
PROBE_SPEC = importlib.util.spec_from_file_location("native_latency_probe", HERE / "jev-native-latency-probe.py")
PROBE = importlib.util.module_from_spec(PROBE_SPEC)
PROBE_SPEC.loader.exec_module(PROBE)
READONLY_SPEC = importlib.util.spec_from_file_location("calculator_readonly", HERE / "jev-calculator-readonly.py")
READONLY = importlib.util.module_from_spec(READONLY_SPEC)
READONLY_SPEC.loader.exec_module(READONLY)


class ScopedSession:
    def __init__(self, bad=None):
        self.metadata = {}
        self.presses = []
        self.bad = bad
        self.reads = 0
        self.read_arguments = []

    def call(self, name, arguments):
        assert name == "get_window_state"
        self.read_arguments.append(arguments)
        self.reads += 1
        snapshot = f"s{self.reads:08x}"
        buttons = [dict(role="AXButton", label=label, enabled=True, actions=["AXPress"], element_index=index,
                        frame=dict(x=index * 20, y=0, w=10, h=10),
                        element_token=f"{snapshot}:{index}")
                   for index, label in enumerate(["All Clear", "2", "Add", "3", "Equals"])]
        state = dict(pid=77, window_id=12, window_title="Calculator", snapshot_id=snapshot, truncated=False,
                     elements_complete=False, elements=buttons,
                     tree_markdown='- [28] AXStaticText = "\\u200e2\\u200e+\\u200e3"\n- [29] AXStaticText = "\\u200e5"')
        if self.bad == "scope":
            state["pid"] = 78
        elif self.bad == "token":
            buttons[0]["element_token"] = "sffffffff:0"
        elif self.bad == "duplicate":
            state["elements"].append(dict(buttons[0]))
        elif self.bad == "modal":
            state["elements"].append(dict(role="AXSheet"))
        elif self.bad and self.bad.startswith("native_"):
            state["elements_complete"] = True
        return state

    def native_window_state(self, target, title):
        def fingerprint(value):
            return dict(sha256=hashlib.sha256(value.encode()).hexdigest(), utf8_count=len(value.encode()))
        controls = [dict(role="AXButton", title=fingerprint(label), description=None,
                         frame=dict(x=index * 20, y=0, width=10, height=10))
                    for index, label in enumerate(["All Clear", "2", "Add", "3", "Equals"])]
        native = dict(pid=77, window_id=12, window_title=fingerprint(title), target_found=True,
                      ax_trusted=True, budget_exhausted=False, modal_sheets=0,
                      role_read_failures=0, children_read_failures=0, controls=controls)
        if self.bad == "native_incomplete":
            native["children_read_failures"] = 1
        elif self.bad == "native_scope":
            native["pid"] = 78
        elif self.bad == "native_duplicate":
            controls.append(dict(controls[0]))
        return native

    def complete_native_window_state(self, target, title, control=None):
        return QUALIFICATION.real.Session.complete_native_window_state(self, target, title, control)

    def raw_call(self, name, arguments):
        assert name == "click"
        assert arguments["pid"] == 77 and arguments["window_id"] == 12
        assert arguments["delivery_mode"] == "background"
        keys = {"pid", "window_id", "element_token", "delivery_mode"}
        if "post_action_wait" in arguments:
            assert arguments["post_action_wait"] == "none"
            keys.add("post_action_wait")
        assert set(arguments) == keys
        assert arguments["element_token"].startswith(f"s{self.reads:08x}:")
        self.presses.append(arguments)
        return dict(isError=False, structuredContent=dict(success=True))


class CalculatorComparisonTests(unittest.TestCase):
    def test_matched_seed_budget_is_separate_from_goal_observations(self):
        workspace = HERE.parents[3] / "jarvis-v1-vision-driver/development/JevVoice"
        with tempfile.TemporaryDirectory(prefix="p4-seed-budget-", dir=workspace) as directory:
            session = ScopedSession()
            session.directory = Path(directory)
            session.metadata["matched_calculator"] = True
            session.drive = Mock(return_value={"strict_success": True})
            with patch.object(EVERYDAY, "visible_window", return_value=dict(pid=77, window_id=12)), \
                 patch.object(EVERYDAY, "screenshot", return_value="not-used-in-unit-check.png"):
                EVERYDAY.calculator(session, QUALIFICATION.real.wait_for)
            record = session.metadata["calculator_seed"]
            self.assertEqual(record["observation_timeout_ms"], 5000)
            self.assertGreaterEqual(record["setup_wall_ms"], 0)
            self.assertTrue(record["verified"])
            setup_reads = len(record["observations"])
            self.assertTrue(all(row.get("timeout_ms") == 5000 for row in session.read_arguments[:setup_reads]))
            self.assertTrue(all("timeout_ms" not in row for row in session.read_arguments[setup_reads:]))
            session.drive.assert_called_once()
            case = session.drive.call_args.args[0]
            self.assertEqual(case["goal"], "Calculate 3 plus 4 and show the result.")
            self.assertEqual(case["values"], {})

    def test_readonly_budget_is_explicit_and_does_not_change_default(self):
        target = dict(pid=77, window_id=12)
        for budget in (None, 5000):
            with self.subTest(budget=budget):
                session = SimpleNamespace(call=Mock(return_value=target))
                self.assertEqual(READONLY.observe(session, target, budget), target)
                arguments = dict(target, include_screenshot=False, tree_format="both", max_elements=2000)
                if budget is not None:
                    arguments["timeout_ms"] = budget
                session.call.assert_called_once_with("get_window_state", arguments)

    def test_readonly_larger_budget_never_accepts_changed_subject(self):
        session = SimpleNamespace(metadata={}, call=Mock(return_value=dict(pid=78, window_id=12)))
        with self.assertRaisesRegex(RuntimeError, "^readonly_snapshot_scope_changed$"):
            READONLY.observe(session, dict(pid=77, window_id=12), 5000)
        self.assertEqual(session.metadata["diagnostic_scope_mismatch"], dict(pid=78, window_id=12))

    def test_seed_waits_for_complete_read_without_replaying_input(self):
        session = ScopedSession()
        original = session.call
        def partial_once(name, arguments):
            state = original(name, arguments)
            state["truncated"] = session.reads == 1
            return state
        with patch.object(session, "call", side_effect=partial_once):
            EVERYDAY.calculator_seed(session, dict(pid=77, window_id=12),
                                     wait=QUALIFICATION.real.wait_for)
        record = session.metadata["calculator_seed"]
        self.assertEqual(len(session.presses), 5)
        self.assertTrue(record["observations"][0]["truncated"])
        self.assertFalse(record["observations"][1]["truncated"])
        self.assertTrue(session.presses[0]["element_token"].startswith("s00000002:"))
        self.assertTrue(all("timeout_ms" not in arguments for arguments in session.read_arguments))
        self.assertTrue(record["verified"])

    def test_seed_readiness_timeout_never_sends_input(self):
        session = ScopedSession()
        original = session.call
        def incomplete(name, arguments):
            state = original(name, arguments)
            state["truncated"] = True
            return state
        def bounded_wait(read, seconds, message):
            self.assertEqual(seconds, 10)
            self.assertIsNone(read())
            raise TimeoutError("fixture observation incomplete")
        with patch.object(session, "call", side_effect=incomplete):
            with self.assertRaisesRegex(TimeoutError, "^fixture observation incomplete$"):
                EVERYDAY.calculator_seed(session, dict(pid=77, window_id=12), wait=bounded_wait)
        self.assertEqual(session.presses, [])
        self.assertFalse(session.metadata["calculator_seed"]["verified"])

    def test_cold_warm_pilot_keeps_one_actor_and_stops_on_failed_cold_goal(self):
        for succeeds in (True, False):
            with self.subTest(cold_succeeds=succeeds):
                actor = SimpleNamespace(close=Mock(), proc=SimpleNamespace(pid=77))
                session = SimpleNamespace(metadata={}, start_actor=Mock(return_value=actor))
                rows = [dict(strict_success=succeeds), dict(strict_success=True)]
                with patch.object(EVERYDAY, "calculator", side_effect=rows) as calculate:
                    EVERYDAY.calculator_pilot(session, None)
                self.assertEqual(calculate.call_count, 2 if succeeds else 1)
                self.assertEqual([call.kwargs["timing_kind"] for call in calculate.call_args_list],
                                 ["cold", "warm"] if succeeds else ["cold"])
                self.assertTrue(all(call.kwargs["actor"] is actor for call in calculate.call_args_list))
                session.start_actor.assert_called_once_with()
                actor.close.assert_not_called()
                self.assertTrue(session.metadata["matched_calculator"])

    def test_retained_product_actor_counts_both_goals_without_closing_between_them(self):
        real = QUALIFICATION.real
        with tempfile.TemporaryDirectory(prefix=".calculator-comparison-test-", dir=HERE) as directory:
            actor = SimpleNamespace(proc=SimpleNamespace(pid=77, poll=lambda: None), close=Mock())
            session = object.__new__(real.Session)
            session.driver_only = False
            session.clients = [actor]
            session.metadata = dict(rows=[], drive_requests=0)
            session.directory = Path(directory)
            session.variant = None
            reply = dict(content=[dict(type="text", text="Done. fixture")], isError=False)
            native = SimpleNamespace(drive=Mock(return_value=(reply, False)))
            spec = SimpleNamespace(loader=SimpleNamespace(exec_module=Mock()))
            with ExitStack() as stack:
                stack.enter_context(patch.object(real.importlib.util, "spec_from_file_location", return_value=spec))
                stack.enter_context(patch.object(real.importlib.util, "module_from_spec", return_value=native))
                create = stack.enter_context(patch.object(real, "start_client"))
                key = stack.enter_context(patch.object(real, "require_api_key"))
                for name in ("calculator.cold", "calculator.warm"):
                    session.drive(dict(id=name, goal="synthetic calculation"), lambda: (dict(display="7"), True),
                                  actor=actor)
            actor.close.assert_not_called()
            create.assert_not_called()
            key.assert_not_called()
            self.assertEqual(session.metadata["drive_requests"], 2)
            self.assertEqual([row["actor_pid"] for row in session.metadata["rows"]], [77, 77])
            self.assertTrue(all(row["strict_success"] for row in session.metadata["rows"]))

    def test_cursor_restore_still_runs_when_motion_restore_fails(self):
        session = SimpleNamespace(metadata={})
        original = dict(enabled=True, motion=dict(glide_duration_ms=0))
        with patch.object(PROBE, "cursor", return_value=original) as cursor_call:
            with patch.object(PROBE, "motion", side_effect=RuntimeError("restore_failed")):
                with self.assertRaisesRegex(RuntimeError, "^restore_failed$"):
                    PROBE.measure(session, {}, HERE, None, None, isolate_glide_duration=True)
        self.assertEqual([call.args[1] for call in cursor_call.call_args_list if len(call.args) == 2],
                         [True, True])

    def test_sampler_reap_timeout_does_not_skip_second_child_or_receipt(self):
        owner = SimpleNamespace(pid=11, poll=lambda: None)
        session = SimpleNamespace(daemon=owner, local=SimpleNamespace(proc=owner), metadata={})
        samplers = [Mock(), Mock()]
        for sampler in samplers:
            sampler.wait.side_effect = PROBE.subprocess.TimeoutExpired("sample", 5)
        real = SimpleNamespace(write_json=Mock())
        with tempfile.TemporaryDirectory(prefix=".calculator-comparison-test-", dir=HERE) as directory:
            with patch.object(PROBE.subprocess, "Popen", side_effect=samplers):
                with self.assertRaisesRegex(RuntimeError, "^diagnostic_driver_sample_unavailable$"):
                    PROBE.sample_driver(session, {}, Path(directory), SimpleNamespace(calculator_seed=Mock()), real)
        for sampler in samplers:
            sampler.kill.assert_called_once()
        real.write_json.assert_called_once()
        self.assertEqual([item["error"] for item in session.metadata["driver_sample"]["processes"]],
                         ["sample_reap_timeout", "sample_reap_timeout"])

    def test_diagnostic_read_budget_does_not_change_default_observation(self):
        ordinary, diagnostic = ScopedSession(), ScopedSession()
        EVERYDAY.calculator_seed(ordinary, dict(pid=77, window_id=12))
        EVERYDAY.calculator_seed(diagnostic, dict(pid=77, window_id=12), observation_timeout_ms=5000)
        self.assertTrue(all("timeout_ms" not in args for args in ordinary.read_arguments))
        self.assertTrue(all(args.get("timeout_ms") == 5000 for args in diagnostic.read_arguments))

    def test_diagnostic_post_action_wait_is_opt_in(self):
        ordinary, diagnostic = ScopedSession(), ScopedSession()
        EVERYDAY.calculator_seed(ordinary, dict(pid=77, window_id=12))
        EVERYDAY.calculator_seed(diagnostic, dict(pid=77, window_id=12), post_action_wait="none")
        self.assertTrue(all("post_action_wait" not in args for args in ordinary.presses))
        self.assertTrue(all(args["post_action_wait"] == "none" for args in diagnostic.presses))

    def test_adopted_running_surface_never_requests_application_launch(self):
        session = SimpleNamespace(call=Mock(return_value=dict(apps=[dict(pid=77, bundle_id="com.apple.calculator")])),
                                  windows=Mock(return_value=[dict(pid=77, window_id=12, layer=0, is_on_screen=True)]))
        wait = lambda read, *_: read()
        self.assertEqual(EVERYDAY.visible_window(session, "com.apple.calculator", wait, allow_launch=False),
                         dict(pid=77, window_id=12))
        session.call.assert_called_once_with("list_apps", {})

    def test_native_probe_refusal_keeps_request_and_exact_diagnostic(self):
        with tempfile.TemporaryDirectory(prefix=".calculator-comparison-test-", dir=HERE) as directory:
            session = SimpleNamespace(directory=Path(directory), metadata={})
            reply = SimpleNamespace(returncode=3, stdout="", stderr="native_probe_title_mismatch\n")
            with patch.object(QUALIFICATION.real.subprocess, "run", return_value=reply):
                with self.assertRaisesRegex(RuntimeError, "^owned_document_native_probe_unavailable$"):
                    QUALIFICATION.real.Session.native_window_state(session, dict(pid=77, window_id=12), "Calculator")
            receipt = json.loads((session.directory / "native-oracle-1.json").read_text())
            self.assertEqual(receipt["window"], dict(pid=77, window_id=12))
            self.assertEqual(receipt["return_code"], 3)
            self.assertEqual(receipt["stderr"], "native_probe_title_mismatch\n")
            self.assertEqual(receipt["title_sha256"], hashlib.sha256(b"Calculator").hexdigest())

    def test_setup_error_is_persisted_before_session_teardown(self):
        with tempfile.TemporaryDirectory(prefix=".calculator-comparison-test-", dir=HERE) as directory:
            session = ScopedSession("scope")
            session.directory = Path(directory)
            session.metadata["matched_calculator"] = True
            with patch.object(EVERYDAY, "visible_window", return_value=dict(pid=77, window_id=12)):
                with self.assertRaisesRegex(RuntimeError, "^calculator_seed_scope_or_state$"):
                    EVERYDAY.calculator(session, None)
            receipt = json.loads((session.directory / "calculator-seed.json").read_text())
            self.assertEqual(receipt["error"], dict(type="RuntimeError", message="calculator_seed_scope_or_state"))
            self.assertEqual(receipt["presses"], [])
            self.assertFalse(receipt["verified"])

    def test_matched_source_pairs_use_after_driver_for_both_builds(self):
        args = SimpleNamespace(command="realapps-everyday", repeats=3, pilot=False,
                               baseline_receipt="baseline", matched_calculator=True)
        self.assertEqual(QUALIFICATION.run_pairs(args), [
            ("before", 0), ("after", 0), ("after", 1), ("before", 1), ("before", 2), ("after", 2)])
        self.assertEqual([QUALIFICATION.profile_subject_variant(args, v) for v in ("before", "after")],
                         ["after", "after"])
        args.matched_calculator = False
        args.baseline_receipt = None
        self.assertEqual(QUALIFICATION.run_pairs(args), [("after", 0), ("after", 1), ("after", 2)])
        self.assertEqual(QUALIFICATION.profile_subject_variant(args, "after"), "after")
        args.command = "realapps-textedit"
        args.baseline_receipt = "baseline"
        self.assertEqual(QUALIFICATION.profile_subject_variant(args, "after"), "before")

    def test_unknown_sdk_completeness_uses_full_native_scope_and_records_every_press(self):
        session = ScopedSession()
        EVERYDAY.calculator_seed(session, dict(pid=77, window_id=12))
        self.assertEqual(len(session.presses), 5)
        self.assertEqual(len(session.metadata["calculator_seed"]["presses"]), 5)
        self.assertTrue(session.metadata["calculator_seed"]["verified"])
        self.assertTrue(all(entry["driver_wall_ms"] >= 0
                            for entry in session.metadata["calculator_seed"]["presses"]))

    def test_bad_scope_token_duplicate_and_modal_refuse_before_input(self):
        for bad in ("scope", "token", "duplicate", "modal", "native_incomplete", "native_scope", "native_duplicate"):
            with self.subTest(bad=bad):
                session = ScopedSession(bad)
                with self.assertRaisesRegex(RuntimeError, "calculator_seed_"):
                    EVERYDAY.calculator_seed(session, dict(pid=77, window_id=12))
                self.assertEqual(session.presses, [])


if __name__ == "__main__":
    unittest.main()
