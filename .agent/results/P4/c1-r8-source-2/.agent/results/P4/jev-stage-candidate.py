import argparse
import ctypes
import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
ROLLBACK_SHA = "f6abbe98113d7f9362ab98bc48a32e1fa94df6ddb3b376ab27dc56939fa4adf1"


def helper():
    spec = importlib.util.spec_from_file_location("c1_existing_stage", HERE / "jev-clone-stage.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(arguments, timeout=60):
    return subprocess.run(arguments, cwd=ROOT, capture_output=True, text=True,
                          check=True, timeout=timeout)


def source_identity(stage):
    result = stage.sources()
    result["Package.resolved"] = stage.digest(ROOT / "Package.resolved")
    return result


def clone_file(source, destination):
    clone = ctypes.CDLL(None, use_errno=True).clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    if clone(os.fsencode(source), os.fsencode(destination), 1) != 0:
        raise OSError(ctypes.get_errno(), "APFS clone failed")
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", choices=("before", "after", "after-r2", "after-r3", "final", "final-r2", "final-r3", "final-r4", "final-r5", "final-r6", "final-r7", "final-r8"), required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_VERIFICATION_LANE_HELD") != "1":
        raise RuntimeError("Run through scripts/verification-lane.sh p4-stage-candidate")
    stage = helper()
    snapshot = json.loads(args.snapshot.read_text())
    expected = {name: digest for name, digest in snapshot["source_sha256"].items()
                if name.startswith("Sources/") or name in
                ("Info.plist", "Package.swift", "Package.resolved")}
    if not expected or source_identity(stage) != expected:
        raise RuntimeError("Current build inputs differ from the frozen source")
    executable = ROOT / ".build/release/JevVoice"
    rollback = Path.home() / "jarvis-local/Jev Voice.app"
    original_main = rollback / "Contents/MacOS/JevVoice"
    if stage.digest(original_main) != ROLLBACK_SHA:
        raise RuntimeError("Daily rollback differs from the approved identity")
    run(["codesign", "--verify", "--deep", "--strict", str(rollback)])
    original_resources = stage.resources(rollback)
    original_info = stage.digest(rollback / "Contents/Info.plist")
    original_requirement = stage.requirement(rollback)
    original_signing = stage.signing_metadata(rollback)
    identities = run(["security", "find-identity", "-v", "-p", "codesigning"]).stdout
    if '"Jev Voice Local Dev"' not in identities:
        raise RuntimeError("The existing stable signing identity is unavailable")
    pins_path = ROOT / "ThirdParty/Cua/source-manifest.json"
    pin_hash = stage.digest(pins_path)
    pins = json.loads(pins_path.read_text())["vendored_binaries"]
    if pins["cua-driver"]["version"] != "0.38.0":
        raise RuntimeError("C1 staging has not admitted a different driver generation")
    driver = ROOT / "build/vendor/cua-driver"
    codex = ROOT / "build/vendor/CodexRuntime/codex"
    for name, path in (("cua-driver", driver), ("codex", codex)):
        if stage.digest(path) != pins[name]["sha256"]:
            raise RuntimeError(f"Canonical {name} differs from its source pin")
    output = ROOT / f".agent/results/P12/c1-{args.label}-stage.json"
    if output.exists():
        raise FileExistsError(output)
    unsigned_main = stage.digest(executable)
    candidate_root = Path.home() / "jarvis-local/c1-candidates"
    candidate_root.mkdir(mode=0o700, exist_ok=True)
    info = candidate_root.lstat()
    if (candidate_root.is_symlink() or not candidate_root.is_dir()
            or info.st_uid != os.getuid() or info.st_mode & 0o777 != 0o700):
        raise RuntimeError("Candidate storage must be a private owned directory")
    parent = Path(tempfile.mkdtemp(prefix=f"jev-c1-{args.label}-", dir=candidate_root))
    parent.chmod(0o700)
    app = parent / "Jev Voice.app"
    shutil.copytree(rollback, app, symlinks=True, copy_function=clone_file)
    shutil.copyfile(executable, app / "Contents/MacOS/JevVoice")
    shutil.copyfile(ROOT / "Info.plist", app / "Contents/Info.plist")
    shutil.copyfile(driver, app / "Contents/Resources/cua-driver")
    shutil.copyfile(codex, app / "Contents/Resources/CodexRuntime/codex")
    if args.label.startswith("final"):
        fluid = ROOT / ".build/checkouts/FluidAudio"
        pin = next(p for p in json.loads((ROOT / "Package.resolved").read_text())["pins"]
                   if p["identity"].lower() == "fluidaudio")
        if run(["git", "-C", str(fluid), "rev-parse", "HEAD"]).stdout.strip() != pin["state"]["revision"]:
            raise RuntimeError("Speech license checkout differs from the resolved dependency")
        license_bytes = subprocess.check_output(
            ["git", "-C", str(fluid), "show", pin["state"]["revision"] + ":LICENSE"], timeout=20)
        if (fluid / "LICENSE").read_bytes() != license_bytes:
            raise RuntimeError("Speech package license differs from its resolved revision")
        destination = app / "Contents/Resources/ThirdParty/FluidAudio"
        destination.mkdir()
        shutil.copyfile(fluid / "LICENSE", destination / "LICENSE")
        shutil.copytree(fluid / "ThirdPartyLicenses", destination / "ThirdPartyLicenses")
        shutil.copyfile(ROOT / ".agent/results/P12/speech-attribution.md", destination / "NOTICE.md")
    if args.label == "final-r8":
        run(["python3", "scripts/bundle-conversation-vad.py", "--app", str(app)], timeout=600)
    signed = run(["scripts/sign-app.sh", str(app)], timeout=600)
    signature = run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if stage.requirement(app) != original_requirement or stage.signing_metadata(app) != original_signing:
        raise RuntimeError("The candidate changed the stable app signing identity or entitlements")
    if (source_identity(stage) != expected or stage.digest(executable) != unsigned_main
            or stage.digest(pins_path) != pin_hash):
        raise RuntimeError("Build inputs changed during staging")
    if (stage.digest(original_main) != ROLLBACK_SHA
            or stage.digest(rollback / "Contents/Info.plist") != original_info
            or stage.resources(rollback) != original_resources):
        raise RuntimeError("Rollback identity changed during staging")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    signed_driver = stage.digest(app / "Contents/Resources/cua-driver")
    if info.get("JevCuaDriverSHA256") != signed_driver or info.get("JevExperimentalWindowImages", False):
        raise RuntimeError("Generated driver identity or image-mode policy is incoherent")
    version = run([str(app / "Contents/Resources/cua-driver"), "--version"]).stdout.strip()
    if version != "cua-driver 0.38.0":
        raise RuntimeError("Signed driver reports an unexpected generation")
    resources = stage.resources(app)
    receipt = {
        "schema_version": 1, "label": args.label, "app": str(app),
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "binary_sha256": stage.digest(app / "Contents/MacOS/JevVoice"),
        "unsigned_main_sha256": unsigned_main,
        "source_sha256": expected,
        "source_snapshot": str(args.snapshot.resolve()),
        "source_snapshot_sha256": stage.digest(args.snapshot),
        "staging_helper_sha256": stage.digest(Path(__file__)),
        "signing_helper_sha256": stage.digest(ROOT / "scripts/sign-app.sh"),
        "resource_helper_sha256": stage.digest(ROOT / ".agent/results/P12/c1_manifest.py"),
        "conversation_resource_receipt_sha256": stage.digest(ROOT / ".agent/results/P12/c1-r2-vad-resource.json"),
        "conversation_resource_helper_sha256": stage.digest(ROOT / "scripts/bundle-conversation-vad.py"),
        "rollback_app": str(rollback), "rollback_sha256": ROLLBACK_SHA,
        "rollback_unchanged": True, "installed": False, "strict_signature": True,
        "unchanged_designated_requirement": True,
        "signing_metadata": original_signing, "designated_requirement": original_requirement,
        "canonical_pin_sha256": pin_hash,
        "driver": {"version": pins["cua-driver"]["version"],
                   "canonical_sha256": pins["cua-driver"]["sha256"], "signed_sha256": signed_driver,
                   "signed_matches_rollback": signed_driver == original_resources["cua-driver"]["sha256"]},
        "codex": {"version": pins["codex"]["version"], "canonical_sha256": pins["codex"]["sha256"],
                  "signed_sha256": stage.digest(app / "Contents/Resources/CodexRuntime/codex")},
        "experimental_window_images": False, "resource_manifest": resources,
        "generated_info_sha256": stage.digest(app / "Contents/Info.plist"),
        "signature_output": signature.stdout + signature.stderr,
        "signing_output": signed.stdout + signed.stderr,
        "physical_input_verified": False, "release_preflight_verified": False,
    }
    with output.open("x") as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(json.dumps({"receipt": str(output), "app": str(app), "binary_sha256": receipt["binary_sha256"],
                      "strict_signature": True, "installed": False,
                      "driver_matches_rollback": receipt["driver"]["signed_matches_rollback"]}))


if __name__ == "__main__":
    main()
