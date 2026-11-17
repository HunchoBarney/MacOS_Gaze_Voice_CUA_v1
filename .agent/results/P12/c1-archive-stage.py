import argparse
import datetime
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import stat
import subprocess
import tempfile
import zipfile


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
EXPECTED = {
    "final-r2": "eac804975c9504c4dfc6aada473ed087f0c90535e855cbae9de0510a0eae52a8",
    "final-r3": "ea2f7c6ae13297ed922a2e8a7e0af4f5d60f842201a3c8deacaa5bc3d19d859e",
    "final-r4": "65155dbeae7cee3f8f3ce24968dc5c24951df235800f0d4836bfd22c7022adf3",
    "review-c292": "c292e12024dc04bfc6a924b0d7f6ceb41a2c1c23ed38ffcba8f404750f9264eb",
}


def digest_stream(stream):
    value = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        value.update(chunk)
    return value.hexdigest()


def digest(path):
    with path.open("rb") as stream:
        return digest_stream(stream)


def signature(app):
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                   check=True, capture_output=True, timeout=180)


def tree(app):
    entries = {}

    def add(path):
        info = path.lstat()
        entry = {"mode": info.st_mode, "uid": info.st_uid, "gid": info.st_gid}
        if stat.S_ISLNK(info.st_mode):
            entry.update(kind="link", target=os.readlink(path))
        elif stat.S_ISDIR(info.st_mode):
            entry.update(kind="directory")
        elif stat.S_ISREG(info.st_mode):
            entry.update(kind="file", size=info.st_size, sha256=digest(path))
        else:
            raise RuntimeError("Unsupported artifact entry")
        entries[str(path.relative_to(app.parent))] = entry

    for current, directories, files in os.walk(app, followlinks=False):
        add(Path(current))
        for name in directories:
            path = Path(current) / name
            if path.is_symlink():
                add(path)
        for name in files:
            add(Path(current) / name)
    return entries


def verify_zip(archive, expected):
    seen = set()
    with zipfile.ZipFile(archive) as zipped:
        names = [item.filename for item in zipped.infolist()]
        if len(set(names)) != len(names):
            raise RuntimeError("Duplicate archive member")
        for item in zipped.infolist():
            name = item.filename.rstrip("/")
            if name == "__MACOSX" or name.startswith("__MACOSX/"):
                continue
            if name not in expected or name in seen:
                raise RuntimeError("Unexpected payload member")
            seen.add(name)
            entry = expected[name]
            if item.external_attr >> 16 != entry["mode"]:
                raise RuntimeError("Archive mode mismatch: " + name)
            if entry["kind"] == "directory":
                if not item.is_dir():
                    raise RuntimeError("Archive directory mismatch")
            elif entry["kind"] == "link":
                if zipped.read(item) != os.fsencode(entry["target"]):
                    raise RuntimeError("Archive link mismatch")
            else:
                if item.file_size != entry["size"]:
                    raise RuntimeError("Archive size mismatch")
                with zipped.open(item) as stream:
                    if digest_stream(stream) != entry["sha256"]:
                        raise RuntimeError("Archive content mismatch")
        if seen != set(expected):
            raise RuntimeError("Missing payload members")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--label", choices=tuple(EXPECTED), required=True)
    args = parser.parse_args()
    os.umask(0o077)
    review_copy = args.label == "review-c292"
    receipt_path = HERE / ("c1-delivery-receipt.json" if review_copy
                           else "c1-" + args.label + "-stage.json")
    receipt = json.loads(receipt_path.read_text())
    app = Path(receipt["app"])
    location_matches = (
        app == Path.home() / "jarvis-local/c1-review-c292e120/Jev Voice.app"
        and not app.parent.is_symlink()
    ) if review_copy else (
        app.parent.parent.resolve() == Path(tempfile.gettempdir()).resolve()
        and app.parent.name.startswith("jev-c1-" + args.label + "-")
    )
    if (app.name != "Jev Voice.app" or app.is_symlink()
            or not location_matches
            or app.parent.stat().st_uid != os.getuid()
            or digest(app / "Contents/MacOS/JevVoice") != EXPECTED[args.label]):
        raise RuntimeError("Unexpected retained artifact")
    opened = subprocess.run(["lsof", "+D", str(app)], capture_output=True, timeout=60)
    if opened.returncode != 1:
        raise RuntimeError("Artifact may be in use")
    protected = [Path.home() / "jarvis-local/Jev Voice.app"]
    protected += [Path(json.loads((HERE / ("c1-" + label + "-stage.json")).read_text())["app"])
                  for label in ("before", "final-r5")]
    identities = {str(path): digest(path / "Contents/MacOS/JevVoice") for path in protected}
    for path in [app] + protected:
        signature(path)
    archive_root = Path.home() / "jarvis-local/c1-archives"
    archive_root.mkdir(mode=0o700, exist_ok=True)
    info = archive_root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
        raise RuntimeError("Archive directory is not private and owned")
    stem = "c1-" + args.label + "-" + EXPECTED[args.label][:12]
    archive = archive_root / (stem + ".zip")
    partial = archive_root / (stem + ".partial.zip")
    manifest = archive_root / (stem + ".tree.json")
    output = HERE / (stem + "-archive.json")
    if any(path.exists() or path.is_symlink() for path in (archive, partial, manifest, output)):
        raise FileExistsError(stem)
    original = tree(app)
    with manifest.open("x") as stream:
        json.dump(original, stream, indent=2, sort_keys=True)
        stream.write("\n")
    result = {
        "label": args.label, "original_app": str(app), "source_receipt": str(receipt_path),
        "source_receipt_sha256": digest(receipt_path), "archive": str(archive),
        "tree_manifest": str(manifest), "tree_sha256": digest(manifest),
        "before_free_bytes": shutil.disk_usage(archive_root).free,
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "archive_verified": False, "original_removed": False,
        "restore_command": shlex.join(["ditto", "-x", "-k", "--rsrc", str(archive), str(app.parent)]),
    }
    try:
        spec = importlib.util.spec_from_file_location("c1_archive_guard", ROOT / ".agent/results/P4/jev-build-guard.py")
        guard = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(guard)
        signal.signal(signal.SIGTERM, guard.interrupted)
        code = guard.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent",
                          str(app), str(partial)], archive_root, 1.5, 1)
        if code != 0:
            raise RuntimeError("Native archive interrupted: " + str(code))
        verify_zip(partial, original)
        if tree(app) != original:
            raise RuntimeError("Original changed during archival")
        signature(app)
        for path in protected:
            if digest(path / "Contents/MacOS/JevVoice") != identities[str(path)]:
                raise RuntimeError("Protected identity changed")
            signature(path)
        result.update(archive_verified=True, archive_sha256=digest(partial),
                      archive_bytes=partial.stat().st_size, entries=len(original),
                      protected_identities_unchanged=identities)
        partial.rename(archive)
        with (app.parent / "app-archive.json").open("x") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
        with output.open("x") as stream:
            json.dump(result, stream, indent=2)
            stream.write("\n")
        shutil.rmtree(app)
        result["original_removed"] = True
    except BaseException as error:
        result["error"] = str(error)
        raise
    finally:
        if partial.exists():
            partial.unlink()
        result["after_free_bytes"] = shutil.disk_usage(archive_root).free
        result["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        output.write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
