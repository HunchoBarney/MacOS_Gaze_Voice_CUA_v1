#!/usr/bin/env python3
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(__file__).resolve().parent


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def profile_driver(binary, directory, done):
    attempts = 0
    deadline = time.monotonic() + 80
    while not done.is_set() and time.monotonic() < deadline and attempts < 6:
        rows = subprocess.check_output(["ps", "-axo", "pid=,ppid=,command="], text=True, timeout=5)
        processes = [r.strip().split(None, 2) for r in rows.splitlines()]
        hosts = {int(r[0]) for r in processes if len(r) == 3
                 and r[2] == str(binary) + " --p3-user-audit"}
        drivers = [r for r in processes if len(r) == 3 and int(r[1]) in hosts
                   and "/cua-driver serve " in r[2]]
        if not drivers:
            done.wait(.2)
            continue
        pid = drivers[0][0]
        attempts += 1
        subprocess.run(["sample", pid, "1", "1", "-file", str(directory / f"driver-{attempts}.txt")],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
        done.wait(.5)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--profile", action="store_true")
    args = parser.parse_args()
    assert re.fullmatch(r"[a-z0-9-]{1,12}", args.label) and args.repeats == 3
    assert not any(k.startswith("JARVIS_P3_NORMAL_") for k in os.environ)
    app = args.app.resolve()
    binary = app / "Contents/MacOS/JevVoice"
    assert binary.is_file()
    target = OUT / f"speed-{args.label}"
    target.mkdir(mode=0o700)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=45)
    digest = hashlib.sha256(binary.read_bytes()).hexdigest()
    helper = module("signed_typing", ROOT / ".agent/results/P3/typing-repair/run-packaged-check.py")
    cleanup = module("owned_fixture_cleanup",
                     ROOT / ".agent/results/P3/physical-20261105/run-focus-window-density.py")
    helper.APP = app
    cleanup.BACKUP = target / "fixture-backups"
    baseline_documents, _ = cleanup.inventory()
    summary = {"schema_version": 1, "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
               "label": args.label, "platform": platform.platform(), "repeats": args.repeats,
               "signed_sha256": digest, "app": str(app), "status": "running",
               "physical_input": False, "human_confirmed": False, "phase_accepted": False,
               "documents_before": baseline_documents, "rows": []}
    output = target / "results.json"
    output.write_text(json.dumps(summary, indent=2) + "\n")
    for i in range(args.repeats + int(args.profile)):
        profiled = i == args.repeats
        run = f"sp-{args.label}-{uuid.uuid4().hex[:8]}-{i + 1}"
        helper.RUN = run
        helper.RESULT = ROOT / f".agent/results/P3/user-audit-{run}/result.json"
        done = threading.Event()
        thread = None
        if profiled:
            thread = threading.Thread(target=profile_driver, args=(binary, target, done))
            thread.start()
        print(f"{args.label} {i + 1}: signed exact typing; profiled={profiled}", flush=True)
        try:
            code = helper.main()
        finally:
            done.set()
            if thread:
                thread.join(timeout=12)
                assert not thread.is_alive(), "Profiler must stop before releasing desktop"
        data = json.loads(helper.RESULT.read_text())
        assert data["desktop_ownership_release_safe"] is True
        owned = sorted(set(cleanup.inventory()[1]) & set(helper.RESULT.parent.glob("owned-*.txt")))
        closed = cleanup.close_owned(owned) if owned else 0
        after, _ = cleanup.inventory()
        row = {"report": str(helper.RESULT.relative_to(ROOT)), "profiled": profiled,
               "exit": code, "status": data["status"], "elapsed_ms": data.get("elapsed_ms"),
               "closed_fixtures": closed, "documents_after": after,
               "exact_insertion": data.get("exact_insertion"), "decoy_unchanged": data.get("decoy_unchanged"),
               "no_model_rounds": data.get("no_model_rounds"), "trace": data.get("trace", [])}
        summary["rows"].append(row)
        output.write_text(json.dumps(summary, indent=2) + "\n")
        assert code == 0 and data["status"] == "passed"
        assert data["executable_sha256"] == digest
        assert all(data[k] is True for k in ("captured_binding_matches", "decoy_unchanged",
                   "exact_insertion", "task_literal_matches", "no_model_rounds",
                   "normal_controller_no_audit_binding"))
        assert data["type_dispatches"] == 1 and after == baseline_documents
    summary["status"] = "passed"
    output.write_text(json.dumps(summary, indent=2) + "\n")
    print("PASS three measured runs; profiled run excluded. No physical voice acceptance.", flush=True)


if __name__ == "__main__":
    main()
