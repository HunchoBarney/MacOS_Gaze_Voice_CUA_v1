import argparse
import base64
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import tempfile
import uuid


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_fixture_shared", HERE / "jev-native-choice-capture.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def seal_fixture(bundle, out, real):
    def manifest(root):
        if any(path.is_symlink() for path in root.rglob("*")):
            raise RuntimeError("unexpected fixture symlink")
        return {str(path.relative_to(root)): (real.digest(path), stat.S_IMODE(path.stat().st_mode))
                for path in root.rglob("*") if path.is_file()}

    def run(name, command):
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        (out / (name + ".log")).write_text(result.stdout + result.stderr)
        real.write_json(out / "setup.json", dict(qualification=False, fixture_started=False,
            stage=name, passed=result.returncode == 0, return_code=result.returncode))
        if result.returncode:
            raise RuntimeError("native fixture " + name + " failed")

    before = manifest(bundle)
    with tempfile.TemporaryDirectory(prefix="jev-native-ui-signature-") as temporary:
        clean = Path(temporary) / bundle.name
        run("verify-copy", ["ditto", "--norsrc", "--noextattr", "--noqtn", str(bundle), str(clean)])
        if manifest(clean) != before:
            raise RuntimeError("fixture unsigned-copy bytes or modes differ")
        run("sign", ["codesign", "--force", "--sign", "-", str(clean)])
        run("verify", ["codesign", "--verify", "--deep", "--strict", str(clean)])
        sealed = manifest(clean)
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        allowed = {"Contents/MacOS/" + info["CFBundleExecutable"], "Contents/_CodeSignature/CodeResources"}
        changed = {name for name in before.keys() | sealed.keys() if before.get(name) != sealed.get(name)}
        if not changed <= allowed:
            raise RuntimeError("fixture signing changed non-signature payload")
        run("retain-copy", ["ditto", "--norsrc", "--noextattr", "--noqtn", str(clean), str(bundle)])
        if manifest(bundle) != sealed:
            raise RuntimeError("retained fixture differs from verified signed copy")
        real.write_json(out / "signature-copy.json", dict(qualification=False,
            signed_outside_synced_tree=True, exact_file_mode_match=True, files=len(sealed), verified=True,
            reason="Sign and verify a clean copy; retain identical sealed bytes and modes in the workspace."))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_REAL_APPS") != "approved":
        raise SystemExit("owned native fixture approval required")
    real = SHARED.load("native_fixture_real", "jev-realapps.py")
    out = SHARED.private_output(args.out)
    source = HERE / "jev-native-ui-fixture.swift"
    bundle = out / "Native UI Fixture.app"
    binary = bundle / "Contents/MacOS/NativeUIFixture"
    binary.parent.mkdir(parents=True)
    bundle_id = "dev.jevvoice.native-ui-outcome-fixture"
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle_id, "CFBundleExecutable": binary.name,
        "CFBundleName": "Jev Native UI Test", "CFBundlePackageType": "APPL",
        "NSHighResolutionCapable": True,
    }))
    result = subprocess.run(["xcrun", "swiftc", str(source), "-o", str(binary)],
                            capture_output=True, text=True, timeout=120)
    (out / "compile.log").write_text(result.stdout + result.stderr)
    real.write_json(out / "setup.json", dict(qualification=False, fixture_started=False,
        stage="compile", passed=result.returncode == 0, return_code=result.returncode))
    if result.returncode:
        raise RuntimeError("native fixture compile failed")
    seal_fixture(bundle, out, real)
    nonce = str(uuid.uuid4())
    report = dict(qualification=False, ai="stubbed typed answers", input_actuations=0,
                  image="owned AppKit content-view raster, not driver capture",
                  source_sha256=real.digest(source), binary_sha256=real.digest(binary))
    with (out / "fixture-process.log").open("w") as log:
        process = subprocess.Popen([str(binary), str(out), nonce], stdout=log, stderr=log)
        try:
            def ready():
                try:
                    journal = json.loads((out / "journal.json").read_text())
                    return journal if (journal.get("pid") == process.pid
                                       and journal.get("nonce") == nonce
                                       and (out / "fixture.png").is_file()) else None
                except (FileNotFoundError, json.JSONDecodeError):
                    return None
            journal = real.wait_for(ready, 8, "owned native fixture not ready")
            state = dict(pid=process.pid, window_id=journal["window_id"],
                         capture_id="fixture-source", snapshot_id="fixture-source",
                         screenshot_frame_valid=True, window_bounds=journal["bounds"],
                         screenshot_width=journal["width"], screenshot_height=journal["height"])
            fixture = dict(bundle_id=bundle_id, binary=str(binary),
                           binary_sha256=report["binary_sha256"], nonce=nonce,
                           command=str(out / "command.json"), journal=str(out / "journal.json"))
            path = out / "input.json"
            real.write_json(path, dict(qualification=False, fixture=fixture, expected_display="7",
                window=dict(pid=process.pid, window_id=journal["window_id"]),
                task=dict(goal="Calculate 3 plus 4 and show the result."),
                session="native-ui-fixture-" + nonce, daemon_socket="/native-ui-test/no-driver.sock",
                driver_reply=state, image_content=[dict(type="image", mimeType="image/png",
                    data=base64.b64encode((out / "fixture.png").read_bytes()).decode())]))
            environment = dict(os.environ, JEV_CALCULATOR_CHOICE_INPUT=str(path))
            tests = subprocess.run([
                "swift", "test", "--skip-build", "--filter",
                "JevNativeChoiceDiagnosticTests.testReadOnlyNativeValueAdmissionAndFreshIdentity"
                "|JevNativeChoiceDiagnosticTests.testDerivedNativeOutcomeUsesFreshExactEvidence",
            ], cwd=HERE.parents[2], env=environment, capture_output=True, text=True, timeout=60)
            (out / "tests.log").write_text(tests.stdout + tests.stderr)
            report["passed"] = tests.returncode == 0
        finally:
            real.write_json(out / "command.json", dict(nonce=nonce, operation="quit"))
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
            report["resources_clean"] = process.poll() is not None
            real.write_json(out / "receipt.json", report)
    if not report.get("passed") or not report["resources_clean"]:
        raise RuntimeError("native fixture regression failed; inspect retained tests.log")


if __name__ == "__main__":
    main()
