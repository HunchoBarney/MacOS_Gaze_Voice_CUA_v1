"""Evidence-boundary regressions; no desktop, audio, network or real receipts."""
import copy
from contextlib import redirect_stdout
import io
import importlib.util
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("verify_p3", ROOT / "scripts/verify-p3.py")
v = importlib.util.module_from_spec(spec)
spec.loader.exec_module(v)


def physical():
    rows = []
    for case in range(1, 5):
        for rep in range(1, 6):
            rows.append(dict(
                case_id=f"live-c{case}", repetition=rep, source="physical",
                artifact_sha256="build", status="ok", wrong_critical_actions=0,
                turn_id=f"{case}-{rep}", generation=rep, dispatch_count=1, effect_count=1,
                marks=dict(fn_up=1, dispatch=1.1, effect=1.2),
                verification=dict(kind="frontmost_pid", passed=True,
                                  app_id="com.apple.calculator", pid=2, baseline_frontmost_pid=1)))
    for case in range(1, 5):
        rows.append(dict(case_id=f"live-n{case}", repetition=1, source="physical",
                         artifact_sha256="build", status="ok", wrong_critical_actions=0,
                         turn_id=f"n{case}", generation=1, dispatch_count=0,
                         command_effect_count=0, marks=dict(fn_up=1),
                         verification=dict(kind="no_dispatch", passed=True)))
    rows[-2].update(actual_route="dictation", transcript_sha256="literal")
    rows[-2]["verification"].update(
        kind="owned_literal_delivery", delivered_sha256="literal", fixture_run_id="run")
    for row in rows:
        row.update(phase="scored", attempt=1, run_id="run")
    cold = dict(rows[0], phase="cold", turn_id="cold")
    warmups = [dict(rows[0], phase="warmup", repetition=i, turn_id=f"warm{i}") for i in [1, 2]]
    return dict(schema_version=1, source="physical", human_confirmed=True,
                remote_live_authorized=False, artifact_sha256="build", run_id="run",
                executed_artifact_sha256="installed", install_receipt_sha256="receipt",
                rows=rows, cold=cold, warmups=warmups)


class EvidenceBoundaryTests(unittest.TestCase):
    def test_acceptance_digest_ignores_only_criterion_verdict_metadata(self):
        path = ROOT / ".agent/acceptance/P3.json"
        contract = json.loads(path.read_text())
        with patch.object(v, "read", side_effect=lambda _: copy.deepcopy(contract)):
            baseline = v.review_file_digest(path)
            for row in contract["criteria"]:
                row.update(passes=True, evidence="reviewed real evidence")
            self.assertEqual(v.review_file_digest(path), baseline)
            for field in ("phase", "new_contract_field"):
                modified = copy.deepcopy(contract)
                modified[field] = "changed"
                with patch.object(v, "read", return_value=modified):
                    self.assertNotEqual(v.review_file_digest(path), baseline)
            for field in ("id", "behavior", "check", "expected", "new_contract_field"):
                modified = copy.deepcopy(contract)
                modified["criteria"][0][field] = "changed"
                with patch.object(v, "read", return_value=modified):
                    self.assertNotEqual(v.review_file_digest(path), baseline)
            modified = copy.deepcopy(contract)
            modified["passes"] = True
            with patch.object(v, "read", return_value=modified):
                self.assertNotEqual(v.review_file_digest(path), baseline)

    def test_review_remains_valid_after_acceptance_verdict_but_not_contract_or_code_change(self):
        acceptance = ROOT / ".agent/acceptance/P3.json"
        contract = json.loads(acceptance.read_text())
        build = dict(artifact_sha256="build", source_hashes={"Sources/a.swift": "source"})
        review = dict(code_delta_pass=True, **build, acceptance_digest_kind="p3-contract-v1")
        def read(path):
            return copy.deepcopy(contract if path == acceptance else review)
        with patch.object(v, "read", side_effect=read), patch.object(v, "sha", return_value="code"):
            review["reviewed_files"] = {
                "scripts/verify-p3.py": "code",
                ".agent/acceptance/P3.json": v.review_file_digest(acceptance),
            }
            v.review_matches(build)
            contract["criteria"][0].update(passes=True, evidence="real evidence")
            v.review_matches(build)
            original = contract["criteria"][0]["check"]
            contract["criteria"][0]["check"] = "weakened"
            with self.assertRaises(AssertionError):
                v.review_matches(build)
            contract["criteria"][0]["check"] = original
            with patch.object(v, "sha", return_value="changed code"), self.assertRaises(AssertionError):
                v.review_matches(build)
            review["acceptance_digest_kind"] = "unversioned"
            with self.assertRaises(AssertionError):
                v.review_matches(build)

    def test_other_reviewed_files_keep_raw_byte_hashes(self):
        path = ROOT / ".agent/CONTRACTS.md"
        self.assertEqual(v.review_file_digest(path), v.sha(path))

    def test_malformed_acceptance_is_a_controlled_failure_not_a_digest_fallback(self):
        path = ROOT / ".agent/acceptance/P3.json"
        for contract in [None, {}, {"criteria": "not an array"}, {"criteria": [1]}]:
            with self.subTest(contract=contract), patch.object(v, "read", return_value=contract):
                with self.assertRaises(AssertionError):
                    v.review_file_digest(path)

    def remote_protocol(self):
        specs = [("safe-miss", "safe", "q1", "r1", "safe-turn", "g1", 1),
                 ("outcome-only", "outcome", "q2", "r2", "safe-turn", "g1", 0),
                 ("cancel", "cancel", "q3", "r3", "cancel-turn", "g1", 0),
                 ("stale-response", "new", "q5", "r5", "new-turn", "g2", 1)]
        rows = [dict(case_id=c, request_id=q, server_response_id=r, turn_id=t,
                     connection_generation=g, dispatch_count=n, duplicate_dispatches=0,
                     wrong_critical_actions=0, verification_passed=True)
                for c, stage, q, r, t, g, n in specs]
        rows[1].update(owning_turn_id=None, source_turn_id="safe-turn", tools_disabled=True)
        rows[2]["cancellation_kind"] = "owning_connection_closed"
        rows[3].update(old_request_id="q4", old_connection_generation="g-old",
                       old_server_response_id="r4", old_call_id="old-call",
                       replayed_frame_sha256="a" * 64, local_replay_count=2,
                       network_replay=False, old_dispatch_count=0)
        sent = [dict(kind="response.create", case_id=c, stage=s, request_id=q,
                     tools_disabled=c == "outcome-only", text_only=True,
                     wire_id="new-wire" if c == "stale-response" else "shared-wire")
                for c, s, q, *_ in specs]
        sent.append(dict(kind="response.create", case_id="stale-response", stage="old",
                         request_id="q4", tools_disabled=False, text_only=True))
        sent.extend([dict(kind="conversation.item.create", case_id=c, stage=s,
                          function_output_call_id="call-" + c)
                     for c, s in [("safe-miss", "safe"), ("stale-response", "new")]])
        sent.append(dict(direction="inbound", kind="response.function_call_arguments.done",
                         case_id="stale-response", stage="old", server_response_id="r4",
                         server_call_id="old-call", raw_frame_sha256="a" * 64))
        sent.append(dict(kind="transport.closed", wire_id="shared-wire",
                         socket_cancel_requested=True, session_invalidated=True))
        replay = dict(kind="response.function_call_arguments.done", response_id="r4",
                      connection_generation="g-old", call_ids=["old-call"])
        ingress = [replay, dict(replay)]
        for _, _, _, response, _, generation, _ in specs:
            ingress.append(dict(kind="response.created", response_id=response, connection_generation=generation))
            if response != "r3":
                ingress.append(dict(kind="response.done", response_id=response, connection_generation=generation))
        ingress.append(dict(kind="response.created", response_id="r4", connection_generation="g-old"))
        return dict(rows=rows, outbound=sent, ingress=dict(overflow=False, frames=ingress))

    def normal_routing(self):
        rows = []
        for command, target, semantic in v.NORMAL_ROUTING_CASES:
            rows.append(dict(
                command=command, observed_bundle_id=target, passed=True,
                normal_route="semantic" if semantic else "local", semantic_focus=semantic,
                scripted_confirmation=False, wrong_proposal=False, false_done=False,
                observed_window_id=7, submit_to_visible_effect_ms=100,
                work_count=1, works=[dict(active=False, outcome="done", application=target, capture_id="turn")],
                trace=[dict(stage="workCreated", turn="turn")] if semantic
                    else [dict(stage="admissionLocal", turn="turn")]))
        return dict(schema_version=1, report_kind="normal_controller_typed_routing",
                    status="passed", normal_typed_routing_gate="passed", artifact_sha256="signed",
                    corpus_sha256=v.normal_routing_corpus_sha(), local_acoustic_gate="not_exercised",
                    phase_acceptance=False, physical_input=False, human_confirmed=False, rows=rows)

    def test_separate_normal_typed_population_is_not_physical_acceptance(self):
        data = self.normal_routing()
        v.validate_normal_routing(data, "signed")
        with self.assertRaises(AssertionError):
            self.live(data, attempts=[])
        diagnostic = dict(data, report_kind="local_voice_trial_diagnostic", source="physical", human_confirmed=True)
        with self.assertRaises(AssertionError):
            self.live(diagnostic, attempts=[])

    def test_normal_report_rejects_missing_duplicate_wrong_lane_or_failed_evidence(self):
        mutations = [
            lambda d: d["rows"].pop(),
            lambda d: d["rows"].append(d["rows"][0]),
            lambda d: d["rows"].__setitem__(4, d["rows"][0]),
            lambda d: d["rows"][4].update(normal_route="local"),
            lambda d: d["rows"][4].update(semantic_focus=False),
            lambda d: d["rows"][0].update(scripted_confirmation=True),
            lambda d: d["rows"][0]["works"][0].update(active=True),
            lambda d: d.update(local_acoustic_gate="passed"),
            lambda d: d.update(physical_input=True),
            lambda d: d.update(artifact_sha256="stale"),
        ]
        for mutate in mutations:
            data = self.normal_routing()
            mutate(data)
            with self.assertRaises(AssertionError):
                v.validate_normal_routing(data, "signed")

    def test_normal_success_cannot_rescue_a_failed_local_physical_row(self):
        data = physical()
        data["normal_typed_routing_gate"] = "passed"
        data["rows"][0]["status"] = "failed"
        with self.assertRaises(AssertionError):
            self.live(data)

    def test_complete_named_integration_population_includes_natural_request(self):
        self.assertEqual(len(v.INTEGRATION_CASES), 12)
        self.assertIn(
            "-[VoiceOneBrainTests testNaturalAppRequestUsesCanonicalSurfaceAndCapturedIdentityOnce]",
            v.INTEGRATION_CASES)
        self.assertIn("-[VoiceOneBrainTests testSemanticNoMatchContinuesOriginalRemoteOwnerOnce]",
                      v.INTEGRATION_CASES)
        v.verify_integration_population(dict(cases=[
            dict(name=name, failures=0) for name in sorted(v.INTEGRATION_CASES)]))

    def test_missing_duplicate_substitute_or_failed_integration_case_is_rejected(self):
        rows = [dict(name=name, failures=0) for name in sorted(v.INTEGRATION_CASES)]
        alternatives = [rows[:-1], rows + [rows[0]],
                        [dict(name="unexpected", failures=0), *rows[1:]],
                        [dict(rows[0], failures=1), *rows[1:]]]
        for candidate in alternatives:
            with self.assertRaises(AssertionError):
                v.verify_integration_population(dict(cases=candidate))

    def live(self, data, attempts=None):
        if attempts is None:
            attempts = [data["cold"], *data["warmups"], *data["rows"]]
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(v, "read", return_value=data), \
             patch.object(v, "read_attempts", return_value=attempts), \
             patch.object(v, "current_build", return_value={"artifact_sha256": "build"}), \
             patch.object(v, "installed_build", return_value={"installed_artifact_sha256": "installed"}), \
             patch.object(v, "sha", return_value="receipt"):
            with redirect_stdout(io.StringIO()):
                v.validate_legacy_live_protocol(SimpleNamespace(out=None))

    def test_normal_live_gate_rejects_local_only_physical_receipt(self):
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(v, "read", return_value=physical()), \
             self.assertRaises(AssertionError):
            v.live(SimpleNamespace(out=None))

    def test_physical_does_not_require_remote_authorization(self):
        self.live(physical())

    def test_changed_signed_executable_cannot_claim_physical(self):
        data = physical()
        data["executed_artifact_sha256"] = "old-package"
        with self.assertRaises(AssertionError):
            self.live(data)

    def test_changed_install_receipt_cannot_claim_physical(self):
        data = physical()
        data["install_receipt_sha256"] = "old-receipt"
        with self.assertRaises(AssertionError):
            self.live(data)

    def test_automated_data_cannot_claim_physical(self):
        data = physical()
        data["source"] = "automated-recording-and-scripted-hold"
        with self.assertRaises(AssertionError):
            self.live(data)

    def test_source_changes_invalidate_build(self):
        build = {"source_hashes": {"Sources/a.swift": "before"}, "artifact_sha256": "build"}
        with patch.object(v, "read", return_value=build), \
             patch.object(v, "source_hashes", return_value={"Sources/a.swift": "after"}):
            with self.assertRaises(AssertionError):
                v.current_build()

    def test_authorization_alone_is_not_server_evidence(self):
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(v, "read", return_value={"remote_live_authorized": True}), \
             patch.object(v, "current_build", return_value={"artifact_sha256": "build"}):
            with self.assertRaises((KeyError, AssertionError)):
                v.remote(SimpleNamespace(out=None))

    def test_remote_without_authorization_remains_blocked(self):
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(v, "read", return_value={"remote_live_authorized": False}):
            with self.assertRaises(v.Blocked):
                v.remote(SimpleNamespace(out=None))

    def test_remote_execution_cannot_omit_signed_artifact_binding(self):
        with self.assertRaises(AssertionError):
            v.validate_remote_execution({}, {"source_hashes": {}})

    def test_remote_execution_requires_current_bytes_and_build_uuid(self):
        binary = Path.home() / "jarvis-local/p3-remote-final/Jev Voice.app/Contents/MacOS/JevVoice"
        data = dict(executed_executable=str(binary), executed_artifact_sha256="signed",
                    source_hashes={"Sources/a.swift": "source"}, executed_build_uuids=["ABC (arm64)"])
        build = dict(source_hashes=data["source_hashes"])
        with patch.object(Path, "is_file", return_value=True), \
             patch.object(v, "sha", return_value="signed"), \
             patch.object(v, "executable_uuid", return_value=[("ABC", "arm64")]), \
             patch.object(v.subprocess, "run"):
            v.validate_remote_execution(data, build)
            for field, value in [("executed_artifact_sha256", "wrong"),
                                 ("executed_build_uuids", ["wrong"]),
                                 ("source_hashes", {})]:
                broken = dict(data, **{field: value})
                with self.assertRaises(AssertionError):
                    v.validate_remote_execution(broken, build)

    def test_remote_protocol_requires_real_replay_and_measured_dispatch_counts(self):
        data = self.remote_protocol()
        v.validate_remote_protocol(data)
        for mutate in [
            lambda d: d["rows"][3].update(network_replay=True),
            lambda d: d["rows"][3].update(local_replay_count=1),
            lambda d: d["rows"][3].update(old_connection_generation="g2"),
            lambda d: d["rows"][1].update(owning_turn_id="invented"),
            lambda d: d["rows"][0].update(dispatch_count=0),
            lambda d: d["outbound"].append(dict(d["outbound"][0])),
            lambda d: d["ingress"]["frames"].pop(0),
            lambda d: d["ingress"]["frames"].pop(),
            lambda d: d["outbound"][-2].update(raw_frame_sha256="b" * 64),
            lambda d: d["outbound"].pop(),
            lambda d: d["outbound"][-1].update(wire_id="wrong-wire"),
        ]:
            broken = copy.deepcopy(data)
            mutate(broken)
            with self.assertRaises(AssertionError):
                v.validate_remote_protocol(broken)

    def test_latency_bars_are_not_replaced_by_safety_timeout(self):
        data = copy.deepcopy(physical())
        for row in data["rows"][:20]:
            row["marks"]["effect"] = 3
        with self.assertRaises(AssertionError):
            self.live(data)

    def test_failed_scored_trial_then_success_cannot_pass(self):
        data = physical()
        failed = dict(data["rows"][0], status="failed_capture_or_finalize")
        attempts = [data["cold"], *data["warmups"], failed, *data["rows"]]
        with self.assertRaises(AssertionError):
            self.live(data, attempts)

    def test_wrong_action_in_failed_warmup_cannot_pass(self):
        data = physical()
        unsafe = dict(data["warmups"][0], status="failed", wrong_critical_actions=1)
        attempts = [data["cold"], unsafe, *data["warmups"], *data["rows"]]
        with self.assertRaises(AssertionError):
            self.live(data, attempts)

    def test_cold_preparation_number_cannot_replace_cold_turn(self):
        data = physical()
        attempts = [*data["warmups"], *data["rows"]]
        with self.assertRaises(AssertionError):
            self.live(data, attempts)

    def test_changed_attempt_ledger_is_rejected(self):
        data = dict(run_id="run", attempts_file="live-attempts-run.jsonl", attempts_sha256="sealed")
        with patch.object(v, "sha", return_value="modified"):
            with self.assertRaises(AssertionError):
                v.read_attempts(data)

    def test_reviewed_contract_change_invalidates_review(self):
        build = dict(artifact_sha256="build", source_hashes={})
        review = dict(code_delta_pass=True, artifact_sha256="build", source_hashes={},
                      acceptance_digest_kind="p3-contract-v1",
                      reviewed_files={"scripts/verify-p3.py": "old", ".agent/acceptance/P3.json": "old"})
        with patch.object(v, "read", return_value=review), patch.object(v, "sha", return_value="changed"):
            with self.assertRaises(AssertionError):
                v.review_matches(build)

    def test_real_install_validation_checks_signature_and_uuid(self):
        build = dict(artifact_sha256="build", source_hashes={})
        receipt = dict(schema_version=1, bundle=str(Path.home() / "jarvis-local/Jev Voice.app"),
                       codesign_verified=True, source_artifact_sha256="build", source_hashes={},
                       installed_artifact_sha256="installed", review_receipt_sha256="review")
        def digest(path):
            return "review" if path.name == "review.json" else "installed"
        with patch.object(v, "read", return_value=receipt), \
             patch.object(v, "review_matches"), patch.object(v, "sha", side_effect=digest), \
             patch.object(v, "executable_uuid", return_value=[("same", "arm64")]) as uuid, \
             patch.object(v.subprocess, "run") as signature:
            self.assertEqual(v.installed_build(build), receipt)
            self.assertEqual(uuid.call_count, 2)
            self.assertIn("--strict", signature.call_args.args[0])
            self.assertIn("--deep", signature.call_args.args[0])
            uuid.side_effect = [[("old", "arm64")], [("new", "arm64")]]
            with self.assertRaises(AssertionError):
                v.installed_build(build)


if __name__ == "__main__":
    unittest.main()
