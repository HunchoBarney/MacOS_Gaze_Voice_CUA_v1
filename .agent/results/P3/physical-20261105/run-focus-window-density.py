import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[4]
OUT = Path(__file__).resolve().parent
BACKUP = OUT / "fixture-backups-20261105"
APP = Path.home() / "jarvis-local/p3-focus-inflection-20261105/Jev Voice.app"
NORMAL = Path.home() / "jarvis-local/Jev Voice.app/Contents/MacOS/JevVoice"
HELPER = ROOT / ".agent/results/P3/typing-repair/run-packaged-check.py"


def apple(script):
    return subprocess.check_output(["osascript", "-"], input=script, text=True, timeout=120).strip()


def inventory():
    count = int(apple('tell application "TextEdit" to count documents'))
    prefix = str(ROOT / ".agent/results/P3/user-audit-")
    output = apple(f'''
tell application "TextEdit"
    set found to {{}}
    repeat with d in documents
        try
            set p to path of d
            set n to name of d
            if p starts with {json.dumps(prefix)} and n starts with "owned-" and n ends with ".txt" then set end of found to p
        end try
    end repeat
    set AppleScript's text item delimiters to ASCII character 10
    return found as text
end tell
''')
    return count, [Path(p) for p in output.splitlines() if p]


def close_owned(paths):
    paths = [Path(p) for p in paths]
    for path in paths:
        assert path.resolve().is_relative_to(ROOT / ".agent/results/P3")
        assert path.parent.name.startswith("user-audit-") and path.name.startswith("owned-")
        assert path.is_file() and not path.is_symlink()
        target = BACKUP / path.relative_to(ROOT / ".agent/results/P3")
        target.parent.mkdir(parents=True, exist_ok=True)
        assert not target.exists()
        target.write_bytes(path.read_bytes())
    allowed = "{" + ", ".join(json.dumps(str(p)) for p in paths) + "}"
    closed = int(apple(f'''
tell application "TextEdit"
    set allowedPaths to {allowed}
    set closedCount to 0
    repeat with i from (count documents) to 1 by -1
        set d to document i
        try
            set p to path of d
        on error
            set p to ""
        end try
        if allowedPaths contains p then
            save d
            close d saving yes
            set closedCount to closedCount + 1
        end if
    end repeat
    return closedCount
end tell
'''))
    assert closed == len(paths), (closed, len(paths))
    return closed


def normal_pids():
    rows = subprocess.check_output(["ps", "-axo", "pid=,command="], text=True, timeout=5)
    return [int(parts[0]) for row in rows.splitlines()
            if len(parts := row.strip().split(None, 1)) == 2 and parts[1] == str(NORMAL)]


def main():
    os.chdir(ROOT)
    path = OUT / "focus-window-density.json"
    assert not path.exists() and not BACKUP.exists()
    total, originals = inventory()
    assert total == 55 and len(originals) == 53, "Window population changed; do not silently broaden approval"
    BACKUP.mkdir()
    result = {"status": "running", "phase_acceptance": False, "physical_input": False,
              "subject": hashlib.sha256((APP / "Contents/MacOS/JevVoice").read_bytes()).hexdigest(),
              "approval": "User selected Save and close 53; save originals first, delete nothing, leave other two open",
              "initial_documents": total, "approved_documents": [str(p.relative_to(ROOT)) for p in originals],
              "rows": []}
    previous = normal_pids()
    try:
        for pid in previous:
            os.kill(pid, signal.SIGTERM)
        deadline = time.monotonic() + 15
        while normal_pids():
            if time.monotonic() >= deadline:
                raise RuntimeError("Normal app still running")
            time.sleep(.1)
        for phase, expected_count in (("high", 55), ("low", 2)):
            if phase == "low":
                result["approved_closed_count"] = close_owned(originals)
                assert inventory()[0] == 2
            for rep in range(1, 4):
                assert inventory()[0] == expected_count
                run = f"focus-density-{phase}-{rep}"
                sys.argv = [str(HELPER), run]
                spec = importlib.util.spec_from_file_location("density_typing", HELPER)
                runner = importlib.util.module_from_spec(spec)
                spec.loader.exec_module(runner)
                runner.APP = APP
                print(f"{phase} density {rep}/3, baseline {expected_count} documents", flush=True)
                code = runner.main()
                data = json.loads(runner.RESULT.read_text())
                row = {"phase": phase, "repetition": rep, "baseline_documents": expected_count,
                       "elapsed_ms": data["elapsed_ms"], "status": data["status"],
                       "report": str(runner.RESULT.relative_to(ROOT))}
                result["rows"].append(row)
                path.write_text(json.dumps(result, indent=2) + "\n")
                assert code == 0 and data["status"] == "passed"
                assert data["executable_sha256"] == result["subject"]
                assert all(data[k] is True for k in ("exact_insertion", "decoy_unchanged",
                           "no_model_rounds", "normal_controller_no_audit_binding",
                           "desktop_ownership_release_safe"))
                assert data["type_dispatches"] == data["work_count"] == 1
                own = sorted(runner.RESULT.parent.glob("owned-*.txt"))
                assert len(own) == 2
                row["closed_new_fixtures"] = close_owned(own)
                row["post_documents"] = inventory()[0]
                assert row["post_documents"] == expected_count
                print(json.dumps(row), flush=True)
        result["status"] = "passed"
    except Exception as error:
        result.update(status="failed", error=str(error))
        raise
    finally:
        path.write_text(json.dumps(result, indent=2) + "\n")
        if previous and not normal_pids():
            with (OUT / "focus-density-normal-restore.log").open("x") as log:
                proc = subprocess.Popen([str(NORMAL)], stdin=subprocess.DEVNULL,
                                        stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
            print("Normal app restoration requested:", proc.pid, flush=True)


if __name__ == "__main__":
    main()
