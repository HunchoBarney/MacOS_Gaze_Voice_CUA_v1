#!/usr/bin/env python3
"""Run one signed normal-controller diagnostic, never a physical voice gate."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[4]
APP = Path.home() / "jarvis-local/typing-repair-candidate/Jev Voice.app"
NORMAL = Path.home() / "jarvis-local/Jev Voice.app"
RUN = sys.argv[1] if len(sys.argv) == 2 else "typing-repair-20261103a"
assert RUN and len(RUN) <= 40 and all(c.isascii() and (c.isalnum() or c == "-") for c in RUN)
RESULT = ROOT / f".agent/results/P3/user-audit-{RUN}/result.json"


def normal_pids():
    output = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, timeout=5)
    target = str(NORMAL / "Contents/MacOS/JevVoice")
    return [int(line.strip().split(None, 1)[0]) for line in output.splitlines()
            if len(line.strip().split(None, 1)) == 2
            and line.strip().split(None, 1)[1] == target]


def main(on_started=None, on_report=None, *, mode="typing"):
    assert mode in ("typing", "focus")
    run_log = Path(__file__).parent / f"packaged-check-{RUN}.log"
    if RESULT.exists() or run_log.exists():
        raise RuntimeError("Refusing to reuse a prior diagnostic result")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(APP)], check=True, timeout=30)
    previous = normal_pids()
    for pid in previous:
        os.kill(pid, signal.SIGTERM)
    deadline = time.monotonic() + 15
    while normal_pids():
        if time.monotonic() >= deadline:
            raise RuntimeError("Normal app did not exit; candidate not launched")
        time.sleep(0.1)
    env = os.environ.copy()
    env.update(JARVIS_P3_GUI_AUDIT="1", JARVIS_P3_GUI_AUDIT_TYPING_ONLY="1",
               JARVIS_P3_GUI_AUDIT_TYPING_REPAIR="1", JARVIS_P3_GUI_AUDIT_RUN_ID=RUN)
    if mode == "focus":
        env.update(JARVIS_P3_GUI_AUDIT_TYPING_ONLY="0", JARVIS_P3_GUI_AUDIT_TYPING_REPAIR="0",
                   JARVIS_P3_GUI_AUDIT_TRACE_ONLY="1")
    env.pop("JARVIS_VOICE_EVIDENCE_DIR", None)
    if evidence := os.environ.get("JARVIS_SPEECH_EVIDENCE_SMOKE_DIR"):
        path = Path(evidence).resolve()
        assert path.is_relative_to(ROOT / ".agent/results/P3/speech-evidence") and path.is_dir()
        env["JARVIS_VOICE_EVIDENCE_DIR"] = str(path)
    proc = None
    try:
        with run_log.open("x") as output:
            proc = subprocess.Popen([str(APP / "Contents/MacOS/JevVoice"), "--p3-user-audit"],
                                    env=env, stdout=output, stderr=subprocess.STDOUT)
            if on_started is not None:
                on_started(proc.pid)
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if RESULT.exists():
                    report = json.loads(RESULT.read_text())
                    if report.get("status") not in ("running", None):
                        if on_report is not None:
                            on_report(proc.pid, report)
                        print(json.dumps(report, indent=2))
                        focused = (mode == "focus" and report["status"] == "reproduction_observed"
                                   and report.get("desktop_ownership_release_safe") is True
                                   and len(report.get("rows", [])) == 1
                                   and report["rows"][0].get("passed") is True)
                        return 0 if report["status"] == "passed" or focused else 1
                if proc.poll() is not None:
                    raise RuntimeError(f"Candidate exited before its report: {proc.returncode}")
                time.sleep(0.1)
            raise RuntimeError("Timed out without a final packaged report")
    finally:
        if proc is not None and proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=15)
        if previous:
            restore_env = os.environ.copy()
            for key in list(restore_env):
                if key.startswith("JARVIS_P3_GUI_AUDIT") or key in (
                        "JARVIS_VOICE_EVIDENCE_DIR", "JARVIS_SPEECH_EVIDENCE_SMOKE_DIR"):
                    restore_env.pop(key)
            with (Path(__file__).parent / "normal-restore.log").open("a") as output:
                restored = subprocess.Popen([str(NORMAL / "Contents/MacOS/JevVoice")],
                                            env=restore_env, stdout=output, stderr=subprocess.STDOUT,
                                            start_new_session=True)
            deadline = time.monotonic() + 10
            while restored.pid not in normal_pids():
                if restored.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("Normal app restoration failed")
                time.sleep(0.1)


if __name__ == "__main__":
    sys.exit(main())
