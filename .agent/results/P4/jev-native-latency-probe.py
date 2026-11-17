import argparse
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import statistics
import subprocess


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("latency_readonly", HERE / "jev-calculator-readonly.py")
READONLY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(READONLY)
SHARED = READONLY.SHARED
ORDER = (True, False, False, True, True, False)


def cursor(session, enabled=None):
    tool = "get_agent_cursor_state" if enabled is None else "set_agent_cursor_enabled"
    arguments = {"session": session.local_session}
    if enabled is not None:
        arguments["enabled"] = enabled
    reply = session.call(tool, arguments)
    session.metadata.setdefault("cursor_operations", []).append(dict(tool=tool, arguments=arguments, reply=reply))
    if (reply.get("session") != session.local_session or type(reply.get("enabled")) is not bool
            or (enabled is not None and reply["enabled"] is not enabled)):
        raise RuntimeError("diagnostic_cursor_scope_or_state")
    return reply


def motion(session, duration, real, expected):
    unchanged = {key: value for key, value in expected.items() if key != "glide_duration_ms"}
    def same_other_fields(value):
        return {key: item for key, item in value.items() if key != "glide_duration_ms"} == unchanged
    arguments = dict(session=session.local_session, glide_duration_ms=duration)
    reply = session.call("set_agent_cursor_motion", arguments)
    session.metadata.setdefault("motion_operations", []).append(dict(arguments=arguments, reply=reply))
    if (reply.get("session") != session.local_session or reply.get("motion", {}).get("glide_duration_ms") != duration
            or not same_other_fields(reply["motion"])):
        raise RuntimeError("diagnostic_motion_scope_or_value")
    def applied():
        state = cursor(session)
        if state["enabled"] is not True:
            raise RuntimeError("diagnostic_visible_cursor_disabled")
        value = state.get("motion", {})
        if value.get("glide_duration_ms") == duration:
            if not same_other_fields(value):
                raise RuntimeError("diagnostic_other_motion_fields_changed")
            return state
        return None
    return real.wait_for(applied, 3, "owned renderer motion readback")


def measure(session, window, output, everyday, real, isolate_post_action_wait=False, isolate_glide_duration=False):
    original = cursor(session) if not isolate_post_action_wait else None
    duration = original.get("motion", {}).get("glide_duration_ms") if isolate_glide_duration else None
    if isolate_glide_duration and (
            type(duration) not in (int, float) or not math.isfinite(duration)
            or original["enabled"] is not True):
        raise RuntimeError("diagnostic_original_motion_unavailable")
    session.metadata["original_cursor"] = original
    session.metadata["latency_trials"] = []
    total = 0
    try:
        if isolate_glide_duration:
            cursor(session, True)
            if cursor(session)["enabled"] is not True:
                raise RuntimeError("diagnostic_motion_cursor_enable_failed")
            session.metadata["cursor_visibility_proof"] = "public enable operation; renderer motion readback, not pixel capture"
        for index, enabled in enumerate(ORDER):
            wait = ("default" if enabled else "none") if isolate_post_action_wait else None
            selected_duration = duration if enabled else 120
            if isolate_glide_duration:
                motion(session, selected_duration, real, original["motion"])
            elif original is not None:
                cursor(session, enabled)
                state = cursor(session)
                if state["enabled"] is not enabled:
                    raise RuntimeError("diagnostic_cursor_condition")
            trial = dict(index=index, cursor_enabled=enabled if original is not None else None,
                         post_action_wait=wait, condition=str(enabled), qualification=False,
                         glide_duration_ms=selected_duration if isolate_glide_duration else None)
            if isolate_glide_duration:
                trial["cursor_enabled"] = True
            session.metadata["latency_trials"].append(trial)
            try:
                everyday.calculator_seed(session, window, observation_timeout_ms=5000, post_action_wait=wait)
            finally:
                seed = copy.deepcopy(session.metadata.get("calculator_seed", {}))
                total += len(seed.get("presses", []))
                trial.update(seed=seed, native_presses_total=total)
                real.write_json(output / ("trial-" + str(index) + ".json"), trial)
            if total > 36 or seed.get("verified") is not True:
                raise RuntimeError("diagnostic_input_budget_or_outcome")
            if session.metadata["drive_requests"] != 0:
                raise RuntimeError("diagnostic_unexpected_goal")
    finally:
        if isolate_glide_duration:
            try:
                restored = motion(session, duration, real, original["motion"])
                session.metadata["motion_restored"] = restored["motion"] == original["motion"]
            finally:
                cursor(session, original["enabled"])
                session.metadata["cursor_restored"] = cursor(session)["enabled"] is original["enabled"]
            if not session.metadata["motion_restored"] or not session.metadata["cursor_restored"]:
                raise RuntimeError("diagnostic_motion_restore_failed")
        elif original is not None:
            cursor(session, original["enabled"])
            restored = cursor(session)
            session.metadata["cursor_restored"] = restored["enabled"] is original["enabled"]
            if not session.metadata["cursor_restored"]:
                raise RuntimeError("diagnostic_cursor_restore_failed")
    medians = {}
    for enabled in (True, False):
        trials = [trial for trial in session.metadata["latency_trials"] if trial["condition"] == str(enabled)]
        medians[str(enabled)] = {
            label: statistics.median(next(entry["driver_wall_ms"] for entry in trial["seed"]["presses"]
                                          if entry["label"] == label) for trial in trials)
            for label in ("2", "Add", "3", "Equals")
        }
    key = ("median_driver_rpc_ms_by_glide_duration_condition" if isolate_glide_duration
           else "median_driver_rpc_ms_by_post_action_wait_condition" if isolate_post_action_wait
           else "median_driver_rpc_ms_by_cursor_condition")
    session.metadata[key] = medians


def sample_driver(session, window, output, everyday, real):
    if (session.daemon.poll() is not None or session.local.proc is None
            or session.local.proc.poll() is not None):
        raise RuntimeError("diagnostic_driver_unavailable")
    record = dict(qualification=False, duration_seconds=8, sampling_interval_ms=1, processes=[])
    session.metadata["driver_sample"] = record
    samplers = []
    try:
        for name, process in (("driver", session.daemon), ("proxy", session.local.proc)):
            path = name + "-sample.txt"
            argv = ["/usr/bin/sample", str(process.pid), "8", "1", "-mayDie", "-file", str(output / path)]
            entry = dict(pid=process.pid, path=path, argv=argv)
            record["processes"].append(entry)
            with (output / (name + "-sample-tool.log")).open("w") as log:
                sampler = subprocess.Popen(argv, stdout=log, stderr=log)
            samplers.append((sampler, entry))
        everyday.calculator_seed(session, window, observation_timeout_ms=5000)
    finally:
        for sampler, entry in samplers:
            try:
                entry["return_code"] = sampler.wait(timeout=15)
            except subprocess.TimeoutExpired:
                sampler.kill()
                entry["error"] = "sample_timeout"
                try:
                    sampler.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    entry["error"] = "sample_reap_timeout"
        real.write_json(output / "sample-receipt.json", record)
    for entry in record["processes"]:
        path = output / entry["path"]
        if (entry.get("return_code") != 0 or not path.is_file()
                or f"(pid {entry['pid']})" not in path.read_text()[:200]):
            raise RuntimeError("diagnostic_driver_sample_unavailable")
    if session.metadata["drive_requests"] != 0:
        raise RuntimeError("diagnostic_unexpected_goal")


def main():
    parser = argparse.ArgumentParser()
    for name in ("receipt", "case-receipt", "reviewed-source-delta", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--sample-driver", action="store_true")
    modes.add_argument("--isolate-post-action-wait", action="store_true")
    modes.add_argument("--isolate-glide-duration", action="store_true")
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("controlled native diagnostic approval required")
    qualification = SHARED.load("native_latency_qualification", "jev-vision-qualification.py")
    everyday = SHARED.load("native_latency_everyday", "jev-everyday-apps.py")
    real = qualification.real
    subject = json.loads(args.receipt.read_text())["candidates"]["after"]
    prior = json.loads(args.case_receipt.read_text())
    if (prior.get("binary_sha256") != subject["binary_sha256"]
            or prior.get("driver_sha256") != subject["driver_sha256"]
            or prior.get("resources_clean") is not True or len(prior.get("rows", [])) != 1
            or prior["rows"][0].get("case") != "calculator.add"):
        raise RuntimeError("diagnostic_subject_unverified")
    approved = qualification.load_reviewed_source_delta(args.reviewed_source_delta)
    output = SHARED.private_output(args.out)
    with real.execution_bundle(subject) as app:
        preparation = qualification.check_driver_artifact(subject, app)
        with real.Session(output, args.receipt, variant="after",
                          approved_source_delta=approved, prepared_app=app) as session:
            session.metadata.update(qualification=False, purpose="cursor wait causal isolation",
                                    model_requests=0, maximum_native_presses=6 if args.sample_driver else 36,
                                    preparation=preparation,
                                    diagnostic_observation_timeout_ms=5000,
                                    harness_source_sha256=real.digest(__file__),
                                    everyday_source_sha256=real.digest(everyday.__file__),
                                    interpretation="disabled cursor is a negative control, not a shipped speed improvement")
            apps = [row for row in session.call("list_apps", {}).get("apps", [])
                    if row.get("bundle_id", "").lower() == "com.apple.calculator"]
            if len(apps) != 1:
                raise RuntimeError("diagnostic_existing_calculator_unverified")
            window = dict(pid=apps[0]["pid"], window_id=prior["rows"][0]["requested_window_id"])
            if not any(row["window_id"] == window["window_id"] for row in session.windows(pid=window["pid"])):
                raise RuntimeError("diagnostic_original_window_unavailable")
            session.metadata["requested_window"] = window
            if args.sample_driver:
                session.metadata["purpose"] = "owned driver CPU sampling during guarded native setup"
                sample_driver(session, window, output, everyday, real)
            else:
                if args.isolate_post_action_wait:
                    session.metadata["purpose"] = "public post-action report wait causal isolation"
                    session.metadata["interpretation"] = "native RPC diagnostic only; not a shipped latency improvement"
                elif args.isolate_glide_duration:
                    session.metadata["purpose"] = "visible cursor motion duration causal isolation"
                    session.metadata["interpretation"] = "original versus 120ms visible glide; native RPCs, not goal qualification"
                measure(session, window, output, everyday, real,
                        isolate_post_action_wait=args.isolate_post_action_wait,
                        isolate_glide_duration=args.isolate_glide_duration)


if __name__ == "__main__":
    main()
