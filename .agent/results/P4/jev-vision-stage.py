import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import uuid


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent


def helpers(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_frozen_payload(before, after):
    allowed = {"Contents/MacOS/JevVoice", "Contents/_CodeSignature/CodeResources"}
    if before.keys() != after.keys():
        raise RuntimeError("frozen_template_payload_changed")
    for name, row in before.items():
        current = after[name]
        if name in allowed and row.get("kind") == current.get("kind") == "file":
            row = {key: value for key, value in row.items() if key != "sha256"}
            current = {key: value for key, value in current.items() if key != "sha256"}
        if row != current:
            raise RuntimeError("frozen_template_payload_changed")


def root_signing_arguments(app, flags, entitlements):
    options = hex(int(flags.split("(")[0], 16))
    command = ["codesign", "--force", "--sign", "Jev Voice Local Dev",
               "--options", options, "--timestamp=none"]
    if entitlements is not None:
        command += ["--entitlements", str(entitlements)]
    return [*command, str(app)]


def verify_frozen_source(expected, current, delta):
    helpers("frozen_realapps", "jev-realapps.py").verify_source_subject(
        expected, current, approved_delta=delta)


def frozen_stage(args, native, before):
    archive = helpers("frozen_archive", "jev-archive-signed-pairs.py")
    clone = helpers("frozen_clone", "jev-clone-stage.py")
    qualification = helpers("frozen_qualification", "jev-vision-qualification.py")
    baseline = json.loads(args.baseline_receipt.read_text())
    delta = qualification.load_reviewed_source_delta(args.reviewed_source_delta)
    if set(baseline["candidates"]) != {"before", "after"}:
        raise RuntimeError("frozen_baseline_variants_unverified")
    workspace = Path(native["candidate_driver"]["path"]).resolve().parents[3]
    if workspace.name != "JevVoice" or not args.out.resolve().is_relative_to(workspace):
        raise RuntimeError("frozen_stage_output_outside_workspace")
    verified = []
    for label, subject in (("before", "baseline_driver"), ("after", "candidate_driver")):
        row = baseline["candidates"][label]
        base = Path(row["app"])
        if (base.is_symlink() or not base.parent.name.startswith("jev-vision-ab-")
                or base.parent.stat().st_uid != os.getuid()
                or base.name != label + ".app"):
            raise RuntimeError("frozen_baseline_owner_unverified")
        verify_frozen_source(row["source_sha256"], before, delta)
        if (digest(base / "Contents/MacOS/JevVoice") != row["binary_sha256"]
                or digest(base / "Contents/Resources/cua-driver") != row["driver_sha256"]
                or row["unsigned_driver_sha256"] != native[subject]["sha256"]):
            raise RuntimeError("frozen_baseline_binary_unverified")
        info = plistlib.loads((base / "Contents/Info.plist").read_bytes())
        if (info.get("JevCuaDriverSHA256") != row["driver_sha256"]
                or info.get("JevExperimentalWindowImages", False) is not args.enable_window_images):
            raise RuntimeError("frozen_baseline_info_unverified")
        run(["codesign", "--verify", "--deep", "--strict", str(base)], timeout=60)
        entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(base)],
                                     capture_output=True, check=True, timeout=20).stdout
        if entitlements:
            plistlib.loads(entitlements)
        verified.append((label, row, base, archive.manifest(base),
                         clone.signing_metadata(base), clone.requirement(base), entitlements))
    run(["swift", "build", "-c", "release", "--disable-automatic-resolution", "--jobs", "2"], timeout=900)
    if source_snapshot() != before:
        raise RuntimeError("frozen_source_changed_during_build")
    args.out.mkdir(mode=0o700)
    directory = Path(tempfile.mkdtemp(prefix="jev-vision-ab-frozen-"))
    binary = ROOT / ".build/release/JevVoice"
    unsigned_main = digest(binary)
    rows = {}
    for label, row, base, original, signing, requirement, entitlements in verified:
        app = directory / (label + ".app")
        archive.clone(base, app)
        replacement = app / "Contents/MacOS/JevVoice.candidate"
        shutil.copy2(binary, replacement)
        os.replace(replacement, app / "Contents/MacOS/JevVoice")
        run(["xattr", "-c", str(app / "Contents/MacOS/JevVoice")], timeout=20)
        entitlement_path = None
        if entitlements:
            entitlement_path = args.out / (label + "-entitlements.plist")
            entitlement_path.write_bytes(entitlements)
        run(root_signing_arguments(app, signing["flags"], entitlement_path), timeout=120)
        run(["codesign", "--verify", "--deep", "--strict", str(app)], timeout=60)
        current = archive.manifest(app)
        assert_frozen_payload(original, current)
        if clone.signing_metadata(app) != signing or clone.requirement(app) != requirement:
            raise RuntimeError("frozen_signing_metadata_changed")
        if digest(app / "Contents/Resources/cua-driver") != row["driver_sha256"]:
            raise RuntimeError("frozen_driver_changed")
        retained = args.out / (label + ".app")
        archive.clone(app, retained)
        if archive.manifest(retained) != current:
            raise RuntimeError("frozen_workspace_copy_changed")
        archive.write(args.out / (label + "-baseline-manifest.json"), original)
        archive.write(args.out / (label + "-manifest.json"), current)
        rows[label] = {
            "app": str(retained.resolve()), "workspace_app": str(retained.resolve()),
            "binary_sha256": digest(app / "Contents/MacOS/JevVoice"),
            "unsigned_main_sha256": unsigned_main, "driver_sha256": row["driver_sha256"],
            "unsigned_driver_sha256": row["unsigned_driver_sha256"],
            "code_resources_sha256": digest(app / "Contents/_CodeSignature/CodeResources"),
            "manifest_sha256": digest(args.out / (label + "-manifest.json")),
            "manifest_path": str((args.out / (label + "-manifest.json")).resolve()),
            "baseline_manifest_sha256": digest(args.out / (label + "-baseline-manifest.json")),
            "signing_metadata": signing, "designated_requirement": requirement,
            "source_sha256": before, "strict_signature": True,
            "frozen_payload_verified": True, "workspace_manifest_equals_runtime": True,
            "experimental_window_images": args.enable_window_images,
            "installed": False, "launched": False,
        }
    if source_snapshot() != before or digest(binary) != unsigned_main:
        raise RuntimeError("frozen_source_or_binary_changed")
    for _, _, base, original, _, _, _ in verified:
        if archive.manifest(base) != original:
            raise RuntimeError("frozen_baseline_changed")
    for subject in ("candidate_driver", "baseline_driver"):
        if digest(native[subject]["path"]) != native[subject]["sha256"]:
            raise RuntimeError("frozen_native_artifact_changed")
    receipt = args.out / "stage-receipt.json"
    archive.write(receipt, {
        "subject": "reviewed Swift-only change; original nested runtime bytes and signing policy frozen",
        "native_receipt": str(args.native_receipt.resolve()),
        "native_receipt_sha256": digest(args.native_receipt),
        "baseline_receipt": str(args.baseline_receipt.resolve()),
        "baseline_receipt_sha256": digest(args.baseline_receipt),
        "reviewed_source_delta": str(args.reviewed_source_delta.resolve()),
        "reviewed_source_delta_sha256": digest(args.reviewed_source_delta),
        "candidates": rows,
        "limitations": ["Local development signature, not release qualification.",
                        "Temporary signing/runtime copies outside synced tree match retained workspace builds.",
                        "No desktop launch, physical Fn, real-app behavior or speed proof."],
    })
    shutil.rmtree(directory)
    print(receipt)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def source_snapshot():
    paths = [*ROOT.joinpath("Sources").rglob("*.swift"), ROOT / "Info.plist", ROOT / "Package.swift"]
    return {str(path.relative_to(ROOT)): digest(path) for path in paths}


def run(arguments, **kwargs):
    subprocess.run(arguments, cwd=ROOT, check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("native_receipt", type=Path)
    parser.add_argument("--enable-window-images", action="store_true")
    parser.add_argument("--baseline-receipt", type=Path)
    parser.add_argument("--reviewed-source-delta", type=Path)
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    frozen = (args.baseline_receipt, args.reviewed_source_delta, args.out)
    if any(value is not None for value in frozen) and not all(value is not None for value in frozen):
        parser.error("frozen staging requires --baseline-receipt, --reviewed-source-delta and --out")
    native = json.loads(args.native_receipt.read_text())
    if native.get("source_review") != "PASS":
        raise SystemExit("BLOCKED: independent source review must pass first")
    for subject in ("candidate_driver", "baseline_driver"):
        entry = native[subject]
        if digest(entry["path"]) != entry["sha256"]:
            raise SystemExit("BLOCKED: native artifact changed")
    for relative, expected in native["app_source_sha256"].items():
        if digest(ROOT / relative) != expected:
            raise SystemExit("BLOCKED: reviewed app source changed")
    notices = native["driver_notices"]
    if digest(notices["path"]) != notices["sha256"]:
        raise SystemExit("BLOCKED: exact driver dependency notices changed")
    pins = json.loads((ROOT / "ThirdParty/Cua/source-manifest.json").read_text())["vendored_binaries"]
    for name, path in (("cua-driver", ROOT / "build/vendor/cua-driver"),
                       ("codex", ROOT / "build/vendor/CodexRuntime/codex")):
        if digest(path) != pins[name]["sha256"]:
            raise SystemExit("BLOCKED: cached vendor differs; no download attempted")
    identities = subprocess.run(["security", "find-identity", "-v", "-p", "codesigning"],
                                capture_output=True, text=True, check=True, timeout=20)
    if '"Jev Voice Local Dev"' not in identities.stdout:
        raise SystemExit("BLOCKED: existing signing identity required; no identity will be minted")
    before = source_snapshot()
    if args.baseline_receipt:
        frozen_stage(args, native, before)
        return
    run(["swift", "build", "-c", "release", "--disable-automatic-resolution", "--jobs", "2"], timeout=900)
    directory = Path(tempfile.mkdtemp(prefix="jev-vision-ab-"))
    template = directory / "Template.app"
    run(["make", "-o", "build", "-o", "vendor", "stage", "STAGE_APP=" + str(template)], timeout=900)
    if args.enable_window_images:
        info_path = template / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        info["JevExperimentalWindowImages"] = True
        info_path.write_bytes(plistlib.dumps(info))
    rows = {}
    for label, subject in (("before", "baseline_driver"), ("after", "candidate_driver")):
        app = directory / (label + ".app")
        run(["cp", "-cR", str(template), str(app)], timeout=180)
        target = app / "Contents/Resources/cua-driver"
        replacement = target.with_suffix(".candidate")
        shutil.copy2(native[subject]["path"], replacement)
        os.replace(replacement, target)
        shutil.copy2(notices["path"],
                     app / "Contents/Resources/ThirdParty/CuaDriver/THIRD_PARTY_NOTICES.md")
        run(["scripts/sign-app.sh", str(app)], timeout=180)
        run(["codesign", "--verify", "--deep", "--strict", str(app)], timeout=60)
        rows[label] = {
            "app": str(app), "binary_sha256": digest(app / "Contents/MacOS/JevVoice"),
            "driver_sha256": digest(target), "unsigned_driver_sha256": native[subject]["sha256"],
            "source_sha256": before, "installed": False, "launched": False,
            "strict_signature": True,
            "experimental_window_images": args.enable_window_images,
        }
    if source_snapshot() != before:
        raise SystemExit("BLOCKED: app source changed during staging")
    for subject in ("candidate_driver", "baseline_driver"):
        if digest(native[subject]["path"]) != native[subject]["sha256"]:
            raise SystemExit("BLOCKED: native artifact changed during staging")
    output = HERE / ("jev-vision-stage-" + uuid.uuid4().hex + ".json")
    with output.open("x") as handle:
        json.dump({
            "subject": "same Swift source and release build, coordinate-v1 vs captured-native-v2",
            "native_receipt": str(args.native_receipt.resolve()),
            "native_receipt_sha256": digest(args.native_receipt), "candidates": rows,
            "limitations": ["Local development signature only, not notarized release qualification.",
                            "No desktop launch, physical Fn, real-app behavior or speed proof."],
        }, handle, indent=2)
        handle.write("\n")
    print(output)


if __name__ == "__main__":
    main()
