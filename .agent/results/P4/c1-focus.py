import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import platform
import re
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[3]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--label", required=True)
    args = parser.parse_args()
    assert re.fullmatch("[a-z0-9-]{1,12}", args.label)
    receipt = json.loads(args.receipt.read_text())
    app = Path(receipt["app"])
    digest = hashlib.sha256((app / "Contents/MacOS/JevVoice").read_bytes()).hexdigest()
    assert digest == receipt["binary_sha256"]
    output = ROOT / f".agent/results/P4/c1-focus-{args.label}.json"
    if output.exists():
        raise FileExistsError(output)
    helper = module("c1_focus_launcher", ROOT / ".agent/results/P3/typing-repair/run-packaged-check.py")
    cleanup = module("c1_focus_cleanup",
                     ROOT / ".agent/results/P3/physical-20261105/run-focus-window-density.py")
    helper.APP = app
    documents, _ = cleanup.inventory()
    subprocess.run(["open", "-g", "-b", "com.apple.calculator"], check=True, timeout=20)
    result = {"schema_version": 1, "status": "running", "physical_input": False,
              "human_confirmed": False, "binary_sha256": digest, "app": str(app),
              "workload": "open Calculator; target already running; new Jev process per trial",
              "platform": platform.platform(), "rows": [],
              "harness_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
              "launcher_sha256": hashlib.sha256(Path(helper.__file__).read_bytes()).hexdigest()}
    for index in range(3):
        run = f"c1focus-{args.label}-{uuid.uuid4().hex[:8]}"
        helper.RUN = run
        helper.RESULT = ROOT / f".agent/results/P3/user-audit-{run}/result.json"
        cleanup.BACKUP = helper.RESULT.parent / "fixture-backups"
        code = helper.main(mode="focus")
        report = json.loads(helper.RESULT.read_text())
        marker = json.loads((helper.RESULT.parent / "started.json").read_text())
        assert marker["artifact_sha256"] == digest
        assert report["desktop_ownership_release_safe"] is True
        owned = sorted(set(cleanup.inventory()[1]) & set(helper.RESULT.parent.glob("owned-*.txt")))
        if owned:
            cleanup.close_owned(owned)
        restored, _ = cleanup.inventory()
        row = report["rows"][0]
        times = {item["stage"]: item["monotonic"] for item in row["trace"]}
        end = times.get("executorEnd")
        begin = times.get("contextBegin")
        result["rows"].append({
            "index": index, "passed": row["passed"], "report": str(helper.RESULT.relative_to(ROOT)),
            "visible_effect_ms": row["submit_to_visible_effect_ms"],
            "context_to_verified_ms": (end - begin) * 1000 if end and begin else None,
            "trace": row["trace"], "documents_restored": restored == documents,
            "normal_route": row["normal_route"], "work_count": row["work_count"],
        })
        output.write_text(json.dumps(result, indent=2) + "\n")
        assert code == 0 and row["passed"] and restored == documents
        assert row["work_count"] == 1 and row["normal_route"] == "local"
        assert not row["wrong_proposal"] and not row["scripted_confirmation"]
        assert row["observed_bundle_id"] == "com.apple.calculator" and row["observed_window_id"] > 0
    result["status"] = "passed"
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"result": str(output), "times_ms": [
        row["context_to_verified_ms"] for row in result["rows"]]}))


if __name__ == "__main__":
    main()
