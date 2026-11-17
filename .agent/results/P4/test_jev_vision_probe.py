import importlib.util
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, call, patch

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("realapps", HERE / "jev-realapps.py")
realapps = importlib.util.module_from_spec(spec)
spec.loader.exec_module(realapps)
spec = importlib.util.spec_from_file_location("qualification", HERE / "jev-vision-qualification.py")
qualification = importlib.util.module_from_spec(spec)
spec.loader.exec_module(qualification)


class RefinementInputInvariantTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("refinement_capture", HERE / "jev-everyday-choice-capture.py")
        self.capture = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.capture)
        self.primary = {
            "state": {"goal": "read", "value": "\u200f7"},
            "questions": {"goal_fact": {"type": "choice", "criteria": {
                "none": "No evidence",
                "value:1": '{"role":"AXStaticText","value":"\\u200f7","roles":["AXWindow","AXGroup"]}',
            }}, "step": {"type": "choice", "criteria": {"e1": "press"}}},
            "assets": {},
        }

    def test_key_order_is_reported_without_claiming_identical_model_inputs(self):
        other = json.loads(json.dumps(self.primary))
        other["questions"]["goal_fact"]["criteria"]["value:1"] = (
            '{"roles":["AXWindow","AXGroup"],"value":"\\u200f7","role":"AXStaticText"}')
        before = json.dumps(self.primary)
        result = self.capture.refinement_input_invariant(self.primary, other)
        self.assertFalse(result["identical_primary_model_input"])
        self.assertTrue(result["semantically_equal_primary_input"])
        self.assertTrue(result["goal_fact_encoding_nondeterminism"])
        self.assertFalse(result["wire_equivalence_claimed"])
        self.assertEqual(json.dumps(self.primary), before)

    def test_identical_requests_remain_identical(self):
        result = self.capture.refinement_input_invariant(self.primary, self.primary)
        self.assertTrue(result["identical_primary_model_input"])
        self.assertFalse(result["goal_fact_encoding_nondeterminism"])

    def test_nonordering_changes_and_direction_mark_changes_still_refuse(self):
        for path, value in [
            (("state", "goal"), "change"),
            (("state", "value"), "7"),
            (("questions", "step", "type"), "noul"),
            (("questions", "goal_fact", "criteria", "value:1"),
             '{"role":"AXStaticText","value":"7","roles":["AXWindow","AXGroup"]}'),
            (("questions", "goal_fact", "criteria", "value:1"),
             '{"role":"AXStaticText","value":"\\u200f7","roles":["AXGroup","AXWindow"]}'),
        ]:
            other = json.loads(json.dumps(self.primary))
            parent = other
            for key in path[:-1]:
                parent = parent[key]
            parent[path[-1]] = value
            with self.assertRaisesRegex(RuntimeError, "semantic model input"):
                self.capture.refinement_input_invariant(self.primary, other)

    def test_invalid_fact_representation_is_not_ignored(self):
        for text in ["bad", "null", "7", "[]", '"text"']:
            other = json.loads(json.dumps(self.primary))
            other["questions"]["goal_fact"]["criteria"]["value:1"] = text
            with self.assertRaisesRegex(RuntimeError, "goal fact"):
                self.capture.refinement_input_invariant(self.primary, other)


class DriverOnlyProbeTests(unittest.TestCase):
    def test_exact_reviewed_addition_is_historical_not_current(self):
        expected = {"stable": "same"}
        current = dict(expected, added="new")
        delta = {"added": {"before": None, "after": "new"}}
        self.assertFalse(realapps.verify_source_subject(expected, current, approved_delta=delta))
        for subject, changed in [
            (current, None),
            (dict(current, undeclared="foreign"), delta),
            (dict(current, added="wrong"), delta),
            (current, {"added": {"before": "old", "after": "new"}}),
            ({}, {"stable": {"before": "same", "after": None}}),
            (current, dict(delta, ghost={"before": None, "after": "new"})),
        ]:
            with self.assertRaises(RuntimeError):
                realapps.verify_source_subject(expected, subject, approved_delta=changed)
        with self.assertRaises(RuntimeError):
            realapps.verify_source_subject({"added": None}, {"added": "new"}, approved_delta=delta)

    def test_review_loader_allows_only_valid_hash_additions_and_existing_changes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            report = root / "review.md"
            report.write_text("PASS scoped source review")
            review = {
                "verdict": "PASS", "review_receipt": str(report),
                "review_receipt_sha256": realapps.digest(report),
                "source_changes": {"added.swift": {"before": None, "after": "a" * 64}},
            }
            receipt = root / "review.json"
            receipt.write_text(json.dumps(review))
            self.assertEqual(qualification.load_reviewed_source_delta(receipt), review["source_changes"])
            for change in [
                {"before": None, "after": None}, {"before": "bad", "after": "a" * 64},
                {"before": False, "after": "a" * 64}, {"before": None, "after": "bad"},
                {"before": "b" * 64, "after": None},
                {"before": None, "after": "a" * 64, "extra": True},
            ]:
                receipt.write_text(json.dumps(dict(review, source_changes={"added.swift": change})))
                with self.assertRaises((AssertionError, ValueError)):
                    qualification.load_reviewed_source_delta(receipt)
            for extra in [
                {"verdict": "FAIL"}, {"review_receipt_sha256": "0" * 64}, {"source_changes": {}},
            ]:
                receipt.write_text(json.dumps(dict(review, **extra)))
                with self.assertRaises((AssertionError, ValueError)):
                    qualification.load_reviewed_source_delta(receipt)

    def test_normal_product_probe_rejects_changed_source(self):
        with self.assertRaises(RuntimeError):
            realapps.verify_source_subject({"a": "old"}, {"a": "new"}, driver_only=False)

    def test_driver_only_records_source_mismatch_instead_of_claiming_product(self):
        self.assertFalse(realapps.verify_source_subject(
            {"a": "old"}, {"a": "new"}, driver_only=True))

    def test_driver_only_cannot_start_jev_actor(self):
        session = realapps.Session(HERE, HERE / "unused.json", driver_only=True)
        with self.assertRaisesRegex(RuntimeError, "driver-only"):
            session.drive({}, lambda: self.fail("oracle must not run"))
        self.assertEqual(session.metadata["drive_requests"], 0)

    def test_historical_source_delta_is_exact_and_does_not_claim_current_source(self):
        delta = {"chooser": {"before": "old", "after": "new"}}
        self.assertFalse(realapps.verify_source_subject(
            {"chooser": "old", "stable": "same"}, {"chooser": "new", "stable": "same"},
            approved_delta=delta))
        for current, change in [
            ({"chooser": "new", "stable": "changed"}, delta),
            ({"chooser": "unexpected", "stable": "same"}, delta),
            ({"chooser": "new", "stable": "same"}, {"chooser": {"before": "wrong", "after": "new"}}),
            ({"chooser": "new"}, delta),
        ]:
            with self.assertRaises(RuntimeError):
                realapps.verify_source_subject({"chooser": "old", "stable": "same"}, current,
                                              approved_delta=change)


class EverydayQualificationTests(unittest.TestCase):
    def helpers(self):
        spec = importlib.util.spec_from_file_location("everyday", HERE / "jev-everyday-apps.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_new_window_requires_one_new_owned_window_and_preserves_old_windows(self):
        select = self.helpers().select_new_window
        old = [{"pid": 7, "window_id": 1, "layer": 0}]
        fresh = {"pid": 7, "window_id": 2, "layer": 0}
        self.assertEqual(select(old, old + [fresh], 7), fresh)
        for rows in [old, [fresh], old + [dict(fresh, pid=8)],
                     old + [fresh, {"pid": 7, "window_id": 3}]]:
            with self.assertRaises(RuntimeError):
                select(old, rows, 7)
        with self.assertRaises(RuntimeError):
            select(old, old + [dict(fresh, layer=101)], 7)

    def test_browser_waits_for_native_startup_window_before_scoped_menu(self):
        helpers = self.helpers()
        window = {"pid": 7, "window_id": 1, "layer": 0}
        session = SimpleNamespace(metadata={}, call=Mock(return_value={"pid": 7}),
                                  windows=Mock(side_effect=[[], [window]]),
                                  invoke_window_menu=Mock(side_effect=RuntimeError("scoped_menu_reached")))
        def wait(probe, *_):
            first = probe()
            return first or probe()
        with self.assertRaisesRegex(RuntimeError, "scoped_menu_reached"):
            helpers.browser(session, "com.apple.Safari", wait)
        session.invoke_window_menu.assert_called_once_with({"pid": 7, "window_id": 1}, ["File", "New Window"])

    def test_browser_menu_host_is_visible_not_a_hidden_normal_layer_helper(self):
        helpers = self.helpers()
        rows = [{"pid": 7, "window_id": 2, "layer": 0, "is_on_screen": False},
                {"pid": 7, "window_id": 1, "layer": 0, "is_on_screen": True}]
        session = SimpleNamespace(metadata={}, call=Mock(return_value={"pid": 7}), windows=Mock(return_value=rows),
                                  invoke_window_menu=Mock(side_effect=RuntimeError("scoped_menu_reached")))
        with self.assertRaisesRegex(RuntimeError, "scoped_menu_reached"):
            helpers.browser(session, "com.apple.Safari", lambda probe, *_: probe())
        session.invoke_window_menu.assert_called_once_with({"pid": 7, "window_id": 1}, ["File", "New Window"])

    def test_browser_waits_for_exact_owned_window_set_after_menu_transition(self):
        helpers = self.helpers()
        old = {"pid": 7, "window_id": 1, "layer": 0, "is_on_screen": True}
        fresh = dict(old, window_id=2)
        for transitional in ([fresh], [old, fresh, dict(old, window_id=3)]):
            with self.subTest(transitional=transitional):
                session = SimpleNamespace(metadata={}, call=Mock(return_value={"pid": 7}),
                                          windows=Mock(side_effect=[[old], transitional, [old, fresh]]),
                                          invoke_window_menu=Mock())
                def wait(probe, *_):
                    first = probe()
                    return first or probe()
                with patch.object(helpers, "state_for", side_effect=RuntimeError("owned_fixture_reached_oracle")):
                    with self.assertRaisesRegex(RuntimeError, "owned_fixture_reached_oracle"):
                        helpers.browser(session, "com.google.Chrome", wait)
                self.assertEqual(session.metadata["browser_fixture"]["window"]["window_id"], 2)

    def test_visible_app_window_excludes_transient_menu_layers(self):
        helpers = self.helpers()
        normal = {"pid": 7, "window_id": 1, "layer": 0, "is_on_screen": True}
        menu = dict(normal, window_id=2, layer=101)
        session = SimpleNamespace(call=Mock(return_value={"pid": 7}), windows=Mock(return_value=[normal, menu]))
        self.assertEqual(helpers.visible_window(session, "app", lambda probe, *_: probe()),
                         {"pid": 7, "window_id": 1})

    def test_foreign_capture_is_rejected_before_any_image_file_is_written(self):
        helpers = self.helpers()
        with tempfile.TemporaryDirectory() as directory:
            session = SimpleNamespace(directory=Path(directory), raw_call=Mock(return_value={
                "structuredContent": {"pid": 8, "window_id": 2},
                "content": [{"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}],
            }))
            with self.assertRaisesRegex(RuntimeError, "native_capture_subject_changed"):
                helpers.screenshot(session, {"pid": 7, "window_id": 2}, "foreign.png")
            self.assertFalse((Path(directory) / "foreign.png").exists())

    def test_inspection_mode_never_launches_fronts_or_drives_an_app(self):
        helpers = self.helpers()
        session = SimpleNamespace(metadata={}, call=Mock(return_value={"apps": []}),
                                  drive=Mock(), raw_call=Mock())
        helpers.run(session, "inspect", None, None)
        session.call.assert_called_once_with("list_apps", {})
        session.drive.assert_not_called()
        session.raw_call.assert_not_called()
        self.assertEqual(session.metadata["observations"], [])

    def test_inspection_records_invalid_capture_without_input_or_private_error_text(self):
        helpers = self.helpers()
        target = {"pid": 7, "window_id": 2}
        def native_call(name, arguments):
            if name == "list_apps":
                return {"apps": [{"pid": 7, "bundle_id": "com.spotify.client"}]}
            if name == "get_window_state":
                return dict(target, elements=[])
            raise AssertionError("inspection attempted an unexpected tool")
        with tempfile.TemporaryDirectory() as directory:
            session = SimpleNamespace(directory=Path(directory), metadata={},
                                      call=Mock(side_effect=native_call),
                                      windows=Mock(return_value=[dict(target, layer=0)]),
                                      drive=Mock(), raw_call=Mock(return_value={
                                          "structuredContent": target,
                                          "content": [{"type": "image", "mimeType": "image/png",
                                                       "data": "invalid-private-image!"}],
                                      }))
            helpers.observe(session)
            entry = session.metadata["observations"][0]
            self.assertEqual(entry["observation_error"], "Error")
            self.assertEqual(entry["captures"], [])
            self.assertEqual(list(Path(directory).iterdir()), [])
            session.drive.assert_not_called()
            self.assertNotIn("invalid-private-image", str(session.metadata))

    def test_browser_outcome_requires_loaded_title_exact_url_and_exact_window(self):
        verify = self.helpers().browser_outcome
        window = {"pid": 7, "window_id": 2}
        state = dict(window, elements=[
            {"role": "AXComboBox", "label": "Address and search bar", "value": "https://www.wikipedia.org/"}])
        rows = [dict(window, title="Wikipedia")]
        self.assertTrue(verify(state, rows, window))
        self.assertFalse(verify(state, [dict(window, title="New Tab")], window))
        for changed in [dict(state, pid=8), dict(state, window_id=3), dict(state, elements=[]),
                        dict(state, elements=[dict(state["elements"][0], value="https://www.wikipedia.org.evil.invalid/")])]:
            self.assertFalse(verify(changed, rows, window))

    def test_extra_case_denials_cannot_remove_default_safety_policy(self):
        defaults = realapps.qualification_denials({})
        extra = realapps.qualification_denials({"deny": ["Play", "Pause", "Space"]})
        self.assertTrue(set(defaults).issubset(extra))
        self.assertTrue({"Delete", "Share", "Send", "Play", "Pause", "Space"}.issubset(extra))
        with self.assertRaises(ValueError):
            realapps.qualification_denials({"deny": "Play"})

    def test_calculator_oracle_excludes_buttons_and_ambiguous_numeric_history(self):
        display = self.helpers().calculator_display
        result = {"role": "AXStaticText", "label": "5"}
        button = {"role": "AXButton", "label": "5"}
        self.assertEqual(display({"elements": [result, button]}), "5")
        self.assertIsNone(display({"elements": [button]}))
        self.assertIsNone(display({"elements": [result, dict(result, label="7")]}))

    def test_native_oracle_requests_readonly_tree_as_well_as_actionable_elements(self):
        helpers = self.helpers()
        target = {"pid": 7, "window_id": 2}
        session = SimpleNamespace(call=Mock(return_value=dict(target, elements=[])))
        helpers.state_for(session, target)
        session.call.assert_called_once_with("get_window_state", dict(
            target, include_screenshot=False, tree_format="both", max_elements=2000))

    def test_calculator_reads_non_actionable_native_display_with_direction_mark(self):
        display = self.helpers().calculator_display
        tree = '- [0] AXWindow "Calculator"\n    - AXStaticText = "\\u200e0"\n    - [1] AXButton (5)'
        state = {"elements": [{"role": "AXButton", "label": "5"}], "tree_markdown": tree}
        self.assertEqual(display(state), "0")
        self.assertIsNone(display(dict(state, tree_markdown=tree + '\n    - AXStaticText = "5"')))
        self.assertIsNone(display(dict(state, tree_markdown=tree.replace("\\u200e0", "not a number"))))

    def test_calculator_waits_for_native_display_before_starting_product_actor(self):
        helpers = self.helpers()
        target = {"pid": 7, "window_id": 2}
        ready = dict(target, elements=[], truncated=False, tree_markdown='- AXStaticText = "0"')
        session = SimpleNamespace(metadata={}, drive=Mock(side_effect=RuntimeError("actor_reached")))
        def wait(probe, *_):
            first = probe()
            return first or probe()
        with patch.object(helpers, "visible_window", return_value=target), \
             patch.object(helpers, "state_for", side_effect=[dict(target, elements=[]), ready, ready]), \
             patch.object(helpers, "screenshot"):
            with self.assertRaisesRegex(RuntimeError, "actor_reached"):
                helpers.calculator(session, wait)
        session.drive.assert_called_once()

    def test_spotify_oracle_distinguishes_missing_evidence_from_wrong_results(self):
        verify = self.helpers().spotify_outcome
        self.assertIsNone(verify({"elements": []}, "Mozart")[1])
        field = {"role": "AXSearchField", "element_index": 1, "label": "Search", "value": "Mozart"}
        result = {"role": "AXStaticText", "element_index": 2, "label": "Wolfgang Amadeus Mozart"}
        self.assertTrue(verify({"elements": [field, result]}, "Mozart")[1])
        self.assertFalse(verify({"elements": [field]}, "Mozart")[1])

    def test_spotify_explicitly_refuses_when_no_negative_query_is_available(self):
        helpers = self.helpers()
        fields = []
        for query in ("Mozart", "Debussy", "Bach"):
            fields += [{"role": "AXSearchField", "label": "Search", "value": query},
                       {"role": "AXStaticText", "label": query}]
        target = {"pid": 7, "window_id": 2}
        with patch.object(helpers, "visible_window", return_value=target), \
             patch.object(helpers, "state_for", return_value={"elements": fields}), \
             patch.object(helpers.subprocess, "run", return_value=SimpleNamespace(stdout="Spotify")):
            with self.assertRaisesRegex(RuntimeError, "spotify_oracle_negative_control_unavailable"):
                helpers.spotify(SimpleNamespace(metadata={}), None, None)


class QualificationReportTests(unittest.TestCase):
    def helpers(self):
        spec = importlib.util.spec_from_file_location("current_report", HERE / "jev-current-evidence-report.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_native_context_report_keeps_interruption_resume_and_harness_delta(self):
        helpers = self.helpers()
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "native-ancestor-frozen-stage"
            stage.mkdir()
            (stage / "stage-receipt.json").write_text(json.dumps({"candidates": {
                arm: {"frozen_payload_verified": True} for arm in ("before", "after")}}))
            for name, status, runs in [
                ("native-ancestor-matched-ab", "error",
                 [("before-0", True, "a" * 64), ("after-0", True, "a" * 64),
                  ("after-1", None, "a" * 64)]),
                ("native-ancestor-matched-resume", "complete", [("after-0", False, "b" * 64)]),
            ]:
                lane = root / name
                lane.mkdir()
                (lane / "summary.json").write_text(json.dumps({"status": status}))
                for run, success, harness in runs:
                    path = lane / run
                    path.mkdir()
                    row = {"case": "textedit.replace.body", "status": "done" if success else "blocked",
                           "strict_success": success, "verified": True, "false_done": False,
                           "wall_ms": 2000, "actual_state": {
                               "document_body_matches": True, "native_exact_value_verified": True}}
                    (path / "results.json").write_text(json.dumps({
                        "rows": [] if success is None else [row], "resources_clean": True,
                        "harness_sha256": harness,
                    }))
            data = helpers.native_context_evidence(root)
            self.assertEqual(data["scores"]["candidate"]["trials"], 2)
            self.assertEqual(data["scores"]["candidate"]["strict_successes"], 1)
            self.assertEqual(data["comparison_preflight_errors"], 1)
            self.assertFalse(data["uninterrupted_matched_comparison"])
            self.assertTrue(data["harness_hash_changed"])
            self.assertIsNone(data["scores"]["candidate"]["successful_wall_median_ms"])
            path = root / "native-ancestor-matched-resume/after-0/results.json"
            self.assertEqual(data["inputs"][str(path.relative_to(root))], helpers.digest(path))
            page = helpers.native_context_section(data, root)
            self.assertIn("Candidate: 1/2", page)
            self.assertIn("not an uninterrupted matched comparison", page)

    def test_native_context_report_does_not_invent_unrun_evidence(self):
        helpers = self.helpers()
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(helpers.native_context_evidence(Path(directory)))
            self.assertEqual(helpers.native_context_section(None, Path(directory)), "")

    def test_report_counts_strict_results_not_mutations_and_keeps_unknown_done(self):
        rows = [
            {"status": "done", "strict_success": True, "verified": True, "false_done": False, "wall_ms": 20},
            {"status": "blocked", "strict_success": False, "verified": True, "false_done": False, "wall_ms": 10},
            {"status": "done", "strict_success": False, "verified": False, "false_done": None,
             "verification_status": "unavailable", "wall_ms": 50},
        ]
        result = self.helpers().summarize(rows)
        self.assertEqual(result["strict_successes"], 1)
        self.assertEqual(result["verified_outcomes"], 2)
        self.assertEqual(result["unverified_done"], 1)
        self.assertEqual(result["confirmed_false_done"], 0)
        self.assertIsNone(result["successful_wall_median_ms"])

    def test_report_preserves_preflight_error_without_inventing_an_actor_trial(self):
        helpers = self.helpers()
        with tempfile.TemporaryDirectory() as directory:
            lane = Path(directory) / "case"
            (lane / "after-0").mkdir(parents=True)
            (lane / "summary.json").write_text(json.dumps({"status": "error", "error_type": "RuntimeError"}))
            (lane / "after-0/results.json").write_text(json.dumps({"rows": [], "resources_clean": True}))
            result = helpers.load_lane(Path(directory), "case")
            self.assertEqual(result["state"], "error")
            self.assertEqual(result["preflight_errors"], 1)
            self.assertEqual(result["rows"], [])
            self.assertTrue(result["resources_clean"])

    def test_report_marks_missing_evidence_as_missing_not_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.helpers().load_lane(Path(directory), "not-run")
            self.assertEqual(result["state"], "missing")
            self.assertEqual(result["rows"], [])

    def test_report_binds_playback_facts_to_matching_actor_and_input_digest(self):
        helpers = self.helpers()
        primary = [{"message": "Visual primary operation=none selectedP=0.93"}]
        lane = {"rows": [{"actor_pid": 77, "actual_state": {"playback_unchanged": False},
                          "visual_trace": primary, "visual_trace_complete": True}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "playback-event-forensics.json"
            path.write_text(json.dumps({"actor_pid": 77, "tool_dispatch_effects": [], "visual_primary": primary}))
            result = helpers.playback_evidence(Path(directory), lane)
            self.assertEqual(result["actor_pid"], 77)
            self.assertTrue(result["fingerprint_changed"])
            self.assertFalse(result["actor_dispatched_input_or_playback"])
            self.assertEqual(result["forensics_sha256"], hashlib.sha256(path.read_bytes()).hexdigest())
            path.write_text(json.dumps({"actor_pid": 78, "tool_dispatch_effects": [], "visual_primary": primary}))
            self.assertIsNone(helpers.playback_evidence(Path(directory), lane)["actor_dispatched_input_or_playback"])

    def test_report_missing_playback_forensics_cannot_prove_no_action(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.helpers().playback_evidence(Path(directory), {"rows": []})
            self.assertIsNone(result["actor_dispatched_input_or_playback"])
            self.assertIsNone(result["fingerprint_changed"])
            self.assertIsNone(result["forensics_sha256"])


class ApprovedArchiveScopeTests(unittest.TestCase):
    def test_approved_633_before_mode_lists_only_that_bundle_without_writes(self):
        result = subprocess.run([
            sys.executable, str(HERE / "jev-archive-signed-pairs.py"),
            "--approved-633-before", "--list-targets",
        ], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads(result.stdout)
        receipt = json.loads((HERE / "jev-vision-stage-633e8fb9c3f54b638a13cfd3aa76ba3a.json").read_text())
        self.assertEqual(record["targets"], [receipt["candidates"]["before"]["app"]])
        current = json.loads((HERE / "jev-vision-stage-8909322f313342eba82c860291e3ba70.json").read_text())
        self.assertEqual(set(record["retained_current"]), {item["app"] for item in current["candidates"].values()})


class FrozenStageTests(unittest.TestCase):
    def helpers(self):
        spec = importlib.util.spec_from_file_location("frozen_stage", HERE / "jev-vision-stage.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def manifest(self):
        return {
            "Contents": {"kind": "directory", "mode": 0o755},
            "Contents/MacOS/JevVoice": {"kind": "file", "mode": 0o755, "sha256": "old-main"},
            "Contents/_CodeSignature/CodeResources": {"kind": "file", "mode": 0o644, "sha256": "old-seal"},
            "Contents/Info.plist": {"kind": "file", "mode": 0o644, "sha256": "info"},
            "Contents/Resources/cua-driver": {"kind": "file", "mode": 0o755, "sha256": "driver"},
            "Contents/Resources/sdk": {"kind": "link", "mode": 0o755, "target": "native-sdk"},
        }

    def test_only_main_and_root_seal_bytes_may_change(self):
        before = self.manifest()
        after = {name: dict(row) for name, row in before.items()}
        after["Contents/MacOS/JevVoice"]["sha256"] = "new-main"
        after["Contents/_CodeSignature/CodeResources"]["sha256"] = "new-seal"
        self.helpers().assert_frozen_payload(before, after)

    def test_payload_guard_rejects_resource_info_modes_links_additions_and_removals(self):
        before = self.manifest()
        for shape in ["resource", "info", "mode", "main-mode", "link", "added", "removed"]:
            after = {name: dict(row) for name, row in before.items()}
            if shape == "resource":
                after["Contents/Resources/cua-driver"]["sha256"] = "re-signed-driver"
            elif shape == "info":
                after["Contents/Info.plist"]["sha256"] = "new-info"
            elif shape == "mode":
                after["Contents"]["mode"] = 0o777
            elif shape == "main-mode":
                after["Contents/MacOS/JevVoice"]["mode"] = 0o777
            elif shape == "link":
                after["Contents/Resources/sdk"]["target"] = "foreign-sdk"
            elif shape == "added":
                after["foreign"] = {"kind": "file", "mode": 0o644, "sha256": "foreign"}
            else:
                del after["Contents/Resources/cua-driver"]
            with self.assertRaisesRegex(RuntimeError, "^frozen_template_payload_changed$"):
                self.helpers().assert_frozen_payload(before, after)

    def test_signing_uses_baseline_flags_and_no_recursive_signing(self):
        command = self.helpers().root_signing_arguments(Path("/owned/app"), "0x0(none)", None)
        self.assertNotIn("--deep", command)
        self.assertEqual(command[command.index("--options") + 1], "0x0")
        self.assertEqual(command[command.index("--sign") + 1], "Jev Voice Local Dev")
        self.assertNotIn("--entitlements", command)
        command = self.helpers().root_signing_arguments(
            Path("/owned/app"), "0x10000(runtime)", Path("/owned/baseline-entitlements"))
        self.assertEqual(command[command.index("--options") + 1], "0x10000")
        self.assertEqual(command[command.index("--entitlements") + 1], "/owned/baseline-entitlements")

    def test_frozen_source_delta_requires_exact_reviewed_changes(self):
        helpers = self.helpers()
        expected, current = {"stable": "same", "field": "old"}, {"stable": "same", "field": "new"}
        delta = {"field": {"before": "old", "after": "new"}}
        helpers.verify_frozen_source(expected, current, delta)
        for proposed in [{}, {"field": {"before": "wrong", "after": "new"}},
                         dict(delta, ghost={"before": None, "after": "new"})]:
            with self.assertRaises(RuntimeError):
                helpers.verify_frozen_source(expected, current, proposed)

    def test_frozen_mode_is_available_through_existing_stage_cli(self):
        result = subprocess.run([sys.executable, str(HERE / "jev-vision-stage.py"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0)
        for flag in ["--baseline-receipt", "--reviewed-source-delta", "--out"]:
            self.assertIn(flag, result.stdout)

    def workspace_subject(self, root):
        app = root / "before.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/MacOS/JevVoice").write_bytes(b"owned-test-main")
        spec = importlib.util.spec_from_file_location("lease_archive", HERE / "jev-archive-signed-pairs.py")
        archive = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(archive)
        manifest = root / "before-manifest.json"
        manifest.write_text(json.dumps(archive.manifest(app)))
        return {"app": str(app), "frozen_payload_verified": True,
                "manifest_path": str(manifest), "manifest_sha256": realapps.digest(manifest)}

    def test_workspace_bundle_gets_an_exact_temporary_execution_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = self.workspace_subject(Path(directory))
            with realapps.execution_bundle(subject) as app:
                self.assertNotEqual(app, Path(subject["app"]))
                self.assertEqual((app / "Contents/MacOS/JevVoice").read_bytes(), b"owned-test-main")
                runtime = app.parent
            self.assertFalse(runtime.exists())
            self.assertTrue(Path(subject["app"]).exists())

    def test_runtime_lease_rejects_changed_manifest_or_workspace_bytes(self):
        for shape in ["manifest", "bytes"]:
            with tempfile.TemporaryDirectory() as directory:
                subject = self.workspace_subject(Path(directory))
                if shape == "manifest":
                    Path(subject["manifest_path"]).write_text("{}")
                else:
                    (Path(subject["app"]) / "Contents/MacOS/JevVoice").write_bytes(b"foreign")
                with self.assertRaisesRegex(RuntimeError, "^frozen_workspace_manifest_changed$"):
                    with realapps.execution_bundle(subject):
                        self.fail("unverified bundle leased")

    def test_runtime_lease_preserves_legacy_subject_paths(self):
        with realapps.execution_bundle({"app": "/legacy/before.app"}) as app:
            self.assertEqual(app, Path("/legacy/before.app"))

    def test_prepared_runtime_reuses_verified_inode_without_owning_outer_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = self.workspace_subject(Path(directory))
            original = Path(subject["app"]) / "Contents/MacOS/JevVoice"
            with realapps.execution_bundle(subject) as prepared:
                inode = prepared.stat().st_ino
                with patch.object(realapps.subprocess, "run") as run:
                    for _ in range(2):
                        with realapps.execution_bundle(subject, prepared_app=prepared) as app:
                            self.assertEqual(app, prepared)
                            self.assertEqual(app.stat().st_ino, inode)
                        self.assertTrue(prepared.exists())
                    self.assertTrue(run.call_args_list)
                    self.assertTrue(all(item.args[0][0] == "codesign"
                                        for item in run.call_args_list))
                self.assertEqual(original.read_bytes(), b"owned-test-main")
            self.assertFalse(prepared.exists())

    def test_prepared_runtime_rejects_changed_canonical_copy_and_symlinks(self):
        for shape in ["canonical", "manifest", "prepared", "symlink"]:
            with self.subTest(shape=shape), tempfile.TemporaryDirectory() as directory:
                subject = self.workspace_subject(Path(directory))
                with realapps.execution_bundle(subject) as prepared:
                    proposed = prepared
                    if shape == "canonical":
                        (Path(subject["app"]) / "Contents/MacOS/JevVoice").write_bytes(b"changed")
                    elif shape == "manifest":
                        Path(subject["manifest_path"]).write_text("{}")
                    elif shape == "prepared":
                        (prepared / "Contents/MacOS/JevVoice").write_bytes(b"changed")
                    else:
                        proposed = prepared.parent / "linked.app"
                        proposed.symlink_to(prepared, target_is_directory=True)
                    with self.assertRaisesRegex(
                            RuntimeError, "^frozen_(workspace_manifest|prepared_runtime)_changed$"):
                        with realapps.execution_bundle(subject, prepared_app=proposed):
                            self.fail("unverified prepared copy reused")

    def test_prepared_runtime_rejects_mutation_during_use_and_legacy_bypass(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = self.workspace_subject(Path(directory))
            with realapps.execution_bundle(subject) as prepared, \
                 patch.object(realapps.subprocess, "run"):
                with self.assertRaisesRegex(RuntimeError, "^frozen_prepared_runtime_changed$"):
                    with realapps.execution_bundle(subject, prepared_app=prepared):
                        (prepared / "Contents/MacOS/JevVoice").write_bytes(b"changed")
        with self.assertRaisesRegex(RuntimeError, "^frozen_prepared_runtime_changed$"):
            with realapps.execution_bundle({"app": "/legacy/before.app"},
                                          prepared_app=Path("/legacy/before.app")):
                self.fail("legacy subject accepted prepared-copy bypass")

    def test_prepared_runtime_rechecks_signature_after_use(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = self.workspace_subject(Path(directory))
            with realapps.execution_bundle(subject) as prepared, \
                 patch.object(realapps.subprocess, "run", side_effect=[
                     SimpleNamespace(returncode=0),
                     subprocess.CalledProcessError(1, ["codesign"]),
                 ]):
                with self.assertRaises(subprocess.CalledProcessError):
                    with realapps.execution_bundle(subject, prepared_app=prepared):
                        pass

    def test_prepared_runtime_rejects_matching_copy_without_an_active_outer_lease(self):
        with tempfile.TemporaryDirectory() as directory, \
             tempfile.TemporaryDirectory(prefix="jev-qualified-runtime-") as rogue:
            subject = self.workspace_subject(Path(directory))
            app = Path(rogue) / "before.app"
            subprocess.run(["cp", "-cRpP", subject["app"], str(app)], check=True, timeout=10)
            with patch.object(realapps.subprocess, "run"), \
                 self.assertRaisesRegex(RuntimeError, "^frozen_prepared_runtime_changed$"):
                with realapps.execution_bundle(subject, prepared_app=app):
                    self.fail("unowned matching copy accepted")

    def test_driver_artifact_validation_rejects_bad_version_exit_or_changed_inode(self):
        for shape in ["exit", "version", "replacement"]:
            with self.subTest(shape=shape), tempfile.TemporaryDirectory() as directory:
                app = Path(directory) / "before.app"
                driver = app / "Contents/Resources/cua-driver"
                driver.parent.mkdir(parents=True)
                driver.write_bytes(b"owned-driver")
                subject = {"driver_sha256": realapps.digest(driver)}
                def run(argv, **kwargs):
                    if argv[0] == "codesign":
                        return SimpleNamespace(returncode=0)
                    self.assertEqual(argv, [str(driver), "--version"])
                    self.assertEqual(kwargs["timeout"], 90)
                    self.assertEqual(kwargs["env"]["CUA_TELEMETRY"], "0")
                    if shape == "replacement":
                        replacement = driver.with_suffix(".replacement")
                        replacement.write_bytes(b"owned-driver")
                        replacement.replace(driver)
                    return SimpleNamespace(returncode=1 if shape == "exit" else 0,
                                           stdout="wrong" if shape == "version" else "cua-driver 0.45.4\n",
                                           stderr="")
                with patch.object(qualification.subprocess, "run", side_effect=run):
                    with self.assertRaisesRegex(
                            RuntimeError, "^(artifact_version_validation_failed|artifact_driver_changed)"):
                        qualification.check_driver_artifact(subject, app)

    def test_qualification_prepares_once_reuses_paths_and_reports_setup_failure(self):
        for failing in [False, True]:
            with self.subTest(failing=failing), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                receipt = root / "stage.json"
                receipt.write_text(json.dumps({"candidates": {
                    variant: {"app": str(root / (variant + ".app")),
                              "frozen_payload_verified": True}
                    for variant in ["before", "after"]}}))
                out = root / "results"
                argv = ["qualification", "preflight", "--receipt", str(receipt), "--out", str(out)]
                with patch.object(qualification.sys, "argv", argv), \
                     patch.dict(qualification.os.environ, JARVIS_P4_REAL_APPS="approved"), \
                     patch.object(qualification, "execution_receipt", return_value={}), \
                     patch.object(qualification.real, "execution_bundle") as lease, \
                     patch.object(qualification, "check_driver_artifact", create=True) as probe, \
                     patch.object(qualification.real, "Session") as factory, \
                     patch.object(qualification, "preflight"), patch("builtins.print"):
                    prepared = root / "prepared.app"
                    lease.return_value.__enter__.return_value = prepared
                    probe.return_value = {"read_only_cli_ms": 8.0, "driver_inode": 7,
                                          "version": "cua-driver 0.45.4"}
                    if failing:
                        probe.side_effect = RuntimeError("artifact_version_validation_failed")
                    session = factory.return_value.__enter__.return_value
                    session.metadata = {"resources_clean": True, "rows": []}
                    if failing:
                        with self.assertRaisesRegex(RuntimeError, "artifact_version_validation_failed"):
                            qualification.main()
                        factory.assert_not_called()
                    else:
                        self.assertEqual(qualification.main(), 0)
                        self.assertEqual(probe.call_count, 2)
                        self.assertEqual(factory.call_count, 2)
                        self.assertTrue(all(row.kwargs["prepared_app"] == prepared
                                            for row in factory.call_args_list))
                    summary = json.loads((out / "summary.json").read_text())
                    self.assertGreaterEqual(summary["total_wall_ms"], 0)
                    preparation = summary["runtime_preparation"]["before"]
                    self.assertGreaterEqual(preparation["setup_wall_ms"], 0)
                    self.assertEqual(preparation["status"], "error" if failing else "pass")
                    if not failing:
                        self.assertEqual(preparation["cold_validation_ms"], 8.0)
                        self.assertEqual(preparation["prepared_driver_inode"], 7)
                    lease.return_value.__exit__.assert_called()

    def test_repeated_aliases_share_one_lease_and_record_each_execution_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            main = root / "canonical.app/Contents/MacOS/JevVoice"
            main.parent.mkdir(parents=True)
            main.write_bytes(b"canonical-unchanged")
            receipt = root / "stage.json"
            subject = {"app": str(root / "canonical.app"), "frozen_payload_verified": True}
            receipt.write_text(json.dumps({"candidates": {"before": subject, "after": subject}}))
            out = root / "results"
            argv = ["qualification", "native-proof", "--receipt", str(receipt), "--out", str(out),
                    "--fixture", str(root / "fixture.json"), "--repeats", "3"]
            prepared = root / "prepared.app"
            with patch.object(qualification.sys, "argv", argv), \
                 patch.dict(qualification.os.environ, JARVIS_P4_REAL_APPS="approved"), \
                 patch.object(qualification, "execution_receipt", return_value={}), \
                 patch.object(qualification.real, "execution_bundle") as lease, \
                 patch.object(qualification, "check_driver_artifact") as probe, \
                 patch.object(qualification.real, "Session") as factory, \
                 patch.object(qualification, "preflight"), \
                 patch.object(qualification, "fixture") as fixture, \
                 patch.object(qualification, "native_proof"), patch("builtins.print"):
                lease.return_value.__enter__.return_value = prepared
                probe.return_value = {"read_only_cli_ms": 8.0, "driver_inode": 7,
                                      "version": "cua-driver 0.45.4"}
                fixture.return_value.__enter__.return_value = ({}, root / "state.json", {})
                session = factory.return_value.__enter__.return_value
                session.metadata = {"resources_clean": True, "rows": [],
                                    "execution_app": str(prepared), "driver_inode": 7}
                self.assertEqual(qualification.main(), 0)
                self.assertEqual(lease.call_count, 1)
                self.assertEqual(probe.call_count, 1)
                self.assertEqual(factory.call_count, 6)
                self.assertTrue(all(item.kwargs["prepared_app"] == prepared
                                    for item in factory.call_args_list))
            summary = json.loads((out / "summary.json").read_text())
            self.assertEqual(summary["runtime_preparation"]["after"]["reused_preparation_of"], "before")
            for row in summary["variants"].values():
                self.assertEqual(row["prepared_execution_app"], str(prepared))
                self.assertEqual(row["prepared_driver_inode"], 7)
            self.assertEqual(main.read_bytes(), b"canonical-unchanged")

    def test_warm_pilot_cleanup_error_keeps_both_seed_receipt_links(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "candidate.app"
            info = app / "Contents/Info.plist"
            info.parent.mkdir(parents=True)
            info.write_bytes(qualification.plistlib.dumps({"JevExperimentalWindowImages": True}))
            receipt = root / "stage.json"
            receipt.write_text(json.dumps({"candidates": {
                variant: {"app": str(app), "frozen_payload_verified": True}
                for variant in ("before", "after")}}))
            out = root / "results"
            argv = ["qualification", "realapps-everyday", "--receipt", str(receipt),
                    "--out", str(out), "--app-case", "calculator", "--pilot",
                    "--repeats", "1", "--warm-same-session"]
            def pilot(session, wait):
                for kind in ("cold", "warm"):
                    (out / "after-0" / f"calculator-{kind}-seed.json").write_text(
                        json.dumps({"verified": True, "kind": kind}))
            helpers = SimpleNamespace(calculator_pilot=Mock(side_effect=pilot))
            with patch.object(qualification.sys, "argv", argv), \
                 patch.dict(qualification.os.environ, JARVIS_P4_REAL_APPS="approved"), \
                 patch.object(qualification, "execution_receipt", return_value={}), \
                 patch.object(qualification.real, "execution_bundle") as lease, \
                 patch.object(qualification, "check_driver_artifact") as probe, \
                 patch.object(qualification.real, "Session") as factory, \
                 patch.object(qualification, "preflight"), \
                 patch.object(qualification, "load", return_value=helpers), patch("builtins.print"):
                lease.return_value.__enter__.return_value = root / "prepared.app"
                probe.return_value = dict(read_only_cli_ms=8, driver_inode=7, version="cua-driver 0.45.4")
                factory.return_value.__enter__.return_value.metadata = {"rows": [], "resources_clean": False}
                factory.return_value.__exit__.side_effect = RuntimeError("owned_cleanup_failed")
                with self.assertRaisesRegex(RuntimeError, "^owned_cleanup_failed$"):
                    qualification.main()
            summary = json.loads((out / "summary.json").read_text())
            self.assertEqual(summary["status"], "error")
            self.assertEqual(summary["error_message"], "owned_cleanup_failed")
            self.assertEqual(summary["failed_run_artifacts"]["calculator_seeds"], {
                kind: f"after-0/calculator-{kind}-seed.json" for kind in ("cold", "warm")})

    def test_session_enter_failure_closes_any_execution_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            subject = self.workspace_subject(Path(directory))
            session = realapps.Session(Path(directory), Path(directory) / "receipt.json")
            leased = []
            def fail_start():
                app = session.bundle_stack.enter_context(realapps.execution_bundle(subject))
                leased.append(app.parent)
                raise RuntimeError("startup-refused")
            with patch.object(session, "_enter", side_effect=fail_start):
                with self.assertRaisesRegex(RuntimeError, "^startup-refused$"):
                    session.__enter__()
            self.assertFalse(leased[0].exists())

    def test_artifact_check_uses_the_verified_execution_lease(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            runtime = root / "runtime.app"
            (runtime / "Contents/Resources").mkdir(parents=True)
            driver = runtime / "Contents/Resources/cua-driver"
            driver.write_bytes(b"owned-driver")
            subject = {"app": str(root / "workspace.app"), "driver_sha256": realapps.digest(driver)}
            receipt = root / "receipt.json"
            receipt.write_text(json.dumps({"candidates": {"before": subject}}))
            with patch.object(qualification.real, "execution_bundle") as lease, \
                 patch.object(qualification.subprocess, "run",
                              return_value=SimpleNamespace(returncode=0, stdout="cua-driver 0.45.4\n")) as run:
                lease.return_value.__enter__.return_value = runtime
                qualification.check_artifacts(receipt, root)
                lease.assert_called_once_with(subject)
                self.assertEqual(run.call_args_list[0].args[0][-1], str(runtime))


class OwnedFixtureReadinessTests(unittest.TestCase):
    def test_owned_sheet_window_is_not_an_unrelated_document_to_retain(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        lease = {"window": {"window_id": 42}, "other_windows_retained": [43, 44]}
        native = {"modal_sheets": 1, "owned_sheet_window_ids": [44]}
        self.assertEqual(helpers.unrelated_windows_to_retain(lease, native), {43})

    def test_unproven_sheet_window_cannot_be_exempted_from_retention(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        lease = {"window": {"window_id": 42}, "other_windows_retained": [43, 44]}
        for native in [{}, {"modal_sheets": 1, "owned_sheet_window_ids": []},
                       {"modal_sheets": 1, "owned_sheet_window_ids": [99]},
                       {"modal_sheets": 1, "owned_sheet_window_ids": [44, 44]}]:
            with self.assertRaisesRegex(RuntimeError, "^owned_fixture_sheet_window_identity_unverified$"):
                helpers.unrelated_windows_to_retain(lease, native)

    def conflict_state(self):
        return {"pid": 7, "window_id": 42, "window_title": "Jev-Test-Document-marker.txt",
                "capture_id": "owned-capture", "elements": [
                    {"element_index": 0, "role": "AXWindow"},
                    {"element_index": 1, "parent_index": 0, "role": "AXSheet"},
                    {"element_index": 2, "parent_index": 1, "role": "AXStaticText",
                     "label": "Jev-Test-Document-marker.txt could not be autosaved. "
                              "The file has been changed by another application."},
                    {"element_index": 3, "parent_index": 1, "role": "AXButton",
                     "label": "Save Anyway", "element_token": "owned-button", "actions": ["AXPress"]},
                ]}

    def test_conflict_save_target_keeps_native_capture_and_never_uses_coordinates(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        target = helpers.owned_conflict_save_target(self.conflict_state(),
            {"pid": 7, "window_id": 42}, "marker", Path("/fixture/Jev-Test-Document-marker.txt"))
        self.assertEqual(target, {"pid": 7, "window_id": 42, "capture_id": "owned-capture",
                                 "element_token": "owned-button", "action": "press",
                                 "delivery_mode": "background"})

    def test_conflict_save_refuses_ambiguous_foreign_or_uncaptured_targets(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        for change in ["pid", "window", "title", "capture", "sheet", "duplicate", "foreign-warning",
                       "foreign-button", "unadvertised", "token"]:
            state = self.conflict_state()
            if change in ("pid", "window", "title", "capture"):
                state[{"pid": "pid", "window": "window_id", "title": "window_title",
                       "capture": "capture_id"}[change]] = None
            elif change == "sheet":
                state["elements"][1]["role"] = "AXGroup"
            elif change == "duplicate":
                state["elements"].append(dict(state["elements"][3], element_index=4))
            elif change == "foreign-warning":
                state["elements"][2]["label"] = "Another document could not be autosaved."
            elif change == "foreign-button":
                state["elements"][3]["parent_index"] = 0
            elif change == "unadvertised":
                state["elements"][3]["actions"] = []
            else:
                state["elements"][3]["element_token"] = None
            with self.assertRaisesRegex(RuntimeError, "^owned_fixture_conflict_target_unverified$"):
                helpers.owned_conflict_save_target(state, {"pid": 7, "window_id": 42},
                    "marker", Path("/fixture/Jev-Test-Document-marker.txt"))

    def session(self, native):
        window = {"pid": 7, "window_id": 42}
        fixture = {"window": window, "marker": "marker", "path": Path("/fixture"),
                   "baseline": "baseline", "value": "replacement"}
        return SimpleNamespace(
            metadata={"owned_document_reads": [{"expected_window": window, "native": native}]},
            adopt_document_fixture=Mock(return_value=fixture),
            read_owned_document=Mock(return_value="baseline"), call=Mock(), drive=Mock())

    def test_owned_fixture_modal_stops_before_reset_or_jev(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        session = self.session({"modal_sheets": 1, "role_read_failures": 0, "children_read_failures": 0})
        with self.assertRaisesRegex(RuntimeError, "^owned_fixture_blocked_by_sheet$"):
            helpers.textedit_owned(session, "receipt")
        session.call.assert_not_called()
        session.drive.assert_not_called()

    def test_owned_fixture_unknown_modal_proof_stops_before_jev(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        for native in [{}, {"modal_sheets": False}, {"modal_sheets": -1},
                       {"modal_sheets": 0, "role_read_failures": 1, "children_read_failures": 0},
                       {"modal_sheets": 0, "role_read_failures": 0, "children_read_failures": 1}]:
            session = self.session(native)
            with self.assertRaisesRegex(RuntimeError, "^owned_fixture_readiness_unverified$"):
                helpers.textedit_owned(session, "receipt")
            session.drive.assert_not_called()

    def test_owned_fixture_complete_modal_free_proof_allows_one_jev_request(self):
        helpers = qualification.load("readiness_helpers", "jev-realapps-native.py")
        session = self.session({"modal_sheets": 0, "role_read_failures": 0, "children_read_failures": 0})
        helpers.textedit_owned(session, "receipt")
        session.drive.assert_called_once()


class OwnedFixtureInspectionTests(unittest.TestCase):
    def test_failed_owned_read_keeps_readiness_evidence_without_relaxing_oracle(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            title = "Jev-Test-Document-0123456789.txt"
            session = realapps.Session(root, root / "receipt.json")
            state = {"pid": 7, "window_id": 42, "window_title": title, "truncated": True}
            native = {"ax_trusted": True, "target_found": True, "budget_exhausted": False,
                      "pid": 7, "window_id": 42, "window_title": {
                          "sha256": hashlib.sha256(title.encode()).hexdigest(),
                          "utf8_count": len(title.encode())}}
            with patch.object(session, "call", return_value=state), \
                 patch.object(session, "native_window_state", return_value=native):
                with self.assertRaisesRegex(RuntimeError, "^owned_document_body_unverified$"):
                    session.read_owned_document({"pid": 7, "window_id": 42},
                                                "0123456789", root / title, ["known"])
            observed = session.metadata["owned_document_reads"][0]
            self.assertIs(observed["sdk"]["truncated"], True)
            self.assertIs(observed["native_window_proven"], True)
            self.assertIs(observed["sdk_title_has_marker"], True)

    def test_readonly_inspection_records_exact_sdk_and_native_readiness(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            title = "Jev-Test-Document-0123456789.txt"
            record = root / "record.json"
            record.write_text(json.dumps({
                "textedit_roster_pids": [7], "rows": [{
                    "case": "textedit.replace.body", "requested_window_id": 42,
                    "goal": "Replace with Jev real app text entry 0123456789.",
                }],
            }))
            state = {"pid": 7, "window_id": 42, "window_title": title,
                     "truncated": True, "elements": []}
            native = {"ax_trusted": True, "target_found": True, "budget_exhausted": False,
                      "pid": 7, "window_id": 42, "window_title": {
                          "sha256": hashlib.sha256(title.encode()).hexdigest(),
                          "utf8_count": len(title.encode())}}
            session = Mock(directory=root, metadata={})
            session.windows.return_value = [{"window_id": 42, "title": title}]
            session.call.return_value = state
            session.native_window_state.return_value = native
            session.raw_call.return_value = {"structuredContent": state, "content": []}
            qualification.cleanup_textedit(session, record, inspect_only=True)
            observed = session.metadata["owned_window_inspection"]
            self.assertIs(observed["truncated"], True)
            self.assertIs(observed["native_window_proven"], True)
            session.drive.assert_not_called()

    def test_inspection_uses_recorded_fixture_origin_not_legacy_roster(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            origin = root / "results.json"
            origin.write_text(json.dumps({
                "textedit_reuses_existing_app": False, "textedit_launch_requested": True,
                "drive_requests": 0, "textedit_launch_pid": 7,
                "owned_document_windows_remaining": [42],
            }))
            (root / "Jev-Test-Document-0123456789.txt").write_text("owned synthetic content")
            record = {
                "rows": [{"case": "textedit.replace.body", "requested_window_id": 42,
                          "goal": "Replace with Jev real app text entry 0123456789."}],
                "fixture_lease": {"origin": str(origin), "origin_sha256": realapps.digest(origin),
                                 "window": {"pid": 7, "window_id": 42}, "process_stamp": "owned"},
            }
            self.assertEqual(qualification.inspection_target(record),
                             ("0123456789", {"pid": 7, "window_id": 42}))
            for key in ["origin_sha256", "window"]:
                changed = dict(record, fixture_lease=dict(record["fixture_lease"]))
                changed["fixture_lease"][key] = "foreign"
                with self.assertRaisesRegex(RuntimeError, "^owned_inspection_origin_unverified$"):
                    qualification.inspection_target(changed)

    def test_legacy_inspection_target_stays_supported(self):
        record = {"textedit_roster_pids": [7], "rows": [{
            "case": "textedit.replace.body", "requested_window_id": 42,
            "goal": "Replace with Jev real app text entry 0123456789.",
        }]}
        self.assertEqual(qualification.inspection_target(record),
                         ("0123456789", {"pid": 7, "window_id": 42}))


class OwnedDocumentCleanupTests(unittest.TestCase):
    def state(self):
        return {"pid": 7, "window_id": 42, "window_title": "Jev-Test-marker",
                "elements_complete": False, "truncated": False,
                "elements": [{"role": "AXTextArea", "value": "known"}]}

    def fingerprint(self, value):
        return {"sha256": hashlib.sha256(value.encode()).hexdigest(), "utf8_count": len(value.encode())}

    def native(self, path=None, body="known"):
        return {"pid": 7, "window_id": 42, "ax_trusted": True, "target_found": True,
                "budget_exhausted": False, "window_title": self.fingerprint("Jev-Test-marker"),
                "document": {"status": "file", "path": self.fingerprint(str((path or HERE / "owned.txt").resolve()))},
                "edited": False, "fields": [{"role": "AXTextArea", "value": self.fingerprint(body)}]}

    def test_only_complete_exact_owned_body_can_authorize_cleanup(self):
        window = {"pid": 7, "window_id": 42}
        path = HERE / "owned.txt"
        self.assertEqual(realapps.owned_document_body(
            self.state(), window, "marker", ["known"], path, self.native()), "known")
        self.assertEqual(realapps.owned_document_body(
            self.state(), window, "marker", ["known\n"], path, self.native(body="known\n")), "known\n")
        for changed in [
            {"pid": 8}, {"window_id": 43}, {"window_title": "Another document"},
            {"degraded": True},
        ]:
            with self.assertRaisesRegex(RuntimeError, "owned_document_body_unverified"):
                realapps.owned_document_body(dict(self.state(), **changed), window, "marker",
                                            ["known"], path, self.native())
        for native in [
            None, dict(self.native(), pid=8), dict(self.native(), window_id=43),
            dict(self.native(), ax_trusted=False), dict(self.native(), budget_exhausted=True),
            dict(self.native(), document={"status": "no_value", "path": None}),
            self.native(path=HERE / "other.txt"), self.native(body="known "),
            dict(self.native(), fields=[]),
            dict(self.native(), fields=[{"role": "AXTextArea", "value": None}]),
            dict(self.native(), fields=self.native()["fields"] * 2),
        ]:
            with self.assertRaisesRegex(RuntimeError, "owned_document_body_unverified"):
                realapps.owned_document_body(self.state(), window, "marker", ["known"], path, native)

    def test_complete_native_body_can_prove_owned_document_with_partial_sdk_tree(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owned.txt"
            window = {"pid": 7, "window_id": 42}
            state = dict(self.state(), truncated=True)
            native = self.native(path=path)
            self.assertEqual(realapps.owned_document_body(
                state, window, "marker", ["known"], path, native), "known")
            session = realapps.Session(Path(directory), Path(directory) / "receipt.json")
            with patch.object(session, "call", return_value=state), \
                 patch.object(session, "native_window_state", return_value=native):
                self.assertEqual(session.read_owned_document(window, "marker", path, ["known"]), "known")
            self.assertTrue(session.metadata["owned_document_reads"][0]["sdk_partial_native_complete"])

    def test_partial_sdk_tree_cannot_replace_missing_or_inexact_native_proof(self):
        path = HERE / "owned.txt"
        window = {"pid": 7, "window_id": 42}
        state = dict(self.state(), truncated=True)
        for native in [
            None, dict(self.native(), pid=8), dict(self.native(), window_id=43),
            dict(self.native(), ax_trusted=False), dict(self.native(), target_found=False),
            dict(self.native(), budget_exhausted=True),
            dict(self.native(), document={"status": "no_value", "path": None}),
            self.native(path=HERE / "foreign.txt"), self.native(body="know"),
            dict(self.native(), fields=[]),
            dict(self.native(), fields=self.native()["fields"] * 2),
            dict(self.native(), fields=[{"role": "AXSecureTextField", "value": self.fingerprint("known")}]),
            dict(self.native(), fields=[{"role": "AXTextArea", "value": {
                **self.fingerprint("known"), "utf8_count": 4}}]),
        ]:
            with self.subTest(native=native), self.assertRaisesRegex(
                    RuntimeError, "^owned_document_body_unverified$"):
                realapps.owned_document_body(state, window, "marker", ["known"], path, native)
        for changed in [{"pid": 8}, {"window_id": 43}, {"window_title": "foreign"}, {"degraded": True}]:
            with self.assertRaisesRegex(RuntimeError, "^owned_document_body_unverified$"):
                realapps.owned_document_body(dict(state, **changed), window, "marker",
                                            ["known"], path, self.native())

    def test_only_initial_native_unedited_empty_document_can_be_startup_blank(self):
        window = {"pid": 7, "window_id": 42, "title": "Jev-Test-marker"}
        native = dict(self.native(body=""), document={"status": "no_value", "path": None})
        self.assertTrue(realapps.owned_startup_blank(native, window, 7, {42}))
        for changed in [
            {"edited": True}, {"edited": None}, {"pid": 8}, {"window_id": 43},
            {"ax_trusted": False}, {"budget_exhausted": True},
            {"document": self.native()["document"]},
            {"document": {"status": "unreadable", "path": None}},
            {"fields": [{"role": "AXTextArea", "value": None}]},
            {"fields": self.native(body=" ")["fields"]},
        ]:
            self.assertFalse(realapps.owned_startup_blank(dict(native, **changed), window, 7, {42}))
        self.assertFalse(realapps.owned_startup_blank(native, window, 7, {43}))

    def test_native_menu_uses_real_invoke_menu_fields_and_explicit_window_focus(self):
        session = realapps.Session(HERE, HERE / "unused.json")
        window = {"pid": 7, "window_id": 42}
        with patch.object(session, "call") as invoke:
            session.invoke_window_menu(window, ["File", "Save"])
        self.assertEqual(invoke.call_args_list, [
            call("bring_to_front", window),
            call("invoke_menu", dict(window, path=["File", "Save"])),
        ])

    def test_fixture_adoption_never_owns_or_closes_the_other_window_or_process(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            marker = "0123456789"
            baseline = "Jev native document baseline " + marker + ".\n"
            path = root / ("Jev-Test-Document-" + marker + ".txt")
            path.write_text(baseline)
            source = root / "results.json"
            metadata = {"textedit_reuses_existing_app": False, "textedit_launch_requested": True,
                        "textedit_launch_pid": 7, "owned_document_windows_remaining": [42],
                        "drive_requests": 0, "rows": []}
            source.write_text(json.dumps(metadata))
            session = realapps.Session(root, HERE / "unused.json")
            session.windows = lambda **_: [
                {"pid": 7, "window_id": 42, "title": path.stem},
                {"pid": 7, "window_id": 43, "title": "Restored document"},
            ]
            with patch.object(session, "read_owned_document", return_value=baseline), \
                 patch.object(realapps, "process_stamp", return_value="started"), \
                 patch.object(session, "call") as mutate:
                fixture = session.adopt_document_fixture(source)
                self.assertEqual(fixture["window"], {"pid": 7, "window_id": 42})
                self.assertEqual(session.owned_documents, [])
                self.assertEqual(session.owned_document_processes, {})
                mutate.assert_not_called()
                for changed in [
                    dict(metadata, textedit_reuses_existing_app=True),
                    dict(metadata, owned_document_windows_remaining=[42, 43]),
                    dict(metadata, drive_requests=1),
                ]:
                    source.write_text(json.dumps(changed))
                    with self.assertRaisesRegex(RuntimeError, "owned_fixture"):
                        session.adopt_document_fixture(source)
                source.write_text(json.dumps(metadata))
                path.write_text("unexpected disk content")
                with self.assertRaisesRegex(RuntimeError, "owned_fixture"):
                    session.adopt_document_fixture(source)

    def test_only_same_new_process_with_no_unknown_or_unsaved_window_can_stop(self):
        lease = {"stamp": "started-here", "windows": {42: "marker"}}
        own = [{"window_id": 42, "title": "Jev-Test-marker"}]
        self.assertTrue(realapps.owned_process_can_stop(lease, [], "started-here", set()))
        self.assertTrue(realapps.owned_process_can_stop(lease, own, "started-here", {42}))
        for windows, stamp, saved in [
            (own, "changed-process", {42}), (own, "started-here", set()),
            (own + [{"window_id": 43, "title": "Other"}], "started-here", {42}),
            ([{"window_id": 42, "title": "Changed"}], "started-here", {42}),
        ]:
            self.assertFalse(realapps.owned_process_can_stop(lease, windows, stamp, saved))

    def test_native_cleanup_failure_never_starts_a_model_cleanup_task(self):
        with tempfile.TemporaryDirectory() as directory:
            session = realapps.Session(Path(directory), HERE / "unused.json")
            session.windows = lambda **_: [{"window_id": 42, "title": "Jev-Test-marker"}]
            session.owned_documents = [({"pid": 7, "window_id": 42}, "marker")]
            session.owned_document_content = {42: {
                "path": str(Path(directory) / "owned.txt"), "known_bodies": ["known"],
            }}
            with patch.object(session, "call", side_effect=RuntimeError("background_unavailable")), \
                 patch.object(session, "drive") as drive, patch.object(realapps.subprocess, "run") as run:
                run.return_value.stdout = ""
                run.return_value.returncode = 1
                session.__exit__()
            drive.assert_not_called()
            self.assertEqual(session.metadata["owned_document_windows_remaining"], [42])
            self.assertFalse(session.metadata["resources_clean"])

    def test_changed_disk_content_cannot_be_overwritten_by_cleanup_save(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "owned.txt"
            path.write_text("unexpected disk content")
            session = realapps.Session(Path(directory), HERE / "unused.json")
            session.windows = lambda **_: [{"window_id": 42, "title": "Jev-Test-marker"}]
            session.owned_documents = [({"pid": 7, "window_id": 42}, "marker")]
            session.owned_document_content = {42: {"path": str(path), "known_bodies": ["known"]}}
            with patch.object(session, "call", return_value=self.state()) as call, \
                 patch.object(session, "native_window_state", return_value=self.native(path), create=True), \
                 patch.object(realapps, "wait_for", side_effect=RuntimeError("timeout")), \
                 patch.object(realapps.subprocess, "run") as run:
                run.return_value.stdout = ""
                run.return_value.returncode = 1
                session.__exit__()
            self.assertEqual([args.args[0] for args in call.call_args_list], ["get_window_state"])
            self.assertEqual(path.read_text(), "unexpected disk content")
            self.assertEqual(session.metadata["document_cleanup_errors"][0]["code"],
                             "owned_document_disk_content_unverified")

    def test_command_exit_rejects_unclean_resources_or_failed_rows(self):
        for metadata, expected in [
            ({"resources_clean": False, "rows": []}, 1),
            ({"resources_clean": True, "rows": [{"strict_success": False}]}, 1),
            ({"resources_clean": True, "rows": [{"strict_success": True}]}, 0),
        ]:
            with tempfile.TemporaryDirectory() as directory, \
                 patch.object(realapps, "HERE", Path(directory)), \
                 patch.object(realapps.sys, "argv", ["realapps", "preflight"]), \
                 patch.object(realapps, "Session") as factory, \
                 patch("builtins.print"):
                session = factory.return_value.__enter__.return_value
                session.metadata = dict(metadata)
                session.tools = {}
                session.local.call.return_value = {"content": [{"type": "text", "text": "guide"}]}
                result = realapps.main()
            self.assertEqual(result, expected)


if __name__ == "__main__":
    unittest.main()
