import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import time


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("calculator_readonly_shared", HERE / "jev-native-choice-capture.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def observe(session, window, timeout_ms=None):
    arguments = dict(window, include_screenshot=False, tree_format="both", max_elements=2000)
    if timeout_ms is not None:
        arguments["timeout_ms"] = timeout_ms
    state = session.call("get_window_state", arguments)
    if any(state.get(key) != value for key, value in window.items()):
        session.metadata["diagnostic_scope_mismatch"] = state
        raise RuntimeError("readonly_snapshot_scope_changed")
    return state


def main():
    parser = argparse.ArgumentParser()
    for name in ("receipt", "case-receipt", "reviewed-source-delta", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--observation-timeout-ms", type=int, choices=(1000, 5000))
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("controlled read-only approval required")
    qualification = SHARED.load("calculator_readonly_qualification", "jev-vision-qualification.py")
    real = qualification.real
    subject = json.loads(args.receipt.read_text())["candidates"]["after"]
    prior = json.loads(args.case_receipt.read_text())
    if (prior.get("binary_sha256") != subject["binary_sha256"]
            or prior.get("driver_sha256") != subject["driver_sha256"]
            or prior.get("resources_clean") is not True or len(prior.get("rows", [])) != 1
            or prior["rows"][0].get("case") != "calculator.add"):
        raise RuntimeError("readonly_subject_unverified")
    output = SHARED.private_output(args.out)
    approved = qualification.load_reviewed_source_delta(args.reviewed_source_delta)
    with real.execution_bundle(subject) as app:
        preparation = qualification.check_driver_artifact(subject, app)
        with real.Session(output, args.receipt, variant="after",
                          approved_source_delta=approved, prepared_app=app, driver_only=True) as session:
            session.metadata.update(qualification=False, input_actuations=0, model_requests=0,
                                    purpose="read-only Calculator scope diagnosis", preparation=preparation,
                                    diagnostic_source_sha256=real.digest(__file__),
                                    diagnostic_observation_timeout_ms=args.observation_timeout_ms)
            apps = [row for row in session.call("list_apps", {}).get("apps", [])
                    if row.get("bundle_id", "").lower() == "com.apple.calculator"]
            if len(apps) != 1:
                raise RuntimeError("readonly_calculator_process_unverified")
            window = dict(pid=apps[0]["pid"], window_id=prior["rows"][0]["requested_window_id"])
            if not any(row["window_id"] == window["window_id"] for row in session.windows(pid=window["pid"])):
                raise RuntimeError("readonly_original_window_unavailable")
            sampler = None
            sample_path = output / "driver-sample.txt"
            if args.observation_timeout_ms is not None:
                sampler = subprocess.Popen(["/usr/bin/sample", str(session.daemon.pid), "5", "1",
                                            "-file", str(sample_path)],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            started = time.perf_counter()
            try:
                state = observe(session, window, args.observation_timeout_ms)
            finally:
                session.metadata["diagnostic_observation_wall_ms"] = (time.perf_counter() - started) * 1000
                if sampler is not None:
                    try:
                        stdout, stderr = sampler.communicate(timeout=8)
                    except subprocess.TimeoutExpired:
                        sampler.kill()
                        stdout, stderr = sampler.communicate(timeout=3)
                    session.metadata["driver_sample"] = dict(
                        pid=session.daemon.pid, return_code=sampler.returncode,
                        stdout=stdout, stderr=stderr,
                        sha256=real.digest(sample_path) if sample_path.is_file() else None)
            real.write_json(output / "driver-readback.json", state)
            session.metadata["requested_window"] = window
            try:
                native = session.native_window_state(window, state.get("window_title", ""))
                real.write_json(output / "native-readback.json", native)
                session.metadata["native_scope_proven"] = real.native_window_proven(
                    native, window, state.get("window_title", ""))
            except RuntimeError as error:
                session.metadata["native_error"] = str(error)
            assert session.metadata["drive_requests"] == 0


if __name__ == "__main__":
    main()
