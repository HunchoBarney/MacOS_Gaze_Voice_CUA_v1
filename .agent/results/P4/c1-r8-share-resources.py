import argparse
import datetime
import importlib.util
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
PREVIOUS = HERE.parent / "P12"
spec = importlib.util.spec_from_file_location("c1_resource_helpers", PREVIOUS / "c1-share-stage-resources.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def receipt(label):
    return json.loads((PREVIOUS / f"c1-{label}-stage.json").read_text())


def verify_app(app, expected):
    if (app.name != "Jev Voice.app" or app.resolve() != app
            or native.digest(app / "Contents/MacOS/JevVoice") != expected
            or native.signature(app, deep=True)["exit_code"]):
        raise RuntimeError("Retained app identity or signature changed")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--attempt", type=int, choices=range(1, 10), default=1)
    parser.add_argument("--target", action="append",
                        choices=("final-r6", "final-r7", "final-r8", "final-r9", "final-r9-2"))
    parser.add_argument("--record-tag", choices=("c1-r8", "c1-r10"), default="c1-r8")
    args = parser.parse_args()
    os.umask(0o077)
    suffix = "" if args.attempt == 1 else f"-{args.attempt}"
    output = HERE / f"{args.record_tag}-resource-sharing{suffix}.json"
    journal = HERE / f"{args.record_tag}-resource-sharing{suffix}.transactions.jsonl"
    if output.exists() or journal.exists():
        raise FileExistsError("Preserve existing storage evidence")
    target_labels = tuple(dict.fromkeys(args.target or ("final-r6", "final-r7")))
    records = {label: receipt(label) for label in ("before", "final-r5", *target_labels)}
    delivery = json.loads((PREVIOUS / "c1-delivery-receipt.json").read_text())
    source_app = Path(records["final-r5"]["app"])
    protected = {Path.home() / "jarvis-local/Jev Voice.app": delivery["daily_binary_sha256"]}
    protected.update({Path(records[label]["app"]).resolve(strict=True): records[label]["binary_sha256"]
                      for label in ("before", "final-r5")})
    targets = {Path(records[label]["app"]): records[label]["binary_sha256"]
               for label in target_labels}
    for app in targets:
        if app in protected or app.parent.parent != Path.home() / "jarvis-local/c1-candidates":
            raise RuntimeError("Unexpected storage target")
    for app, expected in {**protected, **targets}.items():
        verify_app(app, expected)
    sources = {}
    for relative in native.RELATIVES:
        source = native.checked_file(source_app, "CodexRuntime/codex"
                                     if relative == "CodexRuntime/bin/codex" else relative)
        sources[relative] = {
            "path": source, "sha256": native.digest(source), "metadata": native.metadata(source),
            "cdhash": None if relative.endswith(".onnx") else native.cdhash(source),
        }
    scratch = Path(tempfile.mkdtemp(prefix=f".{args.record_tag}-sharing-", dir=Path.home() / "jarvis-local"))
    report = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "runner_sha256": native.digest(Path(__file__)),
        "reused_helper_sha256": native.digest(PREVIOUS / "c1-share-stage-resources.py"),
        "source_app": str(source_app), "targets": {str(k): v for k, v in targets.items()},
        "protected": {str(k): v for k, v in protected.items()},
        "before_free_bytes": shutil.disk_usage(scratch).free, "apps": [], "complete": False,
        "purpose": "Share physical extents; retain every signed byte, path, metadata and app signature.",
    }
    output.write_text(json.dumps(report, indent=2) + "\n")
    signal.signal(signal.SIGTERM, native.stopped)
    signal.signal(signal.SIGINT, native.stopped)
    try:
        with journal.open("x") as log:
            for app, expected in targets.items():
                paths = [native.checked_file(app, relative) for relative in native.RELATIVES]
                native.no_handles(paths + [app / "Contents/MacOS/JevVoice"])
                record = {"app": str(app), "files": [], "committed": False}
                report["apps"].append(record)
                transactions = []
                validated = False
                try:
                    for relative, path in zip(native.RELATIVES, paths):
                        source = sources[relative]
                        info = path.stat()
                        if info.st_dev != source["path"].stat().st_dev or info.st_dev != scratch.stat().st_dev:
                            raise RuntimeError("Cross-volume sharing rejected")
                        original_hash, original_meta = native.digest(path), native.metadata(path)
                        shared = native.shared_bytes(source["path"], path)
                        if shared >= info.st_size - 65536:
                            record["files"].append({"path": str(path), "skipped": "already_shared"})
                            continue
                        if info.st_size != source["metadata"]["size"]:
                            raise RuntimeError("Resource size differs")
                        if source["cdhash"] is None:
                            compatible = original_hash == source["sha256"]
                        else:
                            compatible = (native.cdhash(path) == source["cdhash"]
                                          and native.signature(path)["exit_code"] == 0)
                        if not compatible:
                            record["files"].append({"path": str(path), "skipped": "different_version_or_signature"})
                            continue
                        descriptor, name = tempfile.mkstemp(prefix="resource-", dir=scratch)
                        os.close(descriptor)
                        temporary = Path(name)
                        temporary.unlink()
                        parent = path.parent.stat()
                        row = {"path": str(path), "temporary": str(temporary), "swapped": False,
                               "sha256": original_hash, "metadata": original_meta,
                               "parent_times": [parent.st_atime_ns, parent.st_mtime_ns],
                               "shared_bytes_before": shared}
                        transactions.append(row)
                        record["files"].append(row)
                        native.append(log, {"event": "preparing", **row})
                        if native.NATIVE.clonefile(os.fsencode(source["path"]), os.fsencode(temporary), 0):
                            raise RuntimeError("Native clone failed")
                        if original_hash != source["sha256"]:
                            subprocess.run(["rsync", "--checksum", "--inplace", "--no-whole-file",
                                            str(path), str(temporary)], check=True, capture_output=True, timeout=180)
                        if native.digest(temporary) != original_hash:
                            raise RuntimeError("Temporary bytes differ")
                        if native.NATIVE.copyfile(os.fsencode(path), os.fsencode(temporary), None, 7):
                            raise RuntimeError("Metadata copy failed")
                        os.utime(temporary, ns=(info.st_atime_ns, info.st_mtime_ns))
                        if native.metadata(temporary) != original_meta:
                            raise RuntimeError("Temporary metadata differs")
                        if source["cdhash"] is not None and native.signature(temporary)["exit_code"]:
                            raise RuntimeError("Temporary signature differs")
                        row["shared_bytes_after"] = native.shared_bytes(source["path"], temporary)
                        if row["shared_bytes_after"] <= shared:
                            raise RuntimeError("Clone did not share physical data")
                        native.no_handles([path, app / "Contents/MacOS/JevVoice"])
                        if (path.stat().st_ino != info.st_ino or native.digest(path) != original_hash
                                or native.metadata(path) != original_meta):
                            raise RuntimeError("Original changed before exchange")
                        native.append(log, {"event": "before_exchange", **row})
                        native.exchange(row)
                        os.utime(path.parent, ns=tuple(row["parent_times"]))
                        if native.digest(path) != original_hash or native.metadata(path) != original_meta:
                            raise RuntimeError("Exchanged resource differs")
                        native.append(log, {"event": "exchanged", **row})
                    verify_app(app, expected)
                    validated = True
                    native.append(log, {"event": "validated", "app": str(app)})
                    for row in transactions:
                        Path(row["temporary"]).unlink()
                    record["committed"] = True
                    record["free_bytes"] = shutil.disk_usage(scratch).free
                    native.append(log, {"event": "committed", **record})
                    output.write_text(json.dumps(report, indent=2) + "\n")
                    print(json.dumps({"app": app.parent.name, "free_bytes": record["free_bytes"]}), flush=True)
                except BaseException:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    signal.signal(signal.SIGINT, signal.SIG_IGN)
                    if not validated:
                        for row in reversed(transactions):
                            if row["swapped"]:
                                native.exchange(row)
                                os.utime(Path(row["path"]).parent, ns=tuple(row["parent_times"]))
                        record["rolled_back"] = True
                    for row in transactions:
                        Path(row["temporary"]).unlink(missing_ok=True)
                    native.append(log, {"event": "interrupted", **record})
                    raise
        for app, expected in {**protected, **targets}.items():
            verify_app(app, expected)
        for source in sources.values():
            if native.digest(source["path"]) != source["sha256"] or native.metadata(source["path"]) != source["metadata"]:
                raise RuntimeError("Protected source resource changed")
        report["complete"] = True
    except BaseException as error:
        report["error"] = str(error)
        raise
    finally:
        report["after_free_bytes"] = shutil.disk_usage(scratch).free
        report["finished_at"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        output.write_text(json.dumps(report, indent=2) + "\n")
        if not any(scratch.iterdir()):
            scratch.rmdir()


if __name__ == "__main__":
    main()
