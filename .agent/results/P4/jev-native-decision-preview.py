import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("decision_preview_shared", HERE / "jev-native-choice-capture.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)
QUALIFICATION = SHARED.load("decision_preview_qualification", "jev-vision-qualification.py")
REAL = QUALIFICATION.real


def case_window(prior):
    rows = prior.get("rows", [])
    seed = prior.get("calculator_seed", {})
    observations = seed.get("observations", [])
    scopes = {(row.get("pid"), row.get("window_id")) for row in observations}
    if (prior.get("resources_clean") is not True or len(rows) != 1
            or rows[0].get("case") != "calculator.add" or seed.get("verified") is not True
            or not observations or len(scopes) != 1):
        raise RuntimeError("readonly_preview_case_unverified")
    pid, window_id = next(iter(scopes))
    if (type(pid) is not int or pid <= 0 or type(window_id) is not int or window_id <= 0
            or rows[0].get("requested_window_id") != window_id):
        raise RuntimeError("readonly_preview_case_unverified")
    return dict(pid=pid, window_id=window_id)


def verify_scope(session, window):
    apps = [row for row in session.call("list_apps", {}).get("apps", [])
            if row.get("bundle_id", "").lower() == "com.apple.calculator"]
    valid = len(apps) == 1 and apps[0].get("pid") == window["pid"]
    windows = session.windows(pid=window["pid"]) if valid else []
    if not valid or sum(row.get("window_id") == window["window_id"] for row in windows) != 1:
        session.metadata["scope_failure"] = dict(expected=window, apps=apps, windows=windows)
        raise RuntimeError("readonly_preview_scope_changed")


def suggest(session, window, goal, deny):
    session.metadata.update(qualification=False, preview_requests=0, input_actuations=0)
    verify_scope(session, window)
    stamp = REAL.process_stamp(window["pid"])
    if not stamp or not stamp.endswith("/Calculator.app/Contents/MacOS/Calculator"):
        raise RuntimeError("readonly_preview_process_unverified")
    actor = session.start_actor()
    session.metadata["preview_actor_pid"] = actor.proc.pid
    tools = actor.call("tools/list", timeout=5).get("tools", [])
    offered = [row for row in tools if row.get("name") == "suggest_action"]
    if (len(offered) != 1 or not {"goal", "app", "window_id"}.issubset(
            offered[0].get("inputSchema", {}).get("properties", {}))):
        raise RuntimeError("readonly_preview_tool_unavailable")
    arguments = dict(goal=goal, app="com.apple.calculator", window_id=window["window_id"], deny=deny)
    session.metadata["preview_arguments"] = arguments
    session.metadata["preview_requests"] = 1
    started = time.perf_counter()
    preview_error = None
    try:
        result = actor.call("tools/call", dict(name="suggest_action", arguments=arguments), timeout=30)
        session.metadata["preview_result"] = result
        return result
    except Exception as error:
        preview_error = error
        session.metadata["preview_error_type"] = type(error).__name__
        raise
    finally:
        session.metadata["preview_wall_ms"] = (time.perf_counter() - started) * 1000
        phase = "scope"
        try:
            verify_scope(session, window)
            phase = "process"
            if REAL.process_stamp(window["pid"]) != stamp:
                raise RuntimeError("readonly_preview_process_changed")
            phase = "readback"
            state = session.call("get_window_state", dict(
                window, include_screenshot=False, tree_format="both", max_elements=2000))
            session.metadata["preview_readback"] = state
            if any(state.get(key) != value for key, value in window.items()):
                raise RuntimeError("readonly_preview_readback_scope_changed")
        except Exception as error:
            codes = {"readonly_preview_scope_changed", "readonly_preview_process_changed",
                     "readonly_preview_readback_scope_changed"}
            session.metadata["post_preview_error"] = dict(
                phase=phase, error_type=type(error).__name__,
                code=str(error) if str(error) in codes else "readonly_postcheck_failed")
            if preview_error is None:
                raise


def collect_logs(session, out):
    pid = session.metadata.get("preview_actor_pid")
    if pid is None:
        return
    try:
        result = subprocess.run([
            "/usr/bin/log", "show", "--last", "5m", "--style", "ndjson",
            "--predicate", f'processID == {pid} AND subsystem == "com.chriswozniczek.jevvoice"',
        ], capture_output=True, text=True, timeout=20)
        for name, content in (("events.ndjson", result.stdout), ("events.stderr", result.stderr)):
            with os.fdopen(os.open(out / name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                                   0o600), "w") as stream:
                stream.write(content)
        session.metadata["trace_collection"] = dict(
            actor_pid=pid, return_code=result.returncode, complete=result.returncode == 0,
            sha256=REAL.digest(out / "events.ndjson"))
    except Exception as error:
        session.metadata["trace_collection"] = dict(
            actor_pid=pid, complete=False, error_type=type(error).__name__)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--case-receipt", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("approved read-only signed suggestion required")
    prior = json.loads(args.case_receipt.read_text())
    window = case_window(prior)
    goal = prior["rows"][0].get("goal")
    if goal != "Calculate 3 plus 4 and show the result.":
        raise RuntimeError("readonly_preview_goal_unverified")
    subject = json.loads(args.receipt.read_text())["candidates"]["after"]
    if subject["driver_sha256"] != prior.get("driver_sha256"):
        raise RuntimeError("readonly_preview_driver_changed")
    out = SHARED.private_output(args.out)
    started = time.perf_counter()
    session = None
    status = "error"
    try:
        with REAL.execution_bundle(subject) as app:
            preparation = QUALIFICATION.check_driver_artifact(subject, app)
            with REAL.Session(out, args.receipt, variant="after", prepared_app=app) as session:
                session.metadata.update(
                    qualification=False, purpose="one public signed read-only suggestion, not a goal",
                    input_actuations=0, preparation=preparation,
                    requested_window=window, case_receipt_sha256=REAL.digest(args.case_receipt),
                    diagnostic_source_sha256=REAL.digest(__file__), api_request_count=None)
                try:
                    suggest(session, window, goal, REAL.qualification_denials({}))
                    status = "preview_returned"
                finally:
                    collect_logs(session, out)
    finally:
        metadata = session.metadata if session is not None else {}
        REAL.write_json(out / "preview-receipt.json", dict(
            qualification=False, status=status, diagnostic_wall_ms=(time.perf_counter() - started) * 1000,
            resources_clean=metadata.get("resources_clean", False),
            preview_requests=metadata.get("preview_requests", 0),
            drive_requests=metadata.get("drive_requests", 0),
            input_actuations=metadata.get("input_actuations", 0),
            model_requests="not instrumented; infer attempts may be counted from trace",
            metadata=metadata))


if __name__ == "__main__":
    main()
