import argparse
import ctypes
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import subprocess
import tempfile
import urllib.request


HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
REQUIRED = (
    "cua-driver", "CodexRuntime/codex", "EyeTracker/bin/node",
    "EyeTracker/package.json",
    "EyeTracker/dist/models/gaze_1x3x160x160.onnx",
    "EyeTracker/dist/models/retinaface_mbn025_with_postprocess_480x640_max1000_th0.70.onnx",
    "EyeTracker/dist/models/vsdlm_l.onnx",
    "ThirdParty/CuaDriver/LICENSE.md", "ThirdParty/CuaDriver/THIRD_PARTY_NOTICES.md",
    "ThirdParty/FluidVoice/LICENSE", "ThirdParty/FluidVoice/NOTICE.md",
    "ThirdParty/FluidAudio/LICENSE", "ThirdParty/FluidAudio/NOTICE.md",
    "ConversationVAD/resource.json", "ConversationVAD/LICENSE", "ConversationVAD/README.md",
)
VAD_RECEIPT = HERE / "c1-r2-vad-resource.json"
VAD_RECEIPT_SHA256 = "be41b15f2b6c5c73c4824b99963b54bc6d5f58c3af04468132ddfe131c1c8062"
MODEL_MEMBERS = {
    "parakeet-ultra": ("Encoder.mlmodelc", "Decoder.mlmodelc", "Preprocessor.mlmodelc",
                       "JointDecisionv3.mlmodelc", "parakeet_v3_vocab.json"),
    "parakeet-eou-streaming/160ms": ("streaming_encoder.mlmodelc", "decoder.mlmodelc",
                                   "joint_decision.mlmodelc", "vocab.json"),
}


def staging():
    spec = importlib.util.spec_from_file_location("c1_stage_primitives",
                                               HERE.parent / "P4/jev-clone-stage.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def candidate_staging():
    spec = importlib.util.spec_from_file_location("c1_candidate_stage", HERE.parent / "P4/jev-stage-candidate.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def clone_file(source, destination):
    clone = ctypes.CDLL(None, use_errno=True).clonefile
    clone.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    clone.restype = ctypes.c_int
    if clone(os.fsencode(source), os.fsencode(destination), 1) != 0:
        raise OSError(ctypes.get_errno(), "APFS fixture clone failed")
    return destination


def canonical_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def check(condition, message):
    if not condition:
        raise ValueError(message)


def resource(base, relative):
    name = PurePosixPath(relative)
    check(relative and not name.is_absolute() and ".." not in name.parts, "escaped resource path")
    path = base / relative
    check(path.resolve().is_relative_to(base.resolve()), "escaped resource path")
    return path


def conversation_bundler():
    spec = importlib.util.spec_from_file_location("conversation_vad_bundle",
                                                 ROOT / "scripts/bundle-conversation-vad.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    check(module.VAD_RECEIPT_SHA256 == VAD_RECEIPT_SHA256, "conversation resource pin changed")
    return module


_conversation_vad = conversation_bundler()
conversation_pin = _conversation_vad.conversation_pin
conversation_resource = _conversation_vad.conversation_resource
prepare_conversation_resource = _conversation_vad.prepare_conversation_resource


def model_files(path, stage):
    check(path.is_dir(), f"missing speech model: {path.name}")
    result = {}
    for file in sorted(path.rglob("*")):
        if file.is_file():
            check(file.resolve().is_relative_to(path.resolve()), "escaped speech model path")
            result[str(file.relative_to(path))] = stage.digest(file)
    check(result, f"missing speech model files: {path.name}")
    return result


def create(receipt_path, app=None):
    stage = staging()
    receipt_path = receipt_path.resolve()
    receipt = json.loads(receipt_path.read_text())
    if app is not None:
        check(receipt.get("label") == candidate_staging().GAZE, "app override requires gaze candidate")
    app = app or Path(receipt["app"])
    if receipt.get("label") == candidate_staging().GAZE:
        check(app.absolute() == app.resolve(strict=True), "candidate app path is aliased")
    model_root = Path.home() / "Library/Application Support/JevVoice/Models"
    pins = json.loads((ROOT / "ThirdParty/Cua/source-manifest.json").read_text())
    package = json.loads((ROOT / "Package.resolved").read_text())
    provider = plistlib.loads((app / "Contents/Info.plist").read_bytes()).get("JevVoiceInputProvider", "local")
    check(provider in ("local", "openai-realtime"), "unknown voice provider")
    if receipt.get("label") == candidate_staging().GAZE:
        check(provider == "openai-realtime", "gaze candidate requires realtime voice")
    required = [item for item in REQUIRED if provider == "local" or not item.startswith("ConversationVAD/")]
    models = {}
    for name in (MODEL_MEMBERS if provider == "local" else ()):
        path = model_root / name
        files = model_files(path, stage)
        models[name] = {"root": str(path), "files": files,
                        "sha256": canonical_hash(files),
                        "bytes": sum((path / file).stat().st_size for file in files)}
    dependency = next(pin for pin in package["pins"] if pin["identity"].lower() == "fluidaudio")
    data = {
        "schema_version": 1,
        "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "stage_receipt": str(receipt_path), "stage_receipt_sha256": stage.digest(receipt_path),
        "app": receipt["app"], "binary_sha256": receipt["binary_sha256"],
        "rollback_app": receipt["rollback_app"], "rollback_sha256": receipt["rollback_sha256"],
        "rollback_role": receipt.get("rollback_role", "original_daily"),
        "source_snapshot": receipt["source_snapshot"],
        "source_snapshot_sha256": receipt["source_snapshot_sha256"],
        "required_resources": required,
        "voice_provider": provider,
        "resource_manifest_sha256": canonical_hash(receipt["resource_manifest"]),
        "integration": {"transport": "app-stdio-jsonrpc",
                        "driver_generation": pins["vendored_binaries"]["cua-driver"]["version"],
                        "dependency_source": "Sources/JevVoice/ComputerControl/CuaDependency.swift",
                        "experimental_window_images": receipt["experimental_window_images"]},
        "driver": receipt["driver"], "codex": receipt["codex"],
        "fluid_audio": dependency, "package_resolved_sha256": stage.digest(ROOT / "Package.resolved"),
        "speech_models": models,
        "conversation_vad": conversation_resource(app / "Contents/Resources/ConversationVAD") if provider == "local" else None,
        "licenses": {
            "cua": "ThirdParty/CuaDriver/LICENSE.md",
            "fluid_voice_ui": "ThirdParty/FluidVoice/NOTICE.md",
            "fluid_audio": "ThirdParty/FluidAudio/LICENSE",
            "speech_attribution": "ThirdParty/FluidAudio/NOTICE.md",
            "transitive_release_review": "pending C3 portable-package qualification",
        },
        "private_tester_keys": "existing Keychain policy; no secret values in this manifest",
        "installed": False,
    }
    if data["rollback_role"] == "last_verified_candidate":
        for key in candidate_staging().retained_base_metadata():
            data[key] = receipt.get(key)
    if receipt.get("label") == candidate_staging().GAZE:
        data["tracker_overlay"] = receipt["tracker_overlay"]
    return data


def verify(data, app=None):
    stage = staging()
    check(data["schema_version"] == 1, "unsupported component manifest")
    receipt_path = Path(data["stage_receipt"])
    check(stage.digest(receipt_path) == data["stage_receipt_sha256"], "stage receipt identity changed")
    receipt = json.loads(receipt_path.read_text())
    candidate = candidate_staging()
    gaze = receipt.get("label") == candidate.GAZE
    check(gaze == ("tracker_overlay" in receipt) == ("tracker_overlay" in data),
          "tracker overlay label or proof missing")
    role = receipt.get("rollback_role", "original_daily")
    check(role in ("original_daily", "last_verified_candidate")
          and data.get("rollback_role", "original_daily") == role, "rollback provenance role changed")
    if role == "last_verified_candidate":
        for key, expected in candidate_staging().retained_base_metadata().items():
            check(data.get(key) == receipt.get(key) == expected, "rollback provenance changed: " + key)
    check(data["binary_sha256"] == receipt["binary_sha256"], "binary identity differs from staging")
    check(data["driver"] == receipt["driver"] and data["codex"] == receipt["codex"],
          "runtime identity differs from staging")
    check(data["integration"]["transport"] == "app-stdio-jsonrpc"
          and data["integration"]["driver_generation"] == receipt["driver"]["version"],
          "SDK and driver generation mismatch")
    check(data["integration"]["experimental_window_images"] is False
          and receipt["experimental_window_images"] is False, "unqualified image protocol")
    snapshot_path = Path(data["source_snapshot"])
    check(str(snapshot_path) == receipt["source_snapshot"]
          and stage.digest(snapshot_path) == data["source_snapshot_sha256"]
          == receipt["source_snapshot_sha256"], "source snapshot identity changed")
    snapshot = json.loads(snapshot_path.read_text())
    check((snapshot.get("label") == candidate.GAZE) == gaze, "gaze freeze cannot be relabelled")
    check((Path(receipt["app"]).parent.name == "jev-c1-" + candidate.GAZE) == gaze,
          "gaze stage destination cannot be relabelled")
    if gaze:
        destination = candidate.RETAINED_BASE_APP.parents[1] / ("jev-c1-" + candidate.GAZE) / "Jev Voice.app"
        check(Path(receipt["app"]) == destination, "gaze stage destination differs from exclusive reservation")
        overlay = candidate.tracker_overlay()
        overlay.verify_freeze(stage, snapshot_path, snapshot)
        base_receipt = overlay.retained_receipt(candidate.RETAINED_BASE_RECEIPT, candidate.RETAINED_BASE_RECEIPT_SHA,
                                               candidate.RETAINED_BASE_SHA)
        for path, field in ((Path(candidate.__file__), "staging_helper_sha256"),
                            (Path(overlay.__file__), "tracker_overlay_helper_sha256"),
                            (Path(__file__), "resource_helper_sha256")):
            check(stage.digest(path) == receipt[field] == snapshot["source_sha256"].get(str(path.relative_to(ROOT))),
                  "gaze recipe identity changed")
        check(receipt["signing_helper_sha256"] == receipt["staging_helper_sha256"],
              "incorrect outer signing recipe")
        check(base_receipt["signing_metadata"] == receipt["signing_metadata"] and
              base_receipt["designated_requirement"] == receipt["designated_requirement"],
              "retained signing identity or entitlements changed")
    if receipt.get("label") in candidate_staging().RETEST_LABELS:
        check(role == "last_verified_candidate", "first-minute candidate requires the pinned retained base")
        candidate_staging().verify_retest_release(snapshot, receipt["unsigned_main_sha256"], receipt["label"])
        expected = {key: value for key, value in snapshot["source_sha256"].items()
                    if key.startswith("Sources/") or key in ("Package.swift", "Package.resolved", "Info.plist")}
        check(expected == receipt["source_sha256"], "first-minute source manifest differs from staging")
        for name, digest in snapshot["source_sha256"].items():
            source = snapshot_path.parent / name
            check(source.resolve().is_relative_to(snapshot_path.parent.resolve())
                  and stage.digest(source) == digest, "first-minute frozen input changed")
    dependency_name = "Sources/JevVoice/ComputerControl/CuaDependency.swift"
    check(data["integration"]["dependency_source"] == dependency_name, "SDK source identity changed")
    dependency = snapshot_path.parent / dependency_name
    check(stage.digest(dependency) == receipt["source_sha256"][dependency_name], "SDK source bytes changed")
    pinned_hash = re.search(r'static let executableSHA256 = "([0-9a-f]{64})"', dependency.read_text())
    check(pinned_hash and pinned_hash[1] == receipt["driver"]["canonical_sha256"], "SDK binary pin mismatch")
    resolved = snapshot_path.parent / "Package.resolved"
    check(stage.digest(resolved) == data["package_resolved_sha256"]
          == receipt["source_sha256"]["Package.resolved"], "speech dependency lock changed")
    check(data["fluid_audio"] in json.loads(resolved.read_text())["pins"], "speech SDK identity changed")
    check(snapshot["source_sha256"]["Package.resolved"] == data["package_resolved_sha256"],
          "source dependency binding changed")
    app = app or Path(data["app"])
    if gaze:
        check(app.absolute() == app.resolve(strict=True), "candidate app path is aliased")
    check(Path(data["app"]) == Path(receipt["app"]), "candidate path differs from staging")
    base = app / "Contents/Resources"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    provider = info.get("JevVoiceInputProvider", "local")
    check(provider in (("openai-realtime",) if gaze else ("local", "openai-realtime"))
          and data.get("voice_provider", "local") == provider,
          "voice provider declaration changed")
    required = [item for item in REQUIRED if provider == "local" or not item.startswith("ConversationVAD/")]
    check(set(required).issubset(data["required_resources"]), "required resource policy omitted")
    for name in data["required_resources"]:
        check(resource(base, name).is_file(), f"missing resource: {name}")
    expected_vad = conversation_resource(base / "ConversationVAD") if provider == "local" else None
    check(data.get("conversation_vad") == expected_vad, "conversation model declaration changed")
    members = MODEL_MEMBERS if provider == "local" else {}
    check(set(data["speech_models"]) == set(members), "speech model declaration differs from provider")
    if provider == "openai-realtime":
        check(not any(item.startswith("ConversationVAD/") for item in data["required_resources"]),
              "realtime voice must not require local VAD")
    for name, required in members.items():
        model = data["speech_models"][name]
        path = Path(model["root"])
        check(path.is_dir() and all((path / item).exists() for item in required),
              f"missing speech model: {name}")
        check(canonical_hash(model["files"]) == model["sha256"], f"speech model manifest changed: {name}")
        for file in model["files"]:
            resource(path, file)
    check(stage.digest(app / "Contents/MacOS/JevVoice") == data["binary_sha256"], "binary identity mismatch")
    check(stage.digest(app / "Contents/Info.plist") == receipt["generated_info_sha256"], "generated Info.plist changed")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    check(info["CFBundleIdentifier"] == "com.chriswozniczek.jevvoice", "bundle identity mismatch")
    check(info["JevCuaDriverSHA256"] == receipt["driver"]["signed_sha256"], "generated driver stamp mismatch")
    check(canonical_hash(receipt["resource_manifest"]) == data["resource_manifest_sha256"],
          "resource manifest identity changed")
    resources = stage.resources(app)
    check(resources == receipt["resource_manifest"], "immutable bundle resources changed")
    if not gaze:
        shim = resources.get("EyeTracker/node_modules/.bin/electron", {}).get("sha256")
        check(shim != "a8fe569ad0c1efe9b7e18f575c2d9f0ab07a22068ba504bff98079600e0dd2a5",
              "gaze bundle cannot be relabelled as legacy")
    if gaze:
        proof = overlay.verify_resources(app, resources, base_receipt["resource_manifest"])
        check(proof == data["tracker_overlay"] == receipt["tracker_overlay"], "tracker provenance changed")
        pins_path = overlay.plain(snapshot_path.parent, "ThirdParty/Cua/source-manifest.json")
        pins_sha = stage.digest(pins_path)
        check(pins_sha == receipt["canonical_pin_sha256"] == snapshot["source_sha256"].get("ThirdParty/Cua/source-manifest.json"),
              "canonical vendor manifest identity changed")
        overlay.verify_tools(base_receipt, pins_sha, json.loads(pins_path.read_text())["vendored_binaries"],
                             receipt["driver"], receipt["codex"], receipt["source_sha256"], dependency, resources)
    check(stage.requirement(app) == receipt["designated_requirement"], "designated requirement changed")
    check(stage.signing_metadata(app) == receipt["signing_metadata"], "signing metadata changed")
    signature = subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                               capture_output=True, text=True, timeout=120)
    check(signature.returncode == 0, "strict signature verification failed")
    blockers = []
    for name, model in data["speech_models"].items():
        path = Path(model["root"])
        check(model_files(path, stage) == model["files"], f"speech model bytes changed: {name}")
        if not path.resolve().is_relative_to(app.resolve()):
            blockers.append(f"external speech model: {name}; portable bundling belongs to C3")
    blockers.append(data["licenses"]["transitive_release_review"])
    rollback = Path(data["rollback_app"])
    check(str(rollback) == receipt["rollback_app"] and data["rollback_sha256"] == receipt["rollback_sha256"],
          "rollback declaration changed")
    if not gaze:
        check(stage.digest(rollback / "Contents/MacOS/JevVoice") == data["rollback_sha256"],
              "rollback executable changed")
    if role == "last_verified_candidate" and not gaze:
        candidate_staging().verify_retained_base(stage, receipt["label"], data)
    return {"candidate_verified": True, "release_ready": not blockers,
            "release_blockers": blockers, "speech_models": list(data["speech_models"]),
            "installed": False, "binary_sha256": data["binary_sha256"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("create", "verify", "prepare-vad"))
    parser.add_argument("--receipt", type=Path)
    parser.add_argument("--manifest", type=Path)
    parser.add_argument("--app", type=Path, help="verify a copied gaze candidate in place")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--destination", type=Path)
    args = parser.parse_args()
    if args.action == "prepare-vad":
        check(args.destination is not None, "a resource destination is required")
        print(json.dumps(prepare_conversation_resource(args.source, args.destination)))
        return
    check(args.manifest is not None, "a component manifest is required")
    if args.action == "create":
        check(args.receipt is not None, "a stage receipt is required")
        data = create(args.receipt, args.app)
        result = verify(data, args.app)
        with args.manifest.open("x") as stream:
            json.dump(data, stream, indent=2, sort_keys=True)
            stream.write("\n")
    else:
        data = json.loads(args.manifest.read_text())
        if args.app is not None:
            check("tracker_overlay" in data, "app override requires gaze candidate")
        result = verify(data, args.app)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
