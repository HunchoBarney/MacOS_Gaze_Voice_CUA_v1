import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    if re.fullmatch("[a-z0-9-]{1,20}", args.label) is None:
        raise RuntimeError("Invalid capture label")
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise RuntimeError("Controlled desktop approval is required")
    os.umask(0o077)
    spec = importlib.util.spec_from_file_location("c1_capture_scroll", HERE / "c1-scroll.py")
    scroll = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(scroll)
    real = scroll.load("c1_capture_real", HERE / "jev-realapps.py")
    stage = scroll.load("c1_capture_stage", HERE / "jev-clone-stage.py")
    capture = scroll.load("c1_capture_helpers", HERE / "jev-native-choice-capture.py")
    cleanup = scroll.load("c1_capture_cleanup",
        ROOT / ".agent/results/P3/physical-20261105/run-focus-window-density.py")
    output = capture.private_output(
        ROOT.parent / "jarvis-v1-vision-driver/development/JevVoice" / ("c1-scroll-request-" + args.label))
    receipt = ROOT / ".agent/results/P12/c1-final-r4-stage.json"
    original = json.loads(receipt.read_text())
    candidate = dict(original)
    candidate["source_sha256"] = {p: h for p, h in original["source_sha256"].items()
                                   if p != "Package.resolved"}
    candidate["driver_sha256"] = original["driver"]["signed_sha256"]
    adapter = output / "candidate.json"
    real.write_json(adapter, {"original_receipt": str(receipt),
                             "original_receipt_sha256": real.digest(receipt),
                             "candidates": {"c1": candidate}})
    current = stage.sources()
    delta = {p: {"before": candidate["source_sha256"].get(p), "after": current.get(p)}
             for p in set(current) | set(candidate["source_sha256"])
             if candidate["source_sha256"].get(p) != current.get(p)}
    compiled = json.loads((HERE / "c1-r1-questions-passing-after.json").read_text())
    assert all(real.digest(ROOT / p) == digest for p, digest in compiled["source_sha256"].items()
               if p.startswith(("Sources/", "Tests/")) or p == "Package.resolved")
    executable = ROOT / ".build/release/JevVoicePackageTests.xctest/Contents/MacOS/JevVoicePackageTests"
    marker = "c1-scroll-" + uuid.uuid4().hex[:8]
    document = output / ("Jev-Test-Document-" + marker + ".txt")
    text = "\n".join(f"Jev owned scrolling fixture line {index:04d}" for index in range(300))
    document.write_text(text)
    count, _ = cleanup.inventory()
    metadata = {
        "qualification": False,
        "purpose": "inspect production preview/chooser requests against real captured owned-window data",
        "boundary": "cached release diagnostic, separate document identity; not signed-app G5",
        "workload": "unchanged 300-line document content and scroll-down goal",
        "source_candidate_binary_sha256": original["binary_sha256"],
        "test_executable_sha256": real.digest(executable),
        "harness_sha256": real.digest(__file__),
        "documents_before": count,
        "captured": False,
    }
    opened = False
    try:
        with real.Session(output, adapter, variant="c1", approved_source_delta=delta or None) as session:
            scroll.apple(f'tell application "TextEdit" to open POSIX file {json.dumps(str(document))}')
            opened = True
            scroll.apple('tell application "TextEdit" to activate')
            real.wait_for(lambda: scroll.body(document) == text, 8, "owned diagnostic readiness")
            pid = int(scroll.apple('tell application "System Events" to return unix id of first application process whose bundle identifier is "com.apple.TextEdit"'))
            document_query = 'tell application "System Events" to tell application process "TextEdit" to return value of attribute "AXDocument" of front window'
            assert scroll.apple(document_query) == document.as_uri()
            window = {"pid": pid, "window_id": int(scroll.apple('tell application "TextEdit" to return id of front window'))}
            assert scroll.apple(document_query) == document.as_uri()
            state = session.call("get_window_state", dict(window,
                include_screenshot=False, tree_format="elements", max_elements=600, max_depth=20))
            assert state["pid"] == pid and state["window_id"] == window["window_id"]
            assert session.read_owned_document(window, marker, document, [text]) == text
            apps = [row for row in session.call("list_apps", {}).get("apps", []) if row["pid"] == pid]
            windows = [row for row in session.windows(pid=pid) if row["window_id"] == window["window_id"]]
            assert len(apps) == len(windows) == 1
            input_file = output / "input.json"
            real.write_json(input_file, {
                "qualification": False, "window": window, "marker": marker,
                "document_path": str(document), "baseline": text,
                "task": {"goal": "scroll down", "app": "com.apple.TextEdit", "window_id": window["window_id"]},
                "driver_reply": {"structuredContent": capture.scoped_elements(state)},
                "apps": {"structuredContent": {"apps": apps}},
                "windows": {"structuredContent": {"windows": windows}},
            })
            environment = dict(os.environ, JEV_NATIVE_CHOICE_INPUT=str(input_file),
                               JEV_NATIVE_CHOICE_API_KEY=real.require_api_key())
            command = ["scripts/verification-lane.sh", "c1-chooser-release-tests",
                       "JevNativeChoiceDiagnosticTests.testOwnedWindowReadOnlyDecisionCapture", "--skip-build"]
            with (output / "diagnostic.log").open("x") as log:
                metadata["test_exit"] = subprocess.run(command, cwd=ROOT, env=environment,
                    stdout=log, stderr=subprocess.STDOUT).returncode
            metadata["content_unchanged"] = scroll.body(document) == text
            assert metadata["content_unchanged"]
    except Exception as error:
        metadata["harness_exit"] = type(error).__name__
    finally:
        if opened and scroll.body(document) == text:
            scroll.apple('tell application "TextEdit" to close (first document whose path is '
                         + json.dumps(str(document)) + ') saving no')
        metadata["documents_after"] = cleanup.inventory()[0]
        metadata["documents_restored"] = metadata["documents_after"] == count
        body = output / "request-0.json"
        if body.exists():
            data = body.read_bytes()
            request = json.loads(data)
            if not {"state", "questions"}.issubset(request):
                raise RuntimeError("Unexpected request shape")
            metadata.update(captured=True, bytes=len(data),
                            body_sha256=hashlib.sha256(data).hexdigest(),
                            question_count=len(request["questions"]))
        (output / "receipt.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(metadata, indent=2))
    return 0 if metadata["captured"] and metadata["documents_restored"] else 1


if __name__ == "__main__":
    sys.exit(main())
