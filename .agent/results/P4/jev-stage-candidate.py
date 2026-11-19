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
DAILY_APP = Path.home() / "jarvis-local/Jev Voice.app"
RETAINED_BASE_APP = Path.home() / "jarvis-local/c1-candidates/jev-c1-final-r9-2-ksh975zx/Jev Voice.app"
RETAINED_BASE_RECEIPT = ROOT / ".agent/results/P12/c1-final-r9-2-stage.json"
RETAINED_BASE_RECEIPT_SHA = "972d1ce3cfc04f0d3ef8c101c1cabfe377ee223b2aae0c93e98f35e76e6714f0"
RETAINED_BASE_SHA = "79e8859b32d849e2777c741cefec099123cae9e18a6d081de8bab440cabb276b"
RETEST = "final-first-minute-1"
GAZE = "final-gaze-quiet-1"
RETEST_LABELS = (RETEST, "final-spaces-diagnostic-1", "final-first-minute-quiet-1", GAZE)


def tracker_overlay():
    spec = importlib.util.spec_from_file_location("c1_tracker_overlay", HERE.parent / "P12/c1_tracker_overlay.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


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


def retained_base_metadata():
    return {
        "rollback_role": "last_verified_candidate",
        "rollback_app": str(RETAINED_BASE_APP), "rollback_sha256": RETAINED_BASE_SHA,
        "base_receipt": str(RETAINED_BASE_RECEIPT),
        "base_receipt_sha256": RETAINED_BASE_RECEIPT_SHA,
        "historical_daily": {"app": str(DAILY_APP), "binary_sha256": ROLLBACK_SHA, "status": "missing"},
    }


def verify_retained_base(stage, label, metadata=None):
    if label not in ("final-r10", *RETEST_LABELS):
        raise RuntimeError("The retained base is admitted only final-r10 or a reviewed retest label")
    if os.path.lexists(DAILY_APP):
        raise RuntimeError("The original daily path must be absent, not partial or a symlink")
    expected = retained_base_metadata()
    if metadata is not None and any(metadata.get(key) != value for key, value in expected.items()):
        raise RuntimeError("The retained base provenance changed")
    if stage.digest(RETAINED_BASE_RECEIPT) != RETAINED_BASE_RECEIPT_SHA:
        raise RuntimeError("The retained receipt identity changed")
    receipt = json.loads(RETAINED_BASE_RECEIPT.read_text())
    if Path(receipt["app"]) != RETAINED_BASE_APP or RETAINED_BASE_APP.resolve() != RETAINED_BASE_APP:
        raise RuntimeError("The retained app identity changed")
    parent = RETAINED_BASE_APP.parent.lstat()
    if parent.st_uid != os.getuid() or parent.st_mode & 0o777 != 0o700:
        raise RuntimeError("The retained app parent must remain private and owned")
    if (receipt["binary_sha256"] != RETAINED_BASE_SHA
            or stage.digest(RETAINED_BASE_APP / "Contents/MacOS/JevVoice") != RETAINED_BASE_SHA):
        raise RuntimeError("The retained binary identity changed")
    if (stage.resources(RETAINED_BASE_APP) != receipt["resource_manifest"]
            or stage.digest(RETAINED_BASE_APP / "Contents/Info.plist") != receipt["generated_info_sha256"]
            or stage.requirement(RETAINED_BASE_APP) != receipt["designated_requirement"]
            or stage.signing_metadata(RETAINED_BASE_APP) != receipt["signing_metadata"]
            or stage.digest(Path(receipt["source_snapshot"])) != receipt["source_snapshot_sha256"]):
        raise RuntimeError("The retained app resource, signing or source identity changed")
    run(["codesign", "--verify", "--deep", "--strict", str(RETAINED_BASE_APP)], timeout=120)
    return expected


def choose_base(stage, label, use_retained):
    if label in RETEST_LABELS and not use_retained:
        raise RuntimeError("The first-minute retest requires the pinned retained base")
    if use_retained:
        metadata = verify_retained_base(stage, label)
        return RETAINED_BASE_APP, RETAINED_BASE_SHA, metadata
    if stage.digest(DAILY_APP / "Contents/MacOS/JevVoice") != ROLLBACK_SHA:
        raise RuntimeError("Daily rollback differs from the approved identity")
    return DAILY_APP, ROLLBACK_SHA, {"rollback_role": "original_daily"}


def reserve_retest(root, receipt, component, label=RETEST):
    if label not in RETEST_LABELS:
        raise RuntimeError("Unknown retest label")
    for path in (receipt, component):
        if os.path.lexists(path):
            raise FileExistsError(path)
    parent = root / f"jev-c1-{label}"
    parent.mkdir(mode=0o700)
    return parent


def verify_retest_release(snapshot, unsigned, label=RETEST):
    if label not in RETEST_LABELS or snapshot.get("label") != label or snapshot.get("built_unsigned_main_sha256") != unsigned:
        raise RuntimeError("The release executable does not match its first-minute source freeze")


def clone_file(source, destination):
    clone = ctypes.CDLL(None, use_errno=True).clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    if clone(os.fsencode(source), os.fsencode(destination), 1) != 0:
        raise OSError(ctypes.get_errno(), "APFS clone failed")
    return destination


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", choices=("before", "after", "after-r2", "after-r3", "final", "final-r2", "final-r3", "final-r4", "final-r5", "final-r6", "final-r7", "final-r8", "final-r9", "final-r9-2", "final-r10", *RETEST_LABELS), required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--retained-base", action="store_true")
    args = parser.parse_args()
    if os.environ.get("JARVIS_VERIFICATION_LANE_HELD") != "1":
        raise RuntimeError("Run through scripts/verification-lane.sh p4-stage-candidate")
    stage = helper()
    snapshot_hash = stage.digest(args.snapshot)
    snapshot = json.loads(args.snapshot.read_text())
    if (snapshot.get("label") == GAZE) != (args.label == GAZE):
        raise RuntimeError("Gaze release freeze cannot be relabelled")
    expected = {name: digest for name, digest in snapshot["source_sha256"].items()
                if name.startswith("Sources/") or name in
                ("Info.plist", "Package.swift", "Package.resolved")}
    if not expected or source_identity(stage) != expected:
        raise RuntimeError("Current build inputs differ from the frozen source")
    executable = ROOT / ".build/release/JevVoice"
    gaze = args.label == GAZE
    if gaze:
        overlay = tracker_overlay()
        overlay.verify_freeze(stage, args.snapshot, snapshot, ROOT)
    rollback, rollback_sha, base_metadata = choose_base(stage, args.label, args.retained_base)
    original_main = rollback / "Contents/MacOS/JevVoice"
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
    if gaze:
        base_receipt = overlay.retained_receipt(RETAINED_BASE_RECEIPT, RETAINED_BASE_RECEIPT_SHA, RETAINED_BASE_SHA)
        overlay.verify_tools(base_receipt, pin_hash, pins, base_receipt["driver"], base_receipt["codex"],
                             expected, ROOT / "Sources/JevVoice/ComputerControl/CuaDependency.swift", original_resources)
    candidate_root = Path.home() / "jarvis-local/c1-candidates"
    candidate_root.mkdir(mode=0o700, exist_ok=True)
    info = candidate_root.lstat()
    if (candidate_root.is_symlink() or not candidate_root.is_dir()
            or info.st_uid != os.getuid() or info.st_mode & 0o777 != 0o700):
        raise RuntimeError("Candidate storage must be a private owned directory")
    if args.label in RETEST_LABELS:
        verify_retest_release(snapshot, unsigned_main, args.label)
        parent = reserve_retest(candidate_root, output, output.with_name(f"c1-manifest-{args.label}.json"), args.label)
    else:
        parent = Path(tempfile.mkdtemp(prefix=f"jev-c1-{args.label}-", dir=candidate_root))
    parent.chmod(0o700)
    app = parent / "Jev Voice.app"
    shutil.copytree(rollback, app, symlinks=True, copy_function=clone_file)
    shutil.copyfile(executable, app / "Contents/MacOS/JevVoice")
    shutil.copyfile(ROOT / "Info.plist", app / "Contents/Info.plist")
    if not gaze:
        shutil.copyfile(driver, app / "Contents/Resources/cua-driver")
        shutil.copyfile(codex, app / "Contents/Resources/CodexRuntime/codex")
    if args.label.startswith("final") and not gaze:
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
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.resolve().is_relative_to(app.resolve()):
                raise RuntimeError("Unexpected speech notice location")
            shutil.rmtree(destination)
        destination.mkdir()
        shutil.copyfile(fluid / "LICENSE", destination / "LICENSE")
        shutil.copytree(fluid / "ThirdPartyLicenses", destination / "ThirdPartyLicenses")
        shutil.copyfile(ROOT / ".agent/results/P12/speech-attribution.md", destination / "NOTICE.md")
    if args.label == "final-r8":
        run(["python3", "scripts/bundle-conversation-vad.py", "--app", str(app)], timeout=600)
    if gaze:
        overlay.apply_overlay(stage, app, args.snapshot, snapshot, ROOT, base_receipt["resource_manifest"])
        if stage.digest(app / "Contents/MacOS/JevVoice") != unsigned_main:
            raise RuntimeError("Cloned app does not contain the attested unsigned release")
        info_path = app / "Contents/Info.plist"
        info = plistlib.loads(info_path.read_bytes())
        if info.get("JevVoiceInputProvider") != "openai-realtime":
            raise RuntimeError("Gaze candidate must not depend on local speech assets")
        info["JevCuaDriverSHA256"] = base_receipt["driver"]["signed_sha256"]
        info_path.write_bytes(plistlib.dumps(info))
        signed = run(["/usr/bin/codesign", "--force", "--sign", "f8aeb104eed4b249fe9869c0fa2d328b643dbb21",
                      str(app)], timeout=600)
    else:
        signed = run(["scripts/sign-app.sh", str(app)] + (["--existing-only"] if args.label in RETEST_LABELS else []), timeout=600)
    signature = run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if stage.requirement(app) != original_requirement or stage.signing_metadata(app) != original_signing:
        raise RuntimeError("The candidate changed the stable app signing identity or entitlements")
    if (source_identity(stage) != expected or stage.digest(executable) != unsigned_main
            or stage.digest(pins_path) != pin_hash or stage.digest(args.snapshot) != snapshot_hash):
        raise RuntimeError("Build inputs changed during staging")
    if (stage.digest(original_main) != rollback_sha
            or stage.digest(rollback / "Contents/Info.plist") != original_info
            or stage.resources(rollback) != original_resources):
        raise RuntimeError("Rollback identity changed during staging")
    if args.retained_base:
        verify_retained_base(stage, args.label, base_metadata)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    signed_driver = stage.digest(app / "Contents/Resources/cua-driver")
    if info.get("JevCuaDriverSHA256") != signed_driver or info.get("JevExperimentalWindowImages", False):
        raise RuntimeError("Generated driver identity or image-mode policy is incoherent")
    version = run([str(app / "Contents/Resources/cua-driver"), "--version"]).stdout.strip()
    if version != "cua-driver 0.38.0":
        raise RuntimeError("Signed driver reports an unexpected generation")
    resources = stage.resources(app)
    if gaze:
        overlay.verify_freeze(stage, args.snapshot, snapshot, ROOT)
        proof = overlay.verify_resources(app, resources, base_receipt["resource_manifest"])
    receipt = {
        "schema_version": 1, "label": args.label, "app": str(app),
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "binary_sha256": stage.digest(app / "Contents/MacOS/JevVoice"),
        "unsigned_main_sha256": unsigned_main,
        "source_sha256": expected,
        "source_snapshot": str(args.snapshot.resolve()),
        "source_snapshot_sha256": stage.digest(args.snapshot),
        "staging_helper_sha256": stage.digest(Path(__file__)),
        "signing_helper_sha256": stage.digest(Path(__file__) if gaze else ROOT / "scripts/sign-app.sh"),
        "resource_helper_sha256": stage.digest(ROOT / ".agent/results/P12/c1_manifest.py"),
        "conversation_resource_receipt_sha256": stage.digest(ROOT / ".agent/results/P12/c1-r2-vad-resource.json"),
        "conversation_resource_helper_sha256": stage.digest(ROOT / "scripts/bundle-conversation-vad.py"),
        "rollback_app": str(rollback), "rollback_sha256": rollback_sha,
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
        "voice_provider": info.get("JevVoiceInputProvider", "local"),
        "generated_info_sha256": stage.digest(app / "Contents/Info.plist"),
        "signature_output": signature.stdout + signature.stderr,
        "signing_output": signed.stdout + signed.stderr,
        "physical_input_verified": False, "release_preflight_verified": False,
        **base_metadata,
        **({"tracker_overlay": proof, "tracker_overlay_helper_sha256": stage.digest(Path(overlay.__file__))} if gaze else {}),
    }
    with output.open("x") as stream:
        json.dump(receipt, stream, indent=2, sort_keys=True)
        stream.write("\n")
    print(json.dumps({"receipt": str(output), "app": str(app), "binary_sha256": receipt["binary_sha256"],
                      "strict_signature": True, "installed": False,
                      "driver_matches_rollback": receipt["driver"]["signed_matches_rollback"]}))


if __name__ == "__main__":
    main()
