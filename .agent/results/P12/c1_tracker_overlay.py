"""Pinned overlay for final-gaze-quiet-1. The retained receipt owns every other resource row."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil


LABEL = "final-gaze-quiet-1"
PINS_PATH = Path(__file__).with_name("final-gaze-quiet-1-pins.json")
PINS_SOURCE = ".agent/results/P12/" + PINS_PATH.name
PINS_SHA256 = "3ad65625bcae736e6bc1564b1dea68b5a969fce8b31c0c1ef105e2cf63fe8bec"
if PINS_PATH.is_symlink() or hashlib.sha256(raw := PINS_PATH.read_bytes()).hexdigest() != PINS_SHA256:
    raise ValueError("reviewed tracker pins file changed")
PINS = json.loads(raw)
INPUTS = PINS["inputs"]
OUTPUTS = PINS["renderer_outputs"]
PREFIX = "EyeTracker/"
SHIM = "node_modules/.bin/electron"
ELECTRON = "node_modules/electron/dist/Electron.app/Contents/MacOS/Electron"
SHIM_BYTES = b'#!/bin/sh\nexec "${0%/*}/../electron/dist/Electron.app/Contents/MacOS/Electron" "$@"\n'
BASE_OUTPUTS = {"index.html", "assets/index-6EDtPWa9.js", "assets/index-l2cG5lwS.css",
                "assets/inferenceWorker-B8bfgC5u.js", "assets/ort-wasm-simd-threaded.asyncify-D5D0fo7z.wasm",
                "assets/ort.webgpu.bundle.min-DZMghybQ.js"}
MAIN = "electron/main.cjs"
PRODUCER = "electron/externalStore.cjs"
DELETED_REPLAY = "Sources/JevVoice/Voice/VoiceReplay.swift"
BUILD_FILES = {"Package.swift", "Package.resolved", "Info.plist"}
RECIPE = (".agent/results/P4/jev-stage-candidate.py", ".agent/results/P12/c1_manifest.py",
          ".agent/results/P12/c1_tracker_overlay.py", PINS_SOURCE,
          "ThirdParty/Cua/source-manifest.json")


def check(condition, message):
    if not condition:
        raise ValueError(message)


def plain(root, name):
    path = root / name
    check(path.resolve(strict=True) == root.resolve(strict=True) / name,
          "unexpected symlink: " + name)
    return path.resolve(strict=True)


def inventory(directory):
    check(directory.is_dir() and not directory.is_symlink(), "missing plain input directory")
    return {str(f.relative_to(directory)) for f in directory.rglob("*")}


def members(names):
    return {str(part) for name in names for part in (Path(name), *Path(name).parents)
            if str(part) != "."}


def swift_inputs(root, stage):
    names = set(BUILD_FILES)
    def unreadable(error):
        raise error
    for directory, dirs, files in os.walk(plain(root, "Sources"), onerror=unreadable):
        folder = Path(directory)
        check(all(not (folder / d).is_symlink() for d in dirs), "symlink in compiled source tree")
        names.update(str((folder / f).relative_to(root.resolve())) for f in files if f.endswith(".swift"))
    check(names != BUILD_FILES, "empty compiled Swift cohort")
    return {name: stage.digest(plain(root, name)) for name in names}


def renderer_graph(outputs):
    patterns = ("index-[\\w-]+\\.js", "index-[\\w-]+\\.css", "inferenceWorker-[\\w-]+\\.js",
                "ort\\.webgpu\\.bundle\\.min-[\\w-]+\\.js", "ort-wasm-simd-threaded\\.asyncify-[\\w-]+\\.wasm")
    roles = []
    for pattern in patterns:
        matches = [name for name in outputs if re.fullmatch("assets/" + pattern, name)]
        check(len(matches) == 1, "unexpected renderer asset family")
        roles.append(matches[0])
    entry, css, worker, ort, wasm = roles
    check(set(outputs) == {"index.html", *roles}, "unexpected renderer output")
    return {"index.html": sorted([entry, css]), entry: sorted([worker, ort]), worker: [wasm],
            ort: sorted([entry, wasm]), css: [], wasm: []}


def verify_renderer(evidence, inputs, outputs, pin):
    raw = plain(evidence, "renderer-build.json").read_bytes()
    check(hashlib.sha256(raw).hexdigest() == pin, "renderer build receipt not pinned")
    record = json.loads(raw)
    log = plain(evidence, "renderer-build.log").read_bytes()
    emitted = re.findall(rb"(?:^|/)(index\.html|assets/[\w.-]+)\s+[\d,.]+ kB\b", log, re.M)
    check(record.get("label") == LABEL and record.get("recipe") == "offline-isolated-vite-8.0.16"
          and type(record.get("exit_code")) is int and record["exit_code"] == 0
          and record.get("empty_before") is True and sorted(n.decode() for n in emitted) == sorted(outputs)
          and record.get("inputs_before") == record.get("inputs_after") == inputs
          and record.get("outputs") == outputs and record.get("edges") == renderer_graph(outputs)
          and record.get("log_sha256") == hashlib.sha256(log).hexdigest()
          and log.startswith(b"vite v8.0.16 building client environment for production...")
          and re.fullmatch(rb".*built in [\d.]+m?s", log.rstrip().splitlines()[-1]),
          "renderer build proof does not bind reviewed sources and outputs")
    for name in ("cohort.py", "renderer-refs.cjs"):
        check(record.get("recipe_sha256", {}).get(name) == hashlib.sha256(
            plain(evidence, "renderer-recipe/" + name).read_bytes()).hexdigest(), "renderer build recipe changed")


def verify_build(stage, frozen, snapshot, current):
    review_bytes = plain(frozen, "tracker-source-review.json").read_bytes()
    check(hashlib.sha256(review_bytes).hexdigest() == PINS["source_review_sha256"],
          "tracker source review identity changed")
    verify_renderer(frozen, INPUTS, OUTPUTS, PINS.get("renderer_build_sha256"))
    review = json.loads(review_bytes)
    reviewed = review.get("reviewed_swift_inputs")
    declared = {n: sha for n, sha in snapshot["source_sha256"].items() if n.startswith("Sources/") or n in BUILD_FILES}
    check(set(review) == {"label", "verdict", "reviewed_swift_inputs", "reviewed_tracker_inputs","renderer_build_sha256",
                          "deleted_sources", "renderer_outputs"}
          and review.get("renderer_build_sha256") == PINS["renderer_build_sha256"] and review.get("reviewed_tracker_inputs") == INPUTS
          and review.get("label") == LABEL and review.get("verdict") == "PASS" and
          reviewed == declared and review.get("renderer_outputs") == OUTPUTS, "unapproved source cohort")
    deleted = review.get("deleted_sources")
    check(isinstance(deleted, list) and DELETED_REPLAY in deleted and all(
        isinstance(n, str) and n.startswith("Sources/") and n.endswith(".swift") and
        ".." not in Path(n).parts and str(Path(n)) == n and n not in reviewed for n in deleted),
        "invalid source deletion evidence")
    for root in [frozen] + ([current] if current else []):
        check(all(not os.path.lexists(root / n) for n in deleted), "deleted Swift source still present")
        check(swift_inputs(root, stage) == reviewed, "compiled Swift cohort changed")
    raw = plain(frozen, "release-build.json").read_bytes()
    check(hashlib.sha256(raw).hexdigest() == PINS.get("release_build_sha256"), "release receipt not pinned")
    build = json.loads(raw)
    unsigned = build.get("unsigned_main_sha256")
    check(build.get("label") == LABEL and build.get("lane") == "c1-package-release"
          and type(build.get("exit_code")) is int and build["exit_code"] == 0
          and build.get("source_review_sha256") == PINS["source_review_sha256"]
          and build.get("compiled_swift_inputs") == reviewed
          and isinstance(unsigned, str) and re.fullmatch("[0-9a-f]{64}", unsigned)
          and unsigned == snapshot.get("built_unsigned_main_sha256"), "release build does not bind reviewed inputs")
    log = plain(frozen, "release-build.log").read_bytes()
    lines = [line.strip() for line in log.splitlines() if line.strip()]
    check(hashlib.sha256(log).hexdigest() == build.get("log_sha256") and len(lines) >= 3
          and b"Building for production..." in lines[:-2]
          and re.fullmatch(rb"Build complete! \([0-9.]+s\)", lines[-2])
          and lines[-1] == b"verification lane green", "missing or unsuccessful serialized release log")
    if current:
        check(stage.digest(current / ".build/release/JevVoice") == unsigned, "local unsigned release changed")


def verify_freeze(stage, snapshot_path, snapshot, current=None):
    check(PINS["status"] == "approved-final" and PINS["label"] == LABEL
          and PINS["source_review_sha256"] != "7f5ca0d6ee35a80b745494f9262428220303efd4220a729a6bac193fd2389601"
          and INPUTS["EyeTracking/" + PRODUCER] != "83f85f29b14d1fc7e3b734e34f4db4137d3cfcea4c0c225a420c70a6001b9c5e"
          and OUTPUTS["index.html"] != "28826f49b850db4ea0683b04395d7269adc8b7652318f5147d222c5779e50b01",
          "initial renderer and producer superseded: final independently reviewed pins required")
    check(len(OUTPUTS) == 6 and "index.html" in OUTPUTS and
          all(Path(n).parent == Path("assets") for n in OUTPUTS if n != "index.html"),
          "invalid reviewed renderer output layout")
    check(snapshot["label"] == LABEL and snapshot.get("renderer_output_sha256") == OUTPUTS,
          "wrong tracker freeze")
    check(not snapshot_path.is_symlink(), "snapshot must be a regular file")
    frozen = snapshot_path.resolve(strict=True).parent
    verify_build(stage, frozen, snapshot, current)
    for root in [frozen] + ([current] if current else []):
        check(stage.digest(plain(root, PINS_SOURCE)) == PINS_SHA256, "frozen reviewed pins changed")
        for name in RECIPE:
            check(snapshot["source_sha256"].get(name) == stage.digest(plain(root, name)),
                  "gaze recipe or vendor identity changed: " + name)
        for name, expected in INPUTS.items():
            check(snapshot["source_sha256"].get(name) == expected
                  and stage.digest(plain(root, name)) == expected, "tracker input changed: " + name)
        prefix = "EyeTracking/web/src/"
        check(inventory(plain(root, prefix.rstrip("/"))) ==
              members(k[len(prefix):] for k in INPUTS if k.startswith(prefix)), "renderer input set changed")
    output = plain(frozen, "renderer-output")
    check(inventory(output) == members(OUTPUTS), "renderer output set changed")
    for name, expected in OUTPUTS.items():
        check(stage.digest(plain(output, name)) == expected, "renderer output changed: " + name)


def retained_receipt(path, sha, binary):
    raw = path.read_bytes()
    check(hashlib.sha256(raw).hexdigest() == sha, "base receipt changed")
    receipt = json.loads(raw)
    check(receipt["label"] == "final-r9-2" and receipt["binary_sha256"] == binary,
          "incorrect overlay base")
    return receipt


def expected_resources(base):
    rows = base.copy()
    for name in BASE_OUTPUTS - OUTPUTS.keys():
        del rows[PREFIX + "dist/" + name]
    for name, sha in OUTPUTS.items():
        rows[PREFIX + "dist/" + name] = {"mode": 0o644, "sha256": sha}
    for name in (MAIN, PRODUCER):
        rows[PREFIX + name] = {"mode": 0o644, "sha256": INPUTS["EyeTracking/" + name]}
    rows[PREFIX + SHIM] = {"mode": 0o755, "sha256": hashlib.sha256(SHIM_BYTES).hexdigest()}
    return rows


def verify_resources(app, rows, base):
    check(rows == expected_resources(base), "candidate differs from permitted retained resource delta")
    check(app.absolute() == app.resolve(strict=True), "candidate app path is aliased")
    tracker = plain(app, "Contents/Resources/EyeTracker")
    for path in [p for p, row in rows.items() if p.startswith(PREFIX) and "link" in row]:
        check((tracker / path[len(PREFIX):]).resolve().is_relative_to(tracker),
              "symlink outside tracker: " + path)
    for name in ("bin/node", SHIM, "scripts/start-prod.cjs", "dist/index.html", MAIN, "package.json"):
        path = plain(tracker, name)
        check(path.is_file(), "missing local tracker entry: " + name)
        if name in ("bin/node", SHIM):
            check(os.access(path, os.X_OK), "tracker launcher is not executable: " + name)
    check(json.loads((tracker / "package.json").read_text())["main"] == MAIN,
          "incorrect tracker main")
    electron = (tracker / ELECTRON).resolve(strict=True)
    check(electron.is_relative_to(tracker) and electron.is_file() and os.access(electron, os.X_OK),
          "missing bundled Electron executable")
    return {"reviewed_source_delta_sha256": PINS["source_review_sha256"], "pins_sha256": PINS_SHA256,
            "release_build_sha256": PINS["release_build_sha256"],
            "inputs": INPUTS, "outputs": OUTPUTS,
            "tracker": "Contents/Resources/EyeTracker", "node": "bin/node", "launcher": "scripts/start-prod.cjs",
            "shim": SHIM, "shim_sha256": rows[PREFIX + SHIM]["sha256"],
            "electron": str(electron.relative_to(tracker)), "main": MAIN, "producer": PRODUCER,
            "renderer": "dist/index.html"}


def apply_overlay(stage, app, snapshot_path, snapshot, current, base):
    verify_freeze(stage, snapshot_path, snapshot, current)
    check(stage.resources(app) == base, "clone differs from pinned base before overlay")
    tracker = plain(app, "Contents/Resources/EyeTracker")
    frozen = snapshot_path.resolve(strict=True).parent
    for name in BASE_OUTPUTS - OUTPUTS.keys():
        plain(tracker, "dist/" + name).unlink()
    for name in OUTPUTS:
        dst = tracker / "dist" / name
        plain(tracker, str(dst.parent.relative_to(tracker)))
        if os.path.lexists(dst):
            plain(tracker, "dist/" + name).unlink()
        with plain(frozen, "renderer-output/" + name).open("rb") as src, dst.open("xb") as target:
            shutil.copyfileobj(src, target)
        dst.chmod(0o644)
    for name in (MAIN, PRODUCER):
        shutil.copyfile(plain(frozen, "EyeTracking/" + name), plain(tracker, name))
    plain(tracker, SHIM).write_bytes(SHIM_BYTES)
    return verify_resources(app, stage.resources(app), base)


def verify_tools(base, pins_sha, pins, driver, codex, sources, dependency, resources):
    check(pins_sha == base["canonical_pin_sha256"], "canonical vendor manifest differs from retained pin")
    for name, row, path in (("cua-driver", driver, "cua-driver"), ("codex", codex, "CodexRuntime/codex")):
        previous = base["driver" if name == "cua-driver" else "codex"]
        check(pins[name]["version"] == row["version"] == previous["version"]
              and pins[name]["sha256"] == row["canonical_sha256"] == previous["canonical_sha256"]
              and resources[path]["sha256"] == row["signed_sha256"] == previous["signed_sha256"],
              "retained tool binding changed: " + name)
    source = "Sources/JevVoice/ComputerControl/CuaDependency.swift"
    check(sources.get(source) == hashlib.sha256(dependency.read_bytes()).hexdigest() == base["source_sha256"][source]
          and ('static let executableSHA256 = "' + driver["canonical_sha256"] + '"') in dependency.read_text(),
          "embedded driver pin differs from retained pin")
