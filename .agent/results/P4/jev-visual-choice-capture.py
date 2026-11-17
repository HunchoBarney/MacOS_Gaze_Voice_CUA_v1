import argparse
import importlib.util
import json
import os
from pathlib import Path
import subprocess

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("visual_capture_shared", HERE / "jev-native-choice-capture.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--reviewed-source-delta", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("explicit controlled real-app approval required")
    qualification = shared.load("visual_capture_qualification", "jev-vision-qualification.py")
    real = qualification.real
    approved = qualification.load_reviewed_source_delta(args.reviewed_source_delta)
    subject = json.loads(args.receipt.read_text())["candidates"]["after"]
    args.out = shared.private_output(args.out)
    metadata = {
        "qualification": False, "purpose": "read-only visual decision diagnosis",
        "status": "error", "receipt_sha256": real.digest(args.receipt),
        "fixture_receipt_sha256": real.digest(args.fixture),
        "harness_sha256": real.digest(__file__),
    }
    try:
        with real.execution_bundle(subject) as app:
            metadata["preparation"] = qualification.check_driver_artifact(subject, app)
            with real.Session(args.out, args.receipt, variant="after",
                              approved_source_delta=approved, prepared_app=app) as session:
                with qualification.fixture(session, args.fixture, args.out) as (
                        window, state_path, fixture):
                    if (fixture["bundle_id"] != "dev.jevvoice.visual-fixture"
                            or fixture["source_sha256"]
                            != "27ba1284dbc3949bc1b738e8ca17e84d89351472bfaca17c16b22b745285bde1"):
                        raise RuntimeError("diagnostic_visual_fixture_unverified")
                    raw = session.raw_call("get_window_state", dict(window,
                        include_screenshot=True, include_accessibility_tree=True,
                        tree_format="both", max_elements=600, max_depth=20,
                        max_image_dimension=1568))
                    state = shared.scoped_elements(real.payload(raw))
                    if (state.get("pid") != window["pid"]
                            or state.get("window_id") != window["window_id"]
                            or state.get("window_title") != "Jev Visual Qualification"):
                        raise RuntimeError("diagnostic_snapshot_scope_changed")
                    images = [item for item in raw.get("content", []) if item.get("type") == "image"]
                    if len(images) != 1 or images[0].get("mimeType") != "image/png":
                        raise RuntimeError("diagnostic_window_image_unverified")
                    apps = [item for item in session.call("list_apps", {}).get("apps", [])
                            if item.get("pid") == window["pid"]]
                    windows = [item for item in session.windows(pid=window["pid"])
                               if item.get("window_id") == window["window_id"]]
                    if len(apps) != 1 or len(windows) != 1:
                        raise RuntimeError("diagnostic_roster_unverified")
                    real.write_json(args.out / "input.json", {
                        "qualification": False, "window": window, "fixture": fixture,
                        "fixture_state": str(state_path), "driver_reply": state,
                        "image_content": images, "session": session.local_session,
                        "deny": real.qualification_denials({}),
                        "daemon_socket": str(session.sock),
                        "tools": {"tools": list(session.tools.values())},
                        "apps": {"structuredContent": {"apps": apps}},
                        "windows": {"structuredContent": {"windows": windows}},
                    })
                    environment = dict(os.environ)
                    environment["JEV_VISUAL_CHOICE_INPUT"] = str(args.out / "input.json")
                    environment["JEV_NATIVE_CHOICE_API_KEY"] = real.require_api_key()
                    subprocess.run(["swift", "test", "--skip-build", "--filter",
                                    "JevVisualChoiceDiagnosticTests"], cwd=shared.ROOT,
                                   env=environment, check=True, timeout=120)
                    result = json.loads((args.out / "diagnostic.json").read_text())
                    journal = json.loads(state_path.read_text())
                    retained = session.windows(pid=window["pid"])
                    if (result.get("qualification") is not False or result.get("actuations") != 0
                            or journal.get("pid") != window["pid"]
                            or journal.get("window_id") != window["window_id"]
                            or journal.get("target_count") != 0 or journal.get("other_count") != 0
                            or not any(item["window_id"] == window["window_id"] for item in retained)):
                        raise RuntimeError("diagnostic_fixture_changed")
                    metadata.update(status="captured", result=result, journal=journal)
            metadata["resources_clean"] = session.metadata["resources_clean"]
            metadata["drive_requests"] = session.metadata["drive_requests"]
            metadata["fixture_cleanup"] = session.metadata.get("fixture_cleanup", [])
            if not metadata["resources_clean"] or metadata["drive_requests"] != 0:
                raise RuntimeError("diagnostic_resources_unclean")
    finally:
        real.write_json(args.out / "capture-receipt.json", metadata)


if __name__ == "__main__":
    main()
