import argparse
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("everyday_capture_shared", HERE / "jev-native-choice-capture.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def refinement_input_invariant(normal, strict):
    def canonical(value):
        return json.dumps(value, sort_keys=True, ensure_ascii=True, allow_nan=False)

    def semantic(value):
        value = copy.deepcopy(value)
        fact = value.get("questions", {}).get("goal_fact")
        if fact is not None:
            if not isinstance(fact, dict) or not isinstance(fact.get("criteria"), dict):
                raise RuntimeError("invalid goal fact question")
            for identity, text in fact["criteria"].items():
                if identity == "none":
                    continue
                try:
                    decoded = json.loads(text)
                except (TypeError, ValueError) as error:
                    raise RuntimeError("invalid goal fact encoding") from error
                if not isinstance(decoded, dict):
                    raise RuntimeError("invalid goal fact object")
                fact["criteria"][identity] = decoded
        return canonical(value)

    identical = canonical(normal) == canonical(strict)
    if semantic(normal) != semantic(strict):
        raise RuntimeError("diagnostic floor changed semantic model input")
    return dict(identical_primary_model_input=identical,
                semantically_equal_primary_input=True,
                goal_fact_encoding_nondeterminism=not identical,
                wire_equivalence_claimed=False)


def capture_test(session, window, directory, environment, real):
    with (directory / "tests.log").open("w") as log:
        process = subprocess.Popen(["swift", "test", "--skip-build", "--filter",
            "JevNativeChoiceDiagnosticTests.testVerifiedCalculatorReadOnlyDecisionCapture"],
            cwd=SHARED.ROOT, env=environment, stdout=log, stderr=log)
        sequence = 0
        deadline = time.monotonic() + 120
        nonce = json.loads((directory / "input.json").read_text())["capture_bridge_nonce"]
        try:
            while process.poll() is None:
                if time.monotonic() >= deadline:
                    raise TimeoutError("read-only native preview deadline")
                try:
                    command = json.loads((directory / "capture-command.json").read_text())
                except (FileNotFoundError, json.JSONDecodeError):
                    command = None
                if command and command.get("sequence") != sequence:
                    if (set(command) != {"nonce", "sequence"} or command.get("nonce") != nonce
                            or type(command.get("sequence")) is not int
                            or command["sequence"] != sequence + 1 or sequence >= 2):
                        raise RuntimeError("read-only capture command invalid")
                    raw = session.raw_call("get_window_state", dict(window,
                        include_screenshot=True, include_accessibility_tree=True,
                        tree_format="both", max_elements=600, max_depth=20,
                        max_image_dimension=1568, timeout_ms=5000))
                    body = real.payload(raw)
                    if body.get("pid") != window["pid"] or body.get("window_id") != window["window_id"]:
                        raise RuntimeError("read-only capture changed native window")
                    sequence += 1
                    reply = dict(structuredContent=body, content=raw.get("content", []))
                    real.write_json(directory / "capture-reply.json",
                        dict(nonce=nonce, sequence=sequence, result=reply))
                time.sleep(0.02)
            session.metadata["readonly_live_captures"] = sequence
            if process.returncode:
                raise RuntimeError("read-only preview failed; inspect tests.log")
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--case-receipt", type=Path, required=True)
    parser.add_argument("--reviewed-source-delta", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("approved controlled real-app scope required")
    qualification = SHARED.load("everyday_capture_qualification", "jev-vision-qualification.py")
    everyday = SHARED.load("everyday_capture_helpers", "jev-everyday-apps.py")
    real = qualification.real
    approved = qualification.load_reviewed_source_delta(args.reviewed_source_delta)
    subject = json.loads(args.receipt.read_text())["candidates"]["after"]
    prior = json.loads(args.case_receipt.read_text())
    rows = prior.get("rows", [])
    if (prior.get("binary_sha256") != subject["binary_sha256"]
            or prior.get("driver_sha256") != subject["driver_sha256"]
            or prior.get("resources_clean") is not True or len(rows) != 1):
        raise RuntimeError("signed pilot identity unverified")
    case = rows[0]
    expected = case.get("actual_state", {}).get("expected")
    observed = case.get("actual_state", {}).get("display")
    goals = {"5": "Calculate 2 plus 3 and show the result.",
             "7": "Calculate 3 plus 4 and show the result."}
    if (case.get("case") != "calculator.add" or case.get("verified") is not (observed == expected)
            or case.get("status") != "blocked" or case.get("false_done") is not False
            or expected not in goals or case.get("goal") != goals[expected]
            or observed not in goals):
        raise RuntimeError("scoped Calculator refusal with known unchanged display required")
    goal_expected = expected
    expected = observed
    args.out = SHARED.private_output(args.out)
    metadata = {
        "qualification": False, "actuations": 0, "status": "error",
        "purpose": "read-only Calculator completion/targeting diagnosis",
        "goal_expected_result": goal_expected,
        "unchanged_native_display": expected,
        "receipt_sha256": real.digest(args.receipt),
        "case_receipt_sha256": real.digest(args.case_receipt),
        "harness_sha256": real.digest(__file__),
    }
    session = None
    try:
        with real.execution_bundle(subject) as app:
            metadata["preparation"] = qualification.check_driver_artifact(subject, app)
            session = real.Session(args.out, args.receipt, variant="after",
                                   approved_source_delta=approved, prepared_app=app)
            with session:
                apps = [row for row in session.call("list_apps", {}).get("apps", [])
                        if row.get("bundle_id", "").lower() == "com.apple.calculator"]
                if len(apps) != 1:
                    raise RuntimeError("Calculator process identity unverified")
                pid = apps[0]["pid"]
                windows = [row for row in session.windows(pid=pid)
                           if row.get("window_id") == case["requested_window_id"]]
                if len(windows) != 1:
                    raise RuntimeError("original Calculator window unavailable")
                window = {"pid": pid, "window_id": case["requested_window_id"]}
                raw = session.raw_call("get_window_state", dict(window,
                    include_screenshot=True, include_accessibility_tree=True,
                    tree_format="both", max_elements=600, max_depth=20,
                    max_image_dimension=1568, timeout_ms=5000))
                metadata["diagnostic_observation_timeout_ms"] = 5000
                state = real.payload(raw)
                scoped = state.get("pid") == pid and state.get("window_id") == window["window_id"]
                metadata["readback"] = dict(
                    requested=window, pid=state.get("pid"), window_id=state.get("window_id"),
                    scoped=scoped, truncated=state.get("truncated"),
                    tree_available=bool(state.get("tree_markdown")),
                    element_count=len(state.get("elements", [])),
                    display=everyday.calculator_display(state) if scoped else None,
                    expected=expected)
                if scoped:
                    real.write_json(args.out / "calculator-readback.json", state)
                if not scoped or metadata["readback"]["display"] != expected:
                    raise RuntimeError("Calculator display or scope changed")
                images = [item for item in raw.get("content", []) if item.get("type") == "image"]
                if len(images) != 1 or images[0].get("mimeType") != "image/png":
                    raise RuntimeError("scoped Calculator image unavailable")
                real.write_json(args.out / "input.json", {
                    "qualification": False, "window": window, "expected_display": expected,
                    "expected_goal_result": goal_expected,
                    "capture_existing_refinement": goal_expected != expected,
                    "task": {"goal": case["goal"]}, "driver_reply": SHARED.scoped_elements(state),
                    "image_content": images, "session": session.local_session,
                    "deny": real.qualification_denials({}), "daemon_socket": str(session.sock),
                    "tools": {"tools": list(session.tools.values())},
                    "apps": {"structuredContent": {"apps": apps}},
                    "windows": {"structuredContent": {"windows": windows}},
                    "capture_bridge_nonce": str(uuid.uuid4()),
                })
                environment = dict(os.environ)
                environment.pop("JEV_NATIVE_CHOICE_INPUT", None)
                environment["JEV_CALCULATOR_CHOICE_INPUT"] = str(args.out / "input.json")
                environment["JEV_NATIVE_CHOICE_API_KEY"] = real.require_api_key()
                capture_test(session, window, args.out, environment, real)
                result = json.loads((args.out / "diagnostic.json").read_text())
                if goal_expected != expected:
                    refinement = json.loads((args.out / "refinement-diagnostic.json").read_text())
                    metadata["existing_refinement"] = refinement
                    if (refinement.get("qualification") is not False
                            or refinement.get("actuations") != 0
                            or refinement.get("normal_choice_returned") is not True):
                        raise RuntimeError("production refinement diagnostic scope failed")
                    if refinement["forced"]:
                        start = refinement["forced_primary_index"]
                        normal = json.loads((args.out / "request-0.json").read_text())
                        strict = json.loads((args.out / f"request-{start}.json").read_text())
                        if refinement["diagnostic_floor"] != 1:
                            raise RuntimeError("diagnostic floor changed model inputs")
                        refinement.update(refinement_input_invariant(normal, strict))
                fresh = everyday.state_for(session, window)
                if (everyday.calculator_display(fresh) != expected
                        or result.get("qualification") is not False or result.get("actuations") != 0
                        or session.metadata["drive_requests"] != 0):
                    raise RuntimeError("read-only capture invariants failed")
                metadata.update(status="captured", result=result)
            metadata["resources_clean"] = session.metadata["resources_clean"]
            metadata["drive_requests"] = session.metadata["drive_requests"]
            if not metadata["resources_clean"]:
                raise RuntimeError("diagnostic runtime not cleaned")
    finally:
        if session is not None:
            metadata["resources_clean"] = session.metadata["resources_clean"]
            metadata["drive_requests"] = session.metadata["drive_requests"]
        real.write_json(args.out / "capture-receipt.json", metadata)


if __name__ == "__main__":
    main()
