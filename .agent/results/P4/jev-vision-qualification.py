import argparse
import base64
import contextlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import subprocess
import sys
import tempfile
import time
import uuid


HERE = Path(__file__).resolve().parent


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


real = load("vision_realapps", "jev-realapps.py")

FIXTURE_ID = "dev.jevvoice.visual-fixture"


def build_fixture(directory):
    app = directory / "Jev Visual Fixture.app"
    binary = app / "Contents/MacOS/JevVisualFixture"
    binary.parent.mkdir(parents=True)
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": FIXTURE_ID, "CFBundleName": "Jev Visual Fixture",
        "CFBundleExecutable": binary.name, "CFBundlePackageType": "APPL",
        "CFBundleVersion": "1", "NSHighResolutionCapable": True,
        "NSPrincipalClass": "NSApplication",
    }))
    source = HERE / "JevVisualFixture.swift"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-framework", "AppKit",
                    str(source), "-o", str(binary)], check=True, timeout=180)
    workspace_app = app
    verification = Path(tempfile.mkdtemp(prefix="jev-visual-fixture-"))
    app = verification / app.name
    subprocess.run(["cp", "-cR", str(workspace_app), str(app)], check=True, timeout=30)
    binary = app / "Contents/MacOS/JevVisualFixture"
    subprocess.run(["xattr", "-cr", str(app)], check=True, timeout=20)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=30)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, timeout=30)
    receipt = {
        "app": str(app.resolve()), "binary": str(binary.resolve()), "bundle_id": FIXTURE_ID,
        "workspace_build_app": str(workspace_app.resolve()),
        "source_sha256": real.digest(source), "binary_sha256": real.digest(binary),
    }
    real.write_json(directory / "fixture.json", receipt)
    return receipt


def check_driver_artifact(subject, app):
    environment = {key: value for key, value in os.environ.items() if key in {
        "PATH", "HOME", "LANG", "LC_ALL", "TMPDIR", "USER", "SHELL", "__CF_USER_TEXT_ENCODING",
    }}
    environment.update(DO_NOT_TRACK="1", CUA_TELEMETRY="0", CUA_DRIVER_RS_TELEMETRY_ENABLED="0")
    driver = app / "Contents/Resources/cua-driver"
    identity = (driver.stat().st_dev, driver.stat().st_ino)
    if real.digest(driver) != subject["driver_sha256"]:
        raise RuntimeError("artifact_driver_changed")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, timeout=30)
    start = time.perf_counter()
    version = subprocess.run([str(driver), "--version"], env=environment,
                             capture_output=True, text=True, timeout=90)
    result = {"version": version.stdout.strip(), "exit_code": version.returncode,
              "read_only_cli_ms": (time.perf_counter() - start) * 1000,
              "driver_inode": identity[1]}
    if ((driver.stat().st_dev, driver.stat().st_ino) != identity
            or real.digest(driver) != subject["driver_sha256"]):
        raise RuntimeError("artifact_driver_changed")
    if version.returncode != 0 or result["version"] != "cua-driver 0.45.4":
        raise RuntimeError("artifact_version_validation_failed: " + json.dumps(result))
    return result


def check_artifacts(receipt_path, directory):
    receipt = json.loads(receipt_path.read_text())
    results = {}
    for variant, subject in receipt["candidates"].items():
        with real.execution_bundle(subject) as app:
            results[variant] = check_driver_artifact(subject, app)
    real.write_json(directory / "artifact-check.json", results)


def execution_receipt():
    lock_directory = Path(os.environ.get("JARVIS_DESKTOP_LOCK_DIRECTORY",
        str(Path.home() / "Library/Caches/JarvisDevelopment")))
    with (lock_directory / "desktop.lock").open("r") as descriptor:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            held = True
        else:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            raise RuntimeError("qualification must run under scripts/with-desktop-lock.py")
    parent = subprocess.run(["ps", "-p", str(os.getppid()), "-o", "command="],
                            check=True, capture_output=True, text=True, timeout=3).stdout.strip()
    return {
        "argv": sys.argv, "parent_command": parent, "desktop_lock_held": held,
        "lane_sha256": real.digest(real.ROOT / "scripts/verification-lane.sh"),
        "desktop_wrapper_sha256": real.digest(real.ROOT / "scripts/with-desktop-lock.py"),
    }


@contextlib.contextmanager
def fixture(session, receipt_path, directory, seed=0):
    receipt = json.loads(receipt_path.read_text())
    binary = Path(receipt["binary"])
    assert real.digest(binary) == receipt["binary_sha256"]
    assert real.digest(HERE / "JevVisualFixture.swift") == receipt["source_sha256"]
    subprocess.run(["codesign", "--verify", "--deep", "--strict", receipt["app"]],
                   check=True, timeout=30)
    state_path = directory / "fixture-state.json"
    process = subprocess.Popen([str(binary), str(state_path), str(seed)],
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        def ready():
            if process.poll() is not None:
                raise RuntimeError("owned fixture exited before readiness")
            if not state_path.exists():
                return None
            state = json.loads(state_path.read_text())
            assert state["pid"] == process.pid
            return state if state["window_id"] > 0 else None
        state = real.wait_for(ready, 10, "owned fixture state")
        assert state["target_count"] == state["other_count"] == 0
        target = {"pid": process.pid, "window_id": state["window_id"]}
        real.wait_for(lambda: any(row["window_id"] == target["window_id"]
                                 for row in session.windows(pid=process.pid)),
                      10, "owned fixture window binding")
        yield target, state_path, receipt
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=4)
        session.metadata.setdefault("fixture_cleanup", []).append({
            "pid": process.pid, "exited": process.poll() is not None,
        })


def capture_fixture(session, target, directory):
    raw = session.raw_call("get_window_state", dict(target,
        include_screenshot=True, tree_format="elements", max_elements=2000))
    state = real.payload(raw)
    public = {key: value for key, value in state.items() if key in {
        "capture_id", "snapshot_id", "ax_snapshot_id", "pid", "window_id", "window_bounds",
        "screenshot_width", "screenshot_height", "screenshot_dimensions", "coordinate_space",
        "capture_frame_valid", "screenshot_metadata", "capture_metadata",
    }}
    public["returned_keys"] = sorted(state)
    public["buttons"] = [
        {key: value for key, value in row.items() if key in {
            "role", "label", "title", "element_index", "element_token", "identifier",
            "bounds", "frame", "actions", "value", "enabled", "states",
        }}
        for row in state.get("elements", []) if row.get("role") == "AXButton"
    ]
    real.write_json(directory / "capture.json", public)
    images = [row for row in raw.get("content", [])
              if row.get("type") == "image" and row.get("mimeType") == "image/png"]
    assert len(images) == 1, "owned window must return exactly one PNG"
    png = base64.b64decode(images[0]["data"], validate=True)
    assert png.startswith(b"\x89PNG\r\n\x1a\n")
    (directory / "capture.png").write_bytes(png)
    return state


def raw_click(session, arguments):
    start = time.perf_counter()
    result = session.raw_call("click", arguments)
    return result, (time.perf_counter() - start) * 1000


def refused(result, code):
    body = result.get("structuredContent", {})
    assert result.get("isError") is True, result
    if code == "stale_element_token":
        assert body.get("refusal", {}).get("code") == code, body
        assert body.get("status") == "refused", body
    else:
        assert body.get("code") == code, body
        assert body.get("effect") == "refused", body


def native_proof(session, target, state_path, directory, seed):
    state = capture_fixture(session, target, directory)
    button = next(row for row in state["elements"] if row.get("role") == "AXButton"
                  and row.get("label") == "symbol-" + str(seed % 2))
    arguments = dict(target, capture_id=state["capture_id"])
    if session.variant == "after":
        arguments["element_token"] = button["element_token"]
        mixed, _ = raw_click(session, dict(arguments, x=10, y=10))
        refused(mixed, "invalid_capture_input")
        assert json.loads(state_path.read_text())["target_count"] == 0
    else:
        frame, bounds = button["frame"], state["window_bounds"]
        arguments.update(
            x=(frame["x"] + frame["w"] / 2 - bounds["x"]) * state["screenshot_width"] / bounds["width"],
            y=(frame["y"] + frame["h"] / 2 - bounds["y"]) * state["screenshot_height"] / bounds["height"],
        )
    result, elapsed = raw_click(session, arguments)
    real.payload(result)
    actual = real.wait_for(lambda: (
        row if row["target_count"] == 1 else None
    ) if (row := json.loads(state_path.read_text())) else None, 3, "native target activation")
    assert actual["other_count"] == 0, actual
    reuse, _ = raw_click(session, arguments)
    refused(reuse, "capture_not_found")
    assert json.loads(state_path.read_text())["target_count"] == 1
    session.metadata["native_proof"] = {
        "addressing": "captured_element" if session.variant == "after" else "captured_coordinates",
        "input_keys": sorted(arguments), "actual_state": actual, "elapsed_ms": elapsed,
        "delivery": result.get("structuredContent", {}), "reuse_code": "capture_not_found",
    }
    if session.variant == "after":
        fresh = capture_fixture(session, target, directory / "stale")
        session.call("get_window_state", dict(target, include_screenshot=False, tree_format="elements"))
        stale_button = next(row for row in fresh["elements"]
                            if row.get("label") == "symbol-" + str(seed % 2))
        stale, _ = raw_click(session, dict(target, capture_id=fresh["capture_id"],
                                         element_token=stale_button["element_token"]))
        refused(stale, "stale_element_token")
        actual = json.loads(state_path.read_text())
        assert actual["target_count"] == 1 and actual["other_count"] == 0, actual
        session.metadata["native_proof"]["stale_snapshot_code"] = "stale_element_token"


def fixture_loop(session, target, state_path, receipt):
    def oracle():
        state = json.loads(state_path.read_text())
        return state, state["target_count"] == 1 and state["other_count"] == 0
    assert oracle()[1] is False
    session.metadata["api_requests"] = None
    row = session.drive({
        "id": "visual.green-triangle", "kind": "synthetic-production-loop",
        "requires_visual_trace": True,
        "app": receipt["bundle_id"], "window_id": target["window_id"],
        "goal": "Activate the green triangle.",
    }, oracle)
    assert row["actual_state"]["other_count"] == 0, "wrong control activated; stop qualification"


def inspection_target(previous):
    row = next(row for row in previous["rows"] if row["case"] == "textedit.replace.body")
    match = re.search(r"Jev real app text entry ([0-9a-f]{10})\.", row["goal"])
    if match is None:
        raise RuntimeError("owned_inspection_origin_unverified")
    marker = match[1]
    lease = previous.get("fixture_lease")
    if lease is None:
        pids = previous["textedit_roster_pids"]
        assert len(pids) == 1
        return marker, {"pid": pids[0], "window_id": row["requested_window_id"]}
    origin = Path(lease["origin"])
    if origin.is_symlink() or real.digest(origin) != lease["origin_sha256"]:
        raise RuntimeError("owned_inspection_origin_unverified")
    source = json.loads(origin.read_text())
    windows = source.get("owned_document_windows_remaining", [])
    document = origin.parent / ("Jev-Test-Document-" + marker + ".txt")
    if (source.get("textedit_reuses_existing_app") is not False
            or source.get("textedit_launch_requested") is not True
            or source.get("drive_requests") != 0 or len(windows) != 1
            or not isinstance(source.get("textedit_launch_pid"), int)
            or lease.get("window") != {"pid": source["textedit_launch_pid"], "window_id": windows[0]}
            or windows[0] != row["requested_window_id"]
            or not document.is_file() or document.is_symlink()
            or origin.parent.stat().st_uid != os.getuid()):
        raise RuntimeError("owned_inspection_origin_unverified")
    return marker, lease["window"]


def cleanup_textedit(session, case_receipt, inspect_only=False):
    if not inspect_only:
        session.adopt_document_fixture(case_receipt, cleanup=True)
        session.metadata["cleanup_scope"] = "synthetic document only; no process termination"
        return
    previous = json.loads(case_receipt.read_text())
    marker, target = inspection_target(previous)
    lease = previous.get("fixture_lease")
    if lease and real.process_stamp(target["pid"]) != lease.get("process_stamp"):
        raise RuntimeError("owned_inspection_process_changed")
    windows = session.windows(pid=target["pid"])
    window = next(item for item in windows if item["window_id"] == target["window_id"])
    assert marker in window.get("title", window.get("window_title", ""))
    state = session.call("get_window_state", dict(target, include_screenshot=False,
                                                 tree_format="elements", max_elements=500))
    values = [item["value"] for item in state.get("elements", [])
              if item.get("role") == "AXTextArea" and isinstance(item.get("value"), str)]
    expected = "Jev real app text entry " + marker + "."
    if inspect_only:
        roles = {}
        candidates = []
        for item in state.get("elements", []):
            role = item.get("role", "").lower()
            roles[role] = roles.get(role, 0) + 1
            if role in ("axtextarea", "textarea") and isinstance(item.get("value"), str):
                candidates.append(item["value"])
        session.metadata["owned_window_inspection"] = {
            "app_window_ids": sorted(row["window_id"] for row in windows),
            "state_field_types": {key: type(value).__name__ for key, value in state.items()},
            "degraded": state.get("degraded"),
            "degraded_code": next((code for code in (
                "screen_locked", "ax_window_unresolved", "ax_app_launching", "ax_timeout",
            ) if str(state.get("degraded_reason", "")).startswith(code)), "unclassified"),
            "elements_complete": state.get("elements_complete"),
            "truncated": state.get("truncated"),
            "element_count": state.get("element_count"),
            "timeout_ms": state.get("timeout_ms"),
            "roles": roles, "exact_role_value_count": len(values),
            "normalized_role_value_count": len(candidates),
            "known_body_exact": len(candidates) == 1 and candidates[0] == expected,
            "known_body_boundary_whitespace_only": len(candidates) == 1 and candidates[0].strip() == expected,
            "mutations": 0,
        }
        session.metadata["owned_window_inspection"]["native"] = session.native_window_state(
            target, state.get("window_title", ""))
        session.metadata["owned_window_inspection"]["native_window_proven"] = real.native_window_proven(
            session.metadata["owned_window_inspection"]["native"], target, state.get("window_title", ""))
        raw = session.raw_call("get_window_state", dict(target, include_screenshot=True,
                                                       tree_format="elements", max_elements=500))
        captured = real.payload(raw)
        assert captured["pid"] == target["pid"] and captured["window_id"] == target["window_id"]
        images = [item for item in raw.get("content", []) if item.get("type") == "image"]
        session.metadata["owned_window_inspection"]["image_count"] = len(images)
        if len(images) == 1 and images[0].get("mimeType") == "image/png":
            image = session.directory / "owned-window.png"
            image.write_bytes(base64.b64decode(images[0]["data"], validate=True))
            image.chmod(0o600)
            session.metadata["owned_window_inspection"]["image_sha256"] = real.digest(image)
        real.write_json(session.directory / "owned-window-inspection.json",
                        session.metadata["owned_window_inspection"])
        return


def preflight(session):
    schemas = {}
    for name in ("click", "type_text", "press_key", "scroll"):
        schema = session.tools[name]["inputSchema"]
        assert "capture_id" in schema["properties"], (name, "missing capture binding")
        native = schema.get("x-cua-capture-bound-element") is True
        expected = session.variant == "after"
        assert native == expected, (name, "unexpected captured-native capability", native)
        schemas[name] = {"capture_bound": True, "captured_native": native}
    session.metadata["capability_preflight"] = schemas
    session.metadata["api_requests"] = 0
    session.metadata["ordinary_app_mutations"] = 0


def load_reviewed_source_delta(path):
    review = json.loads(path.read_text())
    assert review["verdict"] == "PASS"
    assert real.digest(Path(review["review_receipt"])) == review["review_receipt_sha256"]
    delta = review["source_changes"]
    valid_hash = lambda value: isinstance(value, str) and re.fullmatch("[0-9a-f]{64}", value)
    assert delta and all(
        isinstance(value, dict) and set(value) == {"before", "after"}
        and (value["before"] is None or valid_hash(value["before"]))
        and valid_hash(value["after"]) for value in delta.values())
    return delta


def profile_subject_variant(args, variant):
    if args.matched_calculator:
        return "after"
    return "before" if args.baseline_receipt else variant


def run_pairs(args):
    repeated = args.command in ("native-proof", "fixture-loop", "realapps-textedit", "realapps-everyday")
    runs = [(variant, repeat)
            for repeat in range(args.repeats if repeated else 1)
            for variant in (("before", "after") if repeat % 2 == 0 else ("after", "before"))]
    if args.pilot:
        return [("after", 0)]
    if args.command == "realapps-everyday" and not args.matched_calculator:
        return [("after", repeat) for repeat in range(args.repeats)]
    return runs


def main():
    main_started = time.monotonic()
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=[
        "preflight", "artifact-check", "fixture-build", "fixture-inspect", "native-proof", "fixture-loop",
        "realapps-textedit",
        "realapps-everyday",
        "cleanup-owned-textedit",
        "inspect-owned-textedit",
        "resolve-owned-textedit-conflict",
    ])
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--case-receipt", type=Path)
    parser.add_argument("--baseline-receipt", type=Path)
    parser.add_argument("--reviewed-source-delta", type=Path)
    parser.add_argument("--pilot", action="store_true")
    parser.add_argument("--app-case", choices=["chrome", "safari", "notes", "spotify", "calculator", "inspect", "keys", "menu", "scroll"])
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--matched-calculator", action="store_true")
    parser.add_argument("--warm-same-session", action="store_true")
    args = parser.parse_args()
    if args.warm_same_session:
        assert (args.command == "realapps-everyday" and args.app_case == "calculator"
                and args.pilot and args.repeats == 1 and not args.baseline_receipt)
    if args.matched_calculator:
        assert args.command == "realapps-everyday" and args.app_case == "calculator"
        assert args.baseline_receipt and args.reviewed_source_delta and not args.pilot and args.repeats == 3
    if args.command == "resolve-owned-textedit-conflict":
        assert args.pilot and args.repeats == 1 and args.case_receipt is not None
        assert os.environ.get("JARVIS_P4_FIXTURE_CONFLICT_SAVE") == "approved-once"
    if args.command == "realapps-everyday":
        assert args.app_case is not None
    approved_delta = None
    if args.reviewed_source_delta:
        approved_delta = load_reviewed_source_delta(args.reviewed_source_delta)
    if args.baseline_receipt:
        assert (args.command == "realapps-textedit" or args.matched_calculator) and approved_delta
        source_variant = profile_subject_variant(args, "before")
        baseline = json.loads(args.baseline_receipt.read_text())["candidates"][source_variant]
        candidate = json.loads(args.receipt.read_text())["candidates"][source_variant]
        assert baseline["unsigned_driver_sha256"] == candidate["unsigned_driver_sha256"]
        assert baseline["driver_sha256"] == candidate["driver_sha256"]
    if args.pilot:
        assert args.command in ("realapps-textedit", "fixture-loop", "realapps-everyday",
                                "resolve-owned-textedit-conflict") and args.repeats == 1
    if args.command in ("fixture-loop", "realapps-textedit", "realapps-everyday"):
        for item in json.loads(args.receipt.read_text())["candidates"].values():
            info = plistlib.loads((Path(item["app"]) / "Contents/Info.plist").read_bytes())
            assert info.get("JevExperimentalWindowImages") is True, "candidate image opt-in missing"
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("explicit real-app qualification approval required")
    invocation = execution_receipt()
    args.out.mkdir(mode=0o700)
    (args.out / ".gitignore").write_text("*\n")
    summary = {
        "platform": platform.platform(), "python": sys.version,
        "receipt_sha256": real.digest(args.receipt),
        "harness_sha256": real.digest(__file__),
        "session_harness_sha256": real.digest(HERE / "jev-realapps.py"),
        "native_helpers_sha256": real.digest(HERE / "jev-realapps-native.py"),
        "command": args.command, "variants": {}, "status": "running",
        "execution": invocation,
        "front_door": "signed embedded daemon MCP; not GUI/Fn",
        "repeats": args.repeats if args.command in ("native-proof", "fixture-loop", "realapps-textedit", "realapps-everyday") else 1,
        "app_case": args.app_case,
        "scope": "affected-path pilot" if args.pilot else "qualification",
        "comparison": "app-source, same coordinate driver" if args.baseline_receipt else "driver variants",
        "baseline_receipt_sha256": real.digest(args.baseline_receipt) if args.baseline_receipt else None,
        "reviewed_source_delta_sha256": real.digest(args.reviewed_source_delta) if args.reviewed_source_delta else None,
        "fixture_origin_sha256": real.digest(args.case_receipt) if args.case_receipt else None,
        "fixture_lifecycle": "retained for matched replay; separate exact-document cleanup"
        if args.command == "realapps-textedit" and args.case_receipt else "per-run owned",
        "runtime_preparation": {},
        "startup_scope": "pre-executed runtime copy; not production cold-start qualification",
    }
    prepared = contextlib.ExitStack()
    prepared_apps = {}
    prepared_variants = {}
    subjects = {}
    active_run = None
    try:
        if args.command == "fixture-build":
            build_fixture(args.out)
        if args.command == "artifact-check":
            check_artifacts(args.receipt, args.out)
        repeated = args.command in ("native-proof", "fixture-loop", "realapps-textedit", "realapps-everyday")
        assert not repeated or args.repeats >= 3 or args.pilot
        runs = run_pairs(args)
        markers = {repeat: uuid.uuid4().hex[:10] for _, repeat in runs}
        if args.command in ("cleanup-owned-textedit", "inspect-owned-textedit"):
            assert args.case_receipt is not None
            runs = [(json.loads(args.case_receipt.read_text())["variant"], 0)]
        actual_runs = () if args.command in ("fixture-build", "artifact-check") else runs
        for variant, _ in actual_runs:
            subject_receipt = args.baseline_receipt if args.baseline_receipt and variant == "before" else args.receipt
            subject_variant = profile_subject_variant(args, variant)
            subject = json.loads(subject_receipt.read_text())["candidates"][subject_variant]
            identity = (subject["app"], subject.get("manifest_sha256"))
            subjects[variant] = (subject_receipt, subject_variant, identity)
            preparation_started = time.monotonic()
            if identity in prepared_apps:
                if variant not in summary["runtime_preparation"]:
                    original = prepared_variants[identity]
                    summary["runtime_preparation"][variant] = dict(
                        summary["runtime_preparation"][original],
                        reused_preparation_of=original, cold_validation_ms=0.0,
                        setup_wall_ms=(time.monotonic() - preparation_started) * 1000)
                continue
            preparation = {"status": "error", "canonical_app": subject["app"],
                           "pre_executed_runtime": True}
            summary["runtime_preparation"][variant] = preparation
            try:
                app = prepared.enter_context(real.execution_bundle(subject))
                preparation["prepared_execution_app"] = str(app)
                probe = check_driver_artifact(subject, app)
                preparation.update(cold_validation_ms=probe["read_only_cli_ms"],
                                   prepared_driver_inode=probe["driver_inode"],
                                   version=probe["version"], status="pass")
                prepared_apps[identity] = app if subject.get("frozen_payload_verified") else None
                prepared_variants[identity] = variant
            finally:
                preparation["setup_wall_ms"] = (time.monotonic() - preparation_started) * 1000
        for variant, repeat in actual_runs:
            key = variant + "-" + str(repeat) if repeated else variant
            directory = args.out / key
            directory.mkdir(mode=0o700)
            active_run = key
            start = time.monotonic()
            subject_receipt, subject_variant, identity = subjects[variant]
            with real.Session(directory, subject_receipt, variant=subject_variant,
                              startup_diagnostics=args.command == "preflight",
                              approved_source_delta=approved_delta,
                              prepared_app=prepared_apps[identity]) as session:
                session.metadata["comparison_variant"] = variant
                session.metadata["qualification_scope"] = summary["scope"]
                session.metadata["matched_calculator"] = args.matched_calculator
                preflight(session)
                if args.command in ("cleanup-owned-textedit", "inspect-owned-textedit"):
                    cleanup_textedit(session, args.case_receipt,
                                     inspect_only=args.command == "inspect-owned-textedit")
                if args.command == "realapps-textedit":
                    session.metadata["ordinary_app_mutations"] = None
                    session.metadata["api_requests"] = None
                    helpers = load("qualification_native_helpers", "jev-realapps-native.py")
                    if args.case_receipt:
                        helpers.textedit_owned(session, args.case_receipt)
                    else:
                        helpers.textedit(session, real.wait_for, marker=markers[repeat])
                if args.command == "resolve-owned-textedit-conflict":
                    session.metadata["qualification_scope"] = "fixture maintenance only; not goal qualification"
                    helpers = load("qualification_native_helpers", "jev-realapps-native.py")
                    helpers.resolve_owned_conflict(session, args.case_receipt, real)
                    assert session.metadata["fixture_conflict_save"]["status"] == "verified"
                    assert session.metadata["drive_requests"] == 0
                if args.command == "realapps-everyday":
                    helpers = load("qualification_everyday_helpers", "jev-everyday-apps.py")
                    native = load("qualification_native_helpers", "jev-realapps-native.py")
                    session.metadata["ordinary_app_mutations"] = None
                    session.metadata["api_requests"] = None
                    session.metadata["everyday_helpers_sha256"] = real.digest(HERE / "jev-everyday-apps.py")
                    if args.warm_same_session:
                        helpers.calculator_pilot(session, real.wait_for)
                    else:
                        helpers.run(session, args.app_case, real.wait_for, native)
                if args.command in ("fixture-inspect", "native-proof", "fixture-loop"):
                    assert args.fixture is not None
                    with fixture(session, args.fixture, directory, repeat) as (target, state_path, receipt):
                        if args.command == "fixture-inspect":
                            state = capture_fixture(session, target, directory)
                            session.metadata["capture_returned"] = bool(state)
                        elif args.command == "native-proof":
                            (directory / "stale").mkdir()
                            native_proof(session, target, state_path, directory, repeat)
                        else:
                            fixture_loop(session, target, state_path, receipt)
            summary["variants"][key] = {
                "status": "pass", "elapsed_seconds": time.monotonic() - start,
                "resources_clean": session.metadata["resources_clean"],
                "rows": session.metadata["rows"],
                "prepared_execution_app": session.metadata.get("execution_app"),
                "prepared_driver_inode": session.metadata.get("driver_inode"),
            }
            assert session.metadata["resources_clean"]
            print(key, args.command, "finished; owned runtime stopped", flush=True)
        rows = [row for variant in summary["variants"].values() for row in variant["rows"]]
        complete = all(row["strict_success"] and (
            not row.get("visual_trace_required") or row.get("visual_trace_complete")) for row in rows)
        summary["status"] = "observed" if args.app_case == "inspect" else "pass" if complete else "fail"
        summary["acceptance_eligible"] = (args.app_case != "inspect"
                                         and args.command not in (
                                             "resolve-owned-textedit-conflict", "inspect-owned-textedit"))
        if args.command == "resolve-owned-textedit-conflict":
            summary["scope"] = "fixture maintenance only; not goal qualification"
    except BaseException as error:
        summary["status"] = "error"
        summary["error_type"] = type(error).__name__
        summary["error_message"] = str(error)
        if active_run is not None:
            summary["failed_run"] = active_run
            summary["failed_run_artifacts"] = {
                "session": active_run + "/results.json",
                "calculator_seed": active_run + "/calculator-seed.json" if args.matched_calculator else None,
            }
            if args.warm_same_session:
                summary["failed_run_artifacts"]["calculator_seeds"] = {
                    kind: f"{active_run}/calculator-{kind}-seed.json"
                    if (args.out / active_run / f"calculator-{kind}-seed.json").is_file() else None
                    for kind in ("cold", "warm")
                }
        raise
    finally:
        try:
            prepared.close()
        finally:
            summary["total_wall_ms"] = (time.monotonic() - main_started) * 1000
            real.write_json(args.out / "summary.json", summary)
            print("evidence", args.out, flush=True)
    return 0 if summary["status"] in ("pass", "observed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
