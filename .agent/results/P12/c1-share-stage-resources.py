import argparse
import ctypes
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import stat
import struct
import subprocess
import tempfile


HERE = Path(__file__).resolve().parent
WORKSPACE = Path("/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice")
STAGES = WORKSPACE / "staging/vision-pinned-owner-20261110.artifacts/completion-research-20261110"
RESOURCE = "Contents/Resources/"
RELATIVES = [
    "CodexRuntime/codex",
    "CodexRuntime/bin/codex",
    "CodexRuntime/bin/codex-code-mode-host",
    "EyeTracker/bin/node",
    "EyeTracker/dist/models/gaze_1x3x160x160.onnx",
    "EyeTracker/node_modules/.pnpm/electron@42.4.1/node_modules/electron/dist/"
    "Electron.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Electron Framework",
]
NATIVE = ctypes.CDLL(None, use_errno=True)
NATIVE.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
NATIVE.copyfile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
NATIVE.renamex_np.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        fcntl.fcntl(stream, 48, 1)
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(chunk)
    return value.hexdigest()


def metadata(path):
    info = path.lstat()
    names = subprocess.check_output(["xattr", str(path)], text=True).splitlines()
    attributes = {
        name: hashlib.sha256(bytes.fromhex(subprocess.check_output(
            ["xattr", "-px", name, str(path)], text=True))).hexdigest()
        for name in names
    }
    acl = subprocess.check_output(["ls", "-lde", str(path)], text=True).splitlines()[1:]
    return {
        "size": info.st_size, "mode": info.st_mode, "uid": info.st_uid,
        "gid": info.st_gid, "flags": info.st_flags, "mtime_ns": info.st_mtime_ns,
        "xattrs": attributes,
        "acl_sha256": hashlib.sha256("\n".join(acl).encode()).hexdigest(),
    }


def signature(path, deep=False):
    command = ["codesign", "--verify", "--strict"]
    if deep:
        command.append("--deep")
    result = subprocess.run(command + [str(path)], capture_output=True, timeout=180)
    return {"exit_code": result.returncode,
            "diagnostic_sha256": hashlib.sha256(result.stderr).hexdigest()}


def cdhash(path):
    result = subprocess.run(["codesign", "-d", "--verbose=4", str(path)],
                            check=True, capture_output=True, text=True, timeout=60)
    values = [line.split("=", 1)[1] for line in result.stderr.splitlines()
              if line.startswith("CDHash=")]
    if len(values) != 1:
        raise RuntimeError("Missing unique CodeDirectory hash")
    return values[0]


def checked_file(app, relative):
    if not app.is_dir() or app.is_symlink() or app.resolve() != app:
        raise RuntimeError("Unexpected app root")
    path = app
    for part in Path(RESOURCE + relative).parts:
        path = path / part
        if path.is_symlink():
            raise RuntimeError("Symlink in resource path")
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or info.st_uid != os.getuid() or info.st_flags != 0):
        raise RuntimeError("Unexpected resource identity or flags")
    return path


def no_handles(paths):
    result = subprocess.run(["lsof", "-F", "p", "--"] + [str(p) for p in paths],
                            capture_output=True, timeout=60)
    if result.returncode != 1:
        raise RuntimeError("An eligible app or resource may be in use")


def exchange(row):
    blocked = signal.pthread_sigmask(signal.SIG_BLOCK, {signal.SIGTERM, signal.SIGINT})
    try:
        result = NATIVE.renamex_np(os.fsencode(row["path"]),
                                   os.fsencode(row["temporary"]), 2)
        if result != 0:
            raise OSError(ctypes.get_errno(), "Atomic exchange failed; no fallback")
        row["swapped"] = not row["swapped"]
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, blocked)


def extents(path):
    result = []
    offset = 0
    size = path.stat().st_size
    with path.open("rb") as stream:
        while offset < size:
            _, length, physical = struct.unpack("=Iqq", fcntl.fcntl(
                stream, 65, struct.pack("=Iqq", 0, size - offset, offset)))
            if length <= 0 or physical < 0:
                raise RuntimeError("Unsupported physical extent")
            length = min(length, size - offset)
            result.append((offset, offset + length, physical))
            offset += length
    return result


def shared_bytes(left, right):
    first, second = extents(left), extents(right)
    i = j = shared = 0
    while i < len(first) and j < len(second):
        x, y = first[i], second[j]
        lo, hi = max(x[0], y[0]), min(x[1], y[1])
        if hi > lo and x[2] + lo - x[0] == y[2] + lo - y[0]:
            shared += hi - lo
        if x[1] <= y[1]:
            i += 1
        else:
            j += 1
    return shared


def append(stream, value):
    stream.write(json.dumps(value) + "\n")
    stream.flush()
    os.fsync(stream.fileno())


def stopped(*args):
    raise InterruptedError("Storage retention interrupted")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true", required=True)
    parser.parse_args()
    os.umask(0o077)
    output = HERE / "c1-resource-sharing.json"
    journal = HERE / "c1-resource-sharing.transactions.jsonl"
    if output.exists() or journal.exists():
        raise FileExistsError("Preserve the prior resource-sharing evidence")
    r5 = json.loads((HERE / "c1-final-r5-stage.json").read_text())
    before = json.loads((HERE / "c1-before-stage.json").read_text())
    delivery = json.loads((HERE / "c1-delivery-receipt.json").read_text())
    source_app = Path(r5["app"])
    protected = [
        (Path.home() / "jarvis-local/Jev Voice.app", delivery["daily_binary_sha256"]),
        (Path(before["app"]), before["binary_sha256"]),
        (source_app, r5["binary_sha256"]),
    ]
    sources = {}
    for relative in RELATIVES:
        source_relative = "CodexRuntime/codex" if relative == "CodexRuntime/bin/codex" else relative
        path = checked_file(source_app, source_relative)
        sources[relative] = {
            "path": path, "sha256": digest(path), "metadata": metadata(path),
            "cdhash": None if relative.endswith(".onnx") else cdhash(path),
        }
    apps = [STAGES / f"native-d{version}-candidate-stage" / f"{side}.app"
            for version in range(114, 122) for side in ("before", "after")]
    apps += [STAGES / "jev-vision-ab-d14-admission/after.app"]
    apps += [STAGES / label / f"{side}.app"
             for label in ("jev-vision-ab-d15-trace-baseline", "jev-vision-ab-d16-baseline")
             for side in ("before", "after")]
    apps += [WORKSPACE / "recovery-20261110/signed-baselines" / f"{side}.app"
             for side in ("before", "after")]
    saved = Path.home() / "jarvis-local/c1-review-c292e120/Jev Voice.app"
    if Path(delivery["app"]) != saved or digest(saved / "Contents/MacOS/JevVoice") != delivery["binary_sha256"]:
        raise RuntimeError("Unexpected saved review artifact")
    apps.append(saved)
    for app, expected in protected:
        if digest(app / "Contents/MacOS/JevVoice") != expected or signature(app, deep=True)["exit_code"]:
            raise RuntimeError("Protected artifact does not match")
    scratch_parent = Path.home() / "jarvis-local"
    scratch = Path(tempfile.mkdtemp(prefix=".c1-file-sharing-", dir=scratch_parent))
    report = {
        "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "helper_sha256": digest(Path(__file__)), "source_app": str(source_app),
        "protected": {str(app): expected for app, expected in protected},
        "before_free_bytes": shutil.disk_usage(scratch).free,
        "apps": [], "complete": False, "source_modified": False,
        "compile_budget_changed": False,
    }
    output.write_text(json.dumps(report, indent=2) + "\n")
    signal.signal(signal.SIGTERM, stopped)
    signal.signal(signal.SIGINT, stopped)
    try:
        with journal.open("x") as log:
            for app in apps:
                if shutil.disk_usage(scratch).free >= 4.5 * 2**30:
                    report["stop_reason"] = "free_space_target"
                    break
                if app in [path for path, _ in protected]:
                    raise RuntimeError("Protected target rejected")
                paths = [checked_file(app, relative) for relative in RELATIVES]
                no_handles(paths + [app / "Contents/MacOS/JevVoice"])
                app_result = {
                    "app": str(app), "signature_before": signature(app, deep=True),
                    "before_free_bytes": shutil.disk_usage(scratch).free, "files": [],
                }
                report["apps"].append(app_result)
                transactions = []
                validated = False
                try:
                    for relative, path in zip(RELATIVES, paths):
                        source = sources[relative]
                        original_stat = path.stat()
                        if original_stat.st_dev != source["path"].stat().st_dev or original_stat.st_dev != scratch.stat().st_dev:
                            raise RuntimeError("Cross-volume sharing rejected")
                        original_meta = metadata(path)
                        original_hash = digest(path)
                        if original_stat.st_size != source["metadata"]["size"]:
                            app_result["files"].append({"path": str(path), "skipped": "different_size"})
                            continue
                        if source["cdhash"] is None:
                            matching = original_hash == source["sha256"]
                        else:
                            matching = cdhash(path) == source["cdhash"] and signature(path)["exit_code"] == 0
                        if not matching:
                            app_result["files"].append({"path": str(path), "skipped": "different_version_or_signature"})
                            continue
                        already_shared = shared_bytes(source["path"], path)
                        if already_shared >= original_stat.st_size - 65536:
                            app_result["files"].append({"path": str(path), "skipped": "already_shared",
                                                        "shared_bytes": already_shared})
                            continue
                        descriptor, name = tempfile.mkstemp(prefix="resource-", dir=scratch)
                        os.close(descriptor)
                        temporary = Path(name)
                        temporary.unlink()
                        row = {
                            "path": str(path), "temporary": str(temporary), "swapped": False,
                            "sha256": original_hash, "metadata": original_meta,
                            "inode_before": original_stat.st_ino, "device": original_stat.st_dev,
                            "source": str(source["path"]), "source_sha256": source["sha256"],
                            "shared_bytes_before": already_shared,
                        }
                        parent_stat = path.parent.stat()
                        row["parent_times"] = [parent_stat.st_atime_ns, parent_stat.st_mtime_ns]
                        transactions.append(row)
                        app_result["files"].append(row)
                        append(log, {"event": "preparing", **row})
                        if NATIVE.clonefile(os.fsencode(source["path"]), os.fsencode(temporary), 0) != 0:
                            raise OSError(ctypes.get_errno(), "clonefile failed; no fallback")
                        if original_hash != source["sha256"]:
                            subprocess.run(["rsync", "--checksum", "--inplace", "--no-whole-file",
                                            str(path), str(temporary)], check=True, capture_output=True, timeout=180)
                        if digest(temporary) != original_hash:
                            raise RuntimeError("Temporary data does not preserve original")
                        if NATIVE.copyfile(os.fsencode(path), os.fsencode(temporary), None, 7) != 0:
                            raise OSError(ctypes.get_errno(), "Native metadata copy failed")
                        os.utime(temporary, ns=(original_stat.st_atime_ns, original_stat.st_mtime_ns))
                        if metadata(temporary) != original_meta:
                            raise RuntimeError("Temporary metadata does not preserve original")
                        if source["cdhash"] is not None and signature(temporary)["exit_code"]:
                            raise RuntimeError("Temporary signature changed")
                        row["shared_bytes_after"] = shared_bytes(source["path"], temporary)
                        if row["shared_bytes_after"] <= already_shared:
                            raise RuntimeError("Native sharing produced no physical sharing")
                        no_handles([path, app / "Contents/MacOS/JevVoice"])
                        if path.stat().st_ino != original_stat.st_ino or digest(path) != original_hash or metadata(path) != original_meta:
                            raise RuntimeError("Original changed during preparation")
                        append(log, {"event": "before_exchange", **row})
                        exchange(row)
                        os.utime(path.parent, ns=tuple(row["parent_times"]))
                        if digest(path) != original_hash or metadata(path) != original_meta:
                            raise RuntimeError("Exchanged resource changed logical contents")
                        row["inode_after"] = path.stat().st_ino
                        append(log, {"event": "exchanged", **row})
                    app_result["signature_after"] = signature(app, deep=True)
                    if app_result["signature_before"]["exit_code"] == 0 and app_result["signature_after"]["exit_code"] != 0:
                        raise RuntimeError("App signature regressed")
                    validated = True
                    append(log, {"event": "app_validated", "app": str(app)})
                    for row in transactions:
                        Path(row["temporary"]).unlink()
                    app_result["committed"] = True
                    app_result["after_free_bytes"] = shutil.disk_usage(scratch).free
                    append(log, {"event": "app_committed", **app_result})
                    output.write_text(json.dumps(report, indent=2) + "\n")
                    print(json.dumps({"app": app.parent.name + "/" + app.name,
                                      "shared_resources": len(transactions),
                                      "free_bytes": app_result["after_free_bytes"]}), flush=True)
                except BaseException:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    signal.signal(signal.SIGINT, signal.SIG_IGN)
                    if not validated:
                        for row in reversed(transactions):
                            if row["swapped"]:
                                exchange(row)
                                os.utime(Path(row["path"]).parent, ns=tuple(row["parent_times"]))
                        app_result["rolled_back"] = True
                    for row in transactions:
                        Path(row["temporary"]).unlink(missing_ok=True)
                    append(log, {"event": "app_interrupted", **app_result})
                    raise
            else:
                report["stop_reason"] = "eligible_targets_exhausted"
        for app, expected in protected:
            if digest(app / "Contents/MacOS/JevVoice") != expected or signature(app, deep=True)["exit_code"]:
                raise RuntimeError("Protected artifact changed")
        for source in sources.values():
            if digest(source["path"]) != source["sha256"] or metadata(source["path"]) != source["metadata"]:
                raise RuntimeError("Canonical source changed")
        report["protected_unchanged"] = True
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
