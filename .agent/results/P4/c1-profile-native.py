import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import uuid


ROOT = Path(__file__).resolve().parents[3]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def main():
    receipt = json.loads((ROOT / ".agent/results/P12/c1-before-stage.json").read_text())
    app = Path(receipt["app"])
    binary = app / "Contents/MacOS/JevVoice"
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == receipt["binary_sha256"]
    helper = module("c1_profile_typing", ROOT / ".agent/results/P3/typing-repair/run-packaged-check.py")
    cleanup = module("c1_profile_cleanup",
                     ROOT / ".agent/results/P3/physical-20261105/run-focus-window-density.py")
    run = "c1profile-" + uuid.uuid4().hex[:8]
    output = ROOT / ".agent/results/P4" / run
    output.mkdir(mode=0o700)
    helper.APP = app
    helper.RUN = run
    helper.RESULT = ROOT / f".agent/results/P3/user-audit-{run}/result.json"
    cleanup.BACKUP = output / "fixture-backups"
    baseline, _ = cleanup.inventory()
    samplers = []

    def started(pid):
        samplers.append(subprocess.Popen(
            ["sample", str(pid), "20", "5", "-file", str(output / "app-sample.txt")],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL))

    try:
        code = helper.main(on_started=started)
    finally:
        for child in samplers:
            try:
                child.wait(timeout=25)
            except subprocess.TimeoutExpired:
                child.terminate()
                child.wait(timeout=5)
    data = json.loads(helper.RESULT.read_text())
    assert data["desktop_ownership_release_safe"] is True
    owned = sorted(set(cleanup.inventory()[1]) & set(helper.RESULT.parent.glob("owned-*.txt")))
    if owned:
        cleanup.close_owned(owned)
    after, _ = cleanup.inventory()
    assert after == baseline
    (output / "diagnostic.json").write_text(json.dumps({
        "profiled": True, "not_a_timed_comparison": True,
        "binary_sha256": receipt["binary_sha256"],
        "report": str(helper.RESULT), "sample": str(output / "app-sample.txt"),
        "status": data["status"], "documents_restored": True,
        "sampler_exit_codes": [child.returncode for child in samplers],
    }, indent=2) + "\n")
    print(output)
    assert code == 0 and data["status"] == "passed"


if __name__ == "__main__":
    main()
