import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("candidate_stage", HERE / "jev-clone-stage.py")
stage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stage)


def outside_resources(app):
    result = {}
    for path in app.rglob("*"):
        relative = path.relative_to(app)
        if relative.parts[:2] == ("Contents", "Resources"):
            continue
        mode = path.lstat().st_mode
        item = {"mode": stat.S_IMODE(mode)}
        if path.is_symlink():
            item["link"] = os.readlink(path)
        elif path.is_file():
            item["sha256"] = stage.digest(path)
        result[str(relative)] = item
    return result


def compress(index_path):
    archive = index_path.resolve().parent
    if archive.parent != HERE or not archive.name.startswith("candidate-archive-"):
        raise RuntimeError("only this run's owned candidate archive is accepted")
    index = json.loads(index_path.read_text())
    anchor = Path(index["full_resource_anchor"])
    if stage.resources(anchor) != index["resource_manifest"]:
        raise RuntimeError("archive resources changed")
    for position, record in enumerate(index["archives"]):
        bundle = Path(record["archived_bundle"])
        if not bundle.is_relative_to(archive) or outside_resources(bundle) != record["outside_resources"]:
            raise RuntimeError("archived non-resource bytes changed")
        packed = archive / ("candidate-" + str(position) + ".tar.xz")
        subprocess.run(["/usr/bin/tar", "-cJf", str(packed),
                        "--exclude=./Contents/Resources", "-C", str(bundle), "."],
                       check=True, timeout=120)
        verified = {}
        with tarfile.open(packed, "r:xz") as stream:
            for member in stream.getmembers():
                relative = Path(member.name)
                if str(relative) == "." or any(part.startswith("._") for part in relative.parts):
                    continue
                item = {"mode": member.mode}
                if member.isfile():
                    value = hashlib.sha256()
                    with stream.extractfile(member) as source:
                        for block in iter(lambda: source.read(1024 * 1024), b""):
                            value.update(block)
                    item["sha256"] = value.hexdigest()
                elif member.issym():
                    item["link"] = member.linkname
                elif not member.isdir():
                    raise RuntimeError("unexpected archived file type")
                verified[str(relative)] = item
        if verified != record["outside_resources"]:
            raise RuntimeError("compressed archive failed original byte/mode verification")
        record.update(compressed_non_resources=str(packed), compressed_sha256=stage.digest(packed),
                      original_bytes_and_modes_verified=True,
                      reconstruct="Restore non-resource tar.xz at app root and clone Contents/Resources "
                                  "from full_resource_anchor, outside synced checkout; verify original signature.")
        index_path.write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
        if bundle == anchor:
            for child in (bundle / "Contents").iterdir():
                if child.name != "Resources":
                    shutil.rmtree(child) if child.is_dir() else child.unlink()
        else:
            shutil.rmtree(bundle)
    if stage.resources(anchor) != index["resource_manifest"]:
        raise RuntimeError("archive resources changed during compression")
    print(index_path)
    subprocess.run(["df", "-h", "/"], check=True, timeout=10)


def main():
    current_receipt = HERE / "jev-candidate-stage-8550a1c31d6344178717e2067f29cb99.json"
    current = json.loads(current_receipt.read_text())
    current_app = Path(current["app"]).resolve()
    expected_resources = stage.resources(current_app)
    names = [
        "jev-candidate-stage-a3ab50165fa44e2a8128c52f66f267cb.json",
        "jev-candidate-recovered-09df.json",
        "jev-candidate-stage-773c8c5977184f3b992dd2f1965289e5.json",
    ]
    processes = subprocess.check_output(["ps", "-axo", "comm="], text=True, timeout=10)
    candidates = []
    for name in names:
        receipt_path = HERE / name
        receipt = json.loads(receipt_path.read_text())
        app = Path(receipt["app"]).resolve()
        if (app == current_app or not app.parent.name.startswith("jev-p4-release-")
                or app.parent.stat().st_uid != os.getuid()):
            raise RuntimeError("candidate ownership check failed")
        if str(app / "Contents/MacOS/JevVoice") in processes.splitlines():
            raise RuntimeError("candidate is still running")
        if stage.digest(app / "Contents/MacOS/JevVoice") != receipt["binary_sha256"]:
            raise RuntimeError("candidate executable changed")
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                       check=True, timeout=40)
        if stage.resources(app) != expected_resources:
            raise RuntimeError("candidate resources differ; no deletion authorized")
        candidates.append((receipt_path, receipt, app, outside_resources(app)))
    archive = HERE / ("candidate-archive-" + uuid.uuid4().hex)
    archive.mkdir(mode=0o700)
    anchor = archive / "resource-anchor" / "Jev Voice.app"
    anchor.parent.mkdir()
    first = candidates[0]
    os.rename(first[2], anchor)
    if stage.resources(anchor) != expected_resources or outside_resources(anchor) != first[3]:
        raise RuntimeError("archive anchor changed")
    index = {
        "authorization": "User approved archiving intermediate temporary candidates on 2026-11-09",
        "current_full_candidate_untouched": str(current_app),
        "full_resource_anchor": str(anchor),
        "resource_manifest": expected_resources,
        "archives": [],
    }
    for receipt_path, receipt, app, manifest in candidates:
        entry = archive / receipt_path.stem
        entry.mkdir()
        shutil.copy2(receipt_path, entry / receipt_path.name)
        if app == first[2]:
            destination = anchor
        else:
            destination = entry / "bundle-without-resources"
            shutil.copytree(app, destination, symlinks=True, ignore=lambda path, names:
                            {"Resources"} if Path(path) == app / "Contents" else set())
        if outside_resources(destination) != manifest:
            raise RuntimeError("archived executable/signature/metadata changed")
        record = {
            "original_bundle": str(app), "archived_bundle": str(destination),
            "receipt": str(entry / receipt_path.name), "receipt_sha256": stage.digest(receipt_path),
            "binary_sha256": receipt["binary_sha256"], "outside_resources": manifest,
            "reconstruct": "Clone resource-anchor/Jev Voice.app outside the synced checkout, "
                           "then replace every non-resource path from archived_bundle; verify original signature.",
            "original_temporary_bundle_removed": False,
        }
        index["archives"].append(record)
        (archive / "index.json").write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
        if app != first[2]:
            if (stage.digest(app / "Contents/MacOS/JevVoice") != receipt["binary_sha256"]
                    or outside_resources(app) != manifest or stage.resources(app) != expected_resources):
                raise RuntimeError("candidate changed during archival")
            shutil.rmtree(app)
        record["original_temporary_bundle_removed"] = True
        (archive / "index.json").write_text(json.dumps(index, indent=2, sort_keys=True) + "\n")
        if not any(app.parent.iterdir()):
            app.parent.rmdir()
    if stage.resources(current_app) != expected_resources:
        raise RuntimeError("current candidate resources changed")
    print(archive / "index.json")
    subprocess.run(["df", "-h", "/"], check=True, timeout=10)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--compress", type=Path)
    arguments = parser.parse_args()
    compress(arguments.compress) if arguments.compress else main()
