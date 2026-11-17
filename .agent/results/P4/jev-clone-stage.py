import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import tempfile
import uuid

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
ALLOWED = {
    "Sources/JevVoice/ComputerControl/CuaDriveServer.swift",
    "Sources/JevVoice/Drive/WindowControls.swift",
    "Sources/JevVoice/Drive/BrowserSupport.swift",
    "Sources/JevVoice/Drive/DriveCandidates.swift",
    "Sources/JevVoice/Drive/JevChooser.swift",
    "Sources/JevVoice/Drive/JevDecider.swift",
    "Sources/JevVoice/Drive/ObservedGoalProof.swift",
    "Sources/JevVoice/Drive/TaskLoop.swift",
    "Sources/JevVoice/Drive/DriveLoop.swift",
    "Sources/JevVoice/Drive/NativeWindowObservation.swift",
}


def digest(path):
    with Path(path).open("rb") as stream:
        value = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def recovery_metadata(receipt):
    visited = set()
    while True:
        recovery = receipt.get("resource_recovery") or receipt.get("template_resource_recovery")
        if recovery is not None:
            return recovery
        parent = receipt.get("template_receipt")
        if parent is None:
            return None
        path = Path(parent).resolve()
        if not path.is_relative_to(HERE) or path in visited:
            raise RuntimeError("invalid template ancestry")
        visited.add(path)
        if digest(path) != receipt.get("template_receipt_sha256"):
            raise RuntimeError("template ancestry receipt changed")
        receipt = json.loads(path.read_text())


def sources():
    paths = [*ROOT.joinpath("Sources").rglob("*.swift"), ROOT / "Info.plist", ROOT / "Package.swift"]
    return {str(path.relative_to(ROOT)): digest(path) for path in paths}


def resources(app):
    result = {}
    base = app / "Contents/Resources"
    for path in base.rglob("*"):
        mode = path.lstat().st_mode
        row = {"mode": stat.S_IMODE(mode)}
        if path.is_symlink():
            target = os.readlink(path)
            if Path(target).is_absolute() or not path.resolve().is_relative_to(app.resolve()):
                raise RuntimeError("resource symlink escapes the owned bundle")
            row["link"] = target
        elif stat.S_ISREG(mode):
            row["sha256"] = digest(path)
        elif not stat.S_ISDIR(mode):
            raise RuntimeError("unsupported resource file type")
        result[str(path.relative_to(base))] = row
    return result


def run(command, timeout=120):
    return subprocess.run(command, cwd=ROOT, check=True, timeout=timeout)


def requirement(app):
    result = subprocess.run(["codesign", "-d", "-r-", str(app)],
                            capture_output=True, text=True, check=True, timeout=20)
    lines = [line for line in (result.stdout + result.stderr).splitlines()
             if line.startswith("designated => ")]
    if len(lines) != 1:
        raise RuntimeError("designated requirement unavailable")
    return lines[0].removeprefix("designated => ")


def signing_metadata(app):
    entitlements = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                  capture_output=True, check=True, timeout=20).stdout
    details = subprocess.run(["codesign", "-d", "--verbose=4", str(app)],
                             capture_output=True, text=True, check=True, timeout=20)
    flags = re.search(r"flags=(\S+)", details.stdout + details.stderr)
    if not flags:
        raise RuntimeError("signing flags unavailable")
    return dict(entitlements_sha256=hashlib.sha256(entitlements).hexdigest(), flags=flags[1])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--template", required=True, type=Path)
    args = parser.parse_args()
    receipt = json.loads(args.template.read_text())
    template = Path(receipt["app"]).resolve()
    if not template.parent.name.startswith("jev-p4-release-") or template.parent.stat().st_uid != os.getuid():
        raise SystemExit("only an owned temporary stage is accepted")
    if digest(template / "Contents/MacOS/JevVoice") != receipt["binary_sha256"]:
        raise SystemExit("template executable changed")
    before = sources()
    changed = {name for name in before.keys() | receipt["source_sha256"].keys()
               if before.get(name) != receipt["source_sha256"].get(name)}
    if not changed <= ALLOWED:
        raise SystemExit("not a Swift-only compatible restage")
    run(["git", "diff", "--exit-code", "HEAD", "--", "Package.resolved"])
    pin_path = ROOT / "ThirdParty/Cua/source-manifest.json"
    pin_sha = digest(pin_path)
    pins = json.loads(pin_path.read_text())["vendored_binaries"]
    if pins["cua-driver"]["version"] != "0.38.0":
        raise SystemExit("template requires the currently authorized 0.38 driver")
    for name, path in (
        ("cua-driver", ROOT / "build/vendor/cua-driver"),
        ("codex", ROOT / "build/vendor/CodexRuntime/codex"),
    ):
        if digest(path) != pins[name]["sha256"]:
            raise SystemExit("canonical pinned cache changed")
    identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"],
                                         text=True, timeout=20)
    if '"Jev Voice Local Dev"' not in identities:
        raise SystemExit("existing signing identity required")
    mount = subprocess.check_output(["/sbin/mount", "-t", "apfs"], text=True, timeout=20)
    if " on /System/Volumes/Data (apfs," not in mount:
        raise SystemExit("APFS data volume not confirmed")
    temporary = Path(tempfile.gettempdir()).resolve()
    if template.stat().st_dev != temporary.stat().st_dev or temporary.stat().st_dev != Path("/System/Volumes/Data").stat().st_dev:
        raise SystemExit("same APFS volume required")
    if shutil.disk_usage(temporary).free < 300 * 1024**2:
        raise SystemExit("insufficient safe free space")
    run(["codesign", "--verify", "--deep", "--strict", str(template)])
    old_requirement = requirement(template)
    old_signing = signing_metadata(template)
    resource_manifest = resources(template)
    resource_sha = hashlib.sha256(json.dumps(resource_manifest, sort_keys=True).encode()).hexdigest()
    if resource_sha != receipt["immutable_resources_sha256"]:
        raise SystemExit("template resource identity differs from its receipt")
    info_sha = digest(template / "Contents/Info.plist")
    info = plistlib.loads((template / "Contents/Info.plist").read_bytes())
    if info.get("JevCuaDriverSHA256") != digest(template / "Contents/Resources/cua-driver"):
        raise SystemExit("template driver stamp mismatch")
    run(["swift", "build", "--disable-automatic-resolution", "-c", "release"], timeout=900)
    if sources() != before:
        raise SystemExit("source changed during build")
    app = Path(tempfile.mkdtemp(prefix="jev-p4-release-")) / "Jev Voice.app"
    native = ctypes.CDLL(None, use_errno=True).clonefile
    native.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
    native.restype = ctypes.c_int

    def clone(source, destination):
        if native(os.fsencode(source), os.fsencode(destination), 1) != 0:
            raise OSError(ctypes.get_errno(), "clonefile failed; no copying fallback")
        return destination

    shutil.copytree(template, app, symlinks=True, copy_function=clone)
    executable = app / "Contents/MacOS/JevVoice"
    if executable.is_symlink():
        raise SystemExit("main executable must be a regular file")
    shutil.copyfile(ROOT / ".build/release/JevVoice", executable)
    executable.chmod(0o755)
    run(["codesign", "--force", "--sign", "Jev Voice Local Dev", str(app)])
    run(["codesign", "--verify", "--deep", "--strict", str(app)])
    if resources(app) != resource_manifest or digest(app / "Contents/Info.plist") != info_sha:
        raise SystemExit("immutable bundle resources or generated Info changed")
    if (requirement(app) != old_requirement or signing_metadata(app) != old_signing
            or sources() != before or digest(pin_path) != pin_sha):
        raise SystemExit("signing identity or source changed")
    output = HERE / ("jev-candidate-stage-" + uuid.uuid4().hex + ".json")
    output.write_text(json.dumps(dict(
        app=str(app), binary_sha256=digest(executable), source_sha256=before,
        strict_signature=True, installed=False, staging="clonefile, no fallback, root-only reseal",
        template_receipt=str(args.template.resolve()), template_receipt_sha256=digest(args.template),
        template_resource_recovery=recovery_metadata(receipt),
        template_main_sha256=receipt["binary_sha256"], generated_info_sha256=info_sha,
        immutable_resources_sha256=hashlib.sha256(json.dumps(resource_manifest, sort_keys=True).encode()).hexdigest(),
        immutable_resources_identical=True, unchanged_designated_requirement=True,
        unchanged_signing_metadata=old_signing,
        canonical_pin_sha256=pin_sha,
    ), indent=2, sort_keys=True) + "\n")
    print(output)


if __name__ == "__main__":
    main()
