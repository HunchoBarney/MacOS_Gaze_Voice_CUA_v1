#!/usr/bin/env python3
"""Bounded, local-only release benchmark; each engine gets a fresh process."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import time

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[1]
ENGINES = ["speechanalyzer", "parakeet", "speechanalyzer-fast"]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic_json(path, data):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def services():
    result = subprocess.run(
        ["/bin/ps", "-axo", "pid=,rss=,comm="], capture_output=True, text=True, timeout=5,
    )
    return [
        {"pid": int(parts[0]), "rss_mb": int(parts[1]) / 1024, "name": parts[2]}
        for line in result.stdout.splitlines()
        if "localspeechrecognition" in line
        for parts in [line.strip().split(None, 2)] if len(parts) == 3
    ]


def apple_assets():
    root = Path("/System/Library/AssetsV2/com_apple_MobileAsset_UAF_Speech_AutomaticSpeechRecognition")
    errors = []
    total = 0
    for directory, _, files in os.walk(root, onerror=lambda error: errors.append(str(error))):
        for name in files:
            try:
                total += os.stat(Path(directory) / name, follow_symlinks=False).st_size
            except OSError as error:
                errors.append(str(error))
    return {
        "path": str(root), "shared_asset_directory_bytes": total if total else None,
        "errors": errors, "locale_exclusive_bytes": None,
        "note": "System asset inventory, not an attributed en_US model footprint.",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iters", type=int, default=3)
    parser.add_argument("--clip")
    parser.add_argument("--engine", choices=ENGINES)
    args = parser.parse_args()
    assert args.iters > 0
    binary = PACKAGE / ".build/release/bakeoff"
    assert binary.is_file(), "Build through scripts/verification-lane.sh speech-release first"
    manifest_path = PACKAGE / "corpus/manifest.json"
    manifest = json.loads(manifest_path.read_text())
    corpus = []
    for row in manifest["recordings"]:
        assert row["status"] == "ok" and row.get("confirmed") is True, row["id"]
        path = PACKAGE / "corpus" / row["wav"]
        corpus.append({**row, "sha256": sha(path)})
    assert len(corpus) >= 10
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    directory = PACKAGE / "results" / run_id
    directory.mkdir()
    engines = [args.engine] if args.engine else ENGINES
    combined = {
        "meta": {
            "run_id": run_id, "binary_sha256": sha(binary), "engines": engines,
            "iterations": args.iters, "clip_filter": args.clip,
            "source_sha256": {
                str(p.relative_to(PACKAGE)): sha(p)
                for p in sorted((PACKAGE / "Sources/bakeoff").glob("*.swift"))
            },
            "manifest_sha256": sha(manifest_path),
            "method": "scheduled-end clock, energy-delimited immutable input, fresh process per variant",
            "apple_assets": apple_assets(),
        },
        "corpus": corpus, "probe": {}, "resources": {}, "rows": [], "partials_probe": [],
        "processes": [], "service_observations": [],
    }
    child_env = {key: os.environ[key] for key in ("HOME", "TMPDIR", "LANG") if key in os.environ}
    child_env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    for engine in engines:
        output = directory / f"{engine}.json"
        command = [str(binary), "measure", "--engine", engine, "--iters", str(args.iters), "--out", str(output)]
        if args.clip:
            command += ["--clip", args.clip]
        print("START", engine, flush=True)
        started = time.monotonic()
        samples = [{"t_s": 0, "services": services()}]
        timed_out = False
        with (directory / f"{engine}.log").open("w") as log:
            child = subprocess.Popen(
                command, cwd=ROOT, env=child_env, stdout=log, stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            try:
                while child.poll() is None:
                    if time.monotonic() - started > 1200:
                        timed_out = True
                        raise subprocess.TimeoutExpired(command, 1200)
                    samples.append({"t_s": time.monotonic() - started, "services": services()})
                    time.sleep(0.5)
            except BaseException:
                if child.poll() is None:
                    os.killpg(child.pid, signal.SIGTERM)
                    try:
                        child.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        os.killpg(child.pid, signal.SIGKILL)
                        child.wait(timeout=5)
                if not timed_out:
                    raise
        combined["processes"].append({
            "engine": engine, "pid": child.pid, "exit_code": child.returncode,
            "wall_s": time.monotonic() - started, "timeout": timed_out, "reaped": child.poll() is not None,
        })
        combined["service_observations"].append({"engine": engine, "samples": samples})
        if output.exists():
            data = json.loads(output.read_text())
            combined["rows"].extend(data["rows"])
            combined["resources"].update(data["resources"])
            combined["probe"].update({f"{engine}:{k}": v for k, v in data["probe"].items()})
            for row in data["rows"]:
                if row["iter"] >= 0:
                    combined["partials_probe"].append({
                        "kind": "partials_probe", "engine": engine, "clip": row["clip"],
                        "iter": row["iter"], "input_duration_ms": row.get("input_duration_ms"),
                        "events": row.get("events", []),
                    })
        atomic_json(directory / "combined.json", combined)
        print("END", engine, "exit", child.returncode, "rows", len(combined["rows"]), flush=True)
    assert sha(manifest_path) == combined["meta"]["manifest_sha256"], "recordings changed during benchmark"
    for row in corpus:
        assert sha(PACKAGE / "corpus" / row["wav"]) == row["sha256"]
    atomic_json(PACKAGE / "results/results.json", combined)
    print("RESULT", directory, flush=True)


if __name__ == "__main__":
    main()
