import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def scoped_elements(state):
    rows = state.get("elements", [])
    roots = [row for row in rows if row.get("role") == "AXWindow"
             and row.get("parent_index") is None]
    if len(roots) != 1:
        raise RuntimeError("diagnostic_window_root_unverified")
    pending = [roots[0]["element_index"]]
    included = set()
    while pending:
        index = pending.pop()
        if index in included:
            continue
        included.add(index)
        pending.extend(row["element_index"] for row in rows if row.get("parent_index") == index
                       and not row.get("role", "").startswith("AXMenu"))
    result = dict(state, elements=[row for row in rows if row["element_index"] in included],
                  tree_markdown="")
    for key in ("screenshot", "screenshots", "images", "menu_bar", "menus"):
        result.pop(key, None)
    return result


def private_output(output):
    workspace = (ROOT.parent / "jarvis-v1-vision-driver/development/JevVoice").resolve(strict=True)
    output = Path(os.path.abspath(output.expanduser()))
    try:
        relative = output.parent.relative_to(workspace)
    except ValueError:
        raise SystemExit("diagnostic output must be inside the existing native workspace")
    parent = workspace
    for part in relative.parts:
        parent /= part
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid():
            raise SystemExit("diagnostic parent is not an owned directory")
    if output.exists() or output.is_symlink():
        raise SystemExit("diagnostic output already exists")
    output.mkdir(mode=0o700, exist_ok=False)
    info = output.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700 or output.resolve() != output.absolute()):
        raise SystemExit("diagnostic output ownership or permissions unverified")
    with os.fdopen(os.open(output / ".gitignore",
                   os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "w") as stream:
        stream.write("*\n")
    return output


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--case-receipt", type=Path, required=True)
    parser.add_argument("--reviewed-source-delta", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("explicit controlled real-app approval required")
    qualification = load("native_choice_qualification", "jev-vision-qualification.py")
    real = qualification.real
    native = load("native_choice_helpers", "jev-realapps-native.py")
    approved = qualification.load_reviewed_source_delta(args.reviewed_source_delta)
    subject = json.loads(args.receipt.read_text())["candidates"]["before"]
    args.out = private_output(args.out)
    metadata = {"qualification": False, "purpose": "read-only native decision diagnosis",
                "receipt_sha256": real.digest(args.receipt),
                "harness_sha256": real.digest(__file__), "status": "error"}
    try:
        with real.execution_bundle(subject) as app:
            metadata["preparation"] = qualification.check_driver_artifact(subject, app)
            with real.Session(args.out, args.receipt, variant="before",
                              approved_source_delta=approved, prepared_app=app) as session:
                fixture = session.adopt_document_fixture(args.case_receipt)
                metadata["retained_fixture"] = {
                    "window": fixture["window"], "created_by_diagnostic": False,
                    "process_teardown": False,
                    "reason": "borrowed existing synthetic document retained for replay; sibling preserved",
                }

                def capture(case, oracle):
                    window = fixture["window"]
                    if oracle()[1] is not False:
                        raise RuntimeError("diagnostic_unfinished_baseline_unverified")
                    state = session.call("get_window_state", dict(window,
                        include_screenshot=False, tree_format="elements",
                        max_elements=600, max_depth=20))
                    if (state.get("pid") != window["pid"] or state.get("window_id") != window["window_id"]
                            or fixture["marker"] not in state.get("window_title", "")):
                        raise RuntimeError("diagnostic_snapshot_scope_changed")
                    if session.read_owned_document(window, fixture["marker"], fixture["path"],
                            [fixture["baseline"], fixture["value"]]) != fixture["baseline"]:
                        raise RuntimeError("diagnostic_native_baseline_changed")
                    apps = session.call("list_apps", {}).get("apps", [])
                    apps = [row for row in apps if row.get("pid") == window["pid"]]
                    windows = [row for row in session.windows(pid=window["pid"])
                               if row.get("window_id") == window["window_id"]]
                    if len(apps) != 1 or len(windows) != 1:
                        raise RuntimeError("diagnostic_roster_unverified")
                    real.write_json(args.out / "input.json", {
                        "qualification": False, "window": window, "marker": fixture["marker"],
                        "document_path": str(fixture["path"]), "baseline": fixture["baseline"],
                        "task": case, "driver_reply": {"structuredContent": scoped_elements(state)},
                        "apps": {"structuredContent": {"apps": apps}},
                        "windows": {"structuredContent": {"windows": windows}},
                        "native_oracle": session.metadata["owned_document_reads"][-1],
                    })

                session.drive = capture
                native.textedit_owned(session, args.case_receipt)
                if session.metadata["drive_requests"] != 0:
                    raise RuntimeError("diagnostic_unexpected_drive_request")
            if not session.metadata["resources_clean"]:
                raise RuntimeError("diagnostic_resources_unclean")
        environment = dict(os.environ)
        environment["JEV_NATIVE_CHOICE_INPUT"] = str((args.out / "input.json").resolve())
        environment["JEV_NATIVE_CHOICE_API_KEY"] = real.require_api_key()
        subprocess.run(["swift", "test", "--skip-build", "--filter",
                        "JevNativeChoiceDiagnosticTests"], cwd=ROOT, env=environment, check=True)
        result = json.loads((args.out / "diagnostic.json").read_text())
        if result.get("qualification") is not False or result.get("actuations") != 0:
            raise RuntimeError("diagnostic_output_invalid")
        metadata.update(status="captured", result=result, resources_clean=True, drive_requests=0)
    finally:
        real.write_json(args.out / "capture-receipt.json", metadata)


if __name__ == "__main__":
    main()
