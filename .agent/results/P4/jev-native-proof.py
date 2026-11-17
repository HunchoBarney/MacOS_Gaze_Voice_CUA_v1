#!/usr/bin/env python3
"""Real MCP -> pinned native driver -> owned synthetic AppKit app."""
import argparse
import concurrent.futures
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import plistlib
import platform
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
SOURCE = HERE / "JevWorkflowFixture.swift"
APP_ID = "dev.jevvoice.workflow-fixture"
sys.path.insert(0, str(ROOT / "bench"))
from lib.mcp_stdio import MCPStdio, require_api_key, tool_text
from lib.results import classify

verifier_spec = importlib.util.spec_from_file_location("native_policy", HERE / "jev-native-verifier.py")
verifier = importlib.util.module_from_spec(verifier_spec)
verifier_spec.loader.exec_module(verifier)


def digest(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save(path, value):
    temporary = path.with_suffix(".pending")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def build_fixture():
    applications = Path.home() / "Applications"
    if not applications.is_dir():
        raise SystemExit("BLOCKED: existing user Applications directory required")
    app = applications / ("Jev P4 Fixture " + uuid.uuid4().hex + ".app")
    executable = app / "Contents/MacOS/JevWorkflowFixture"
    executable.parent.mkdir(parents=True)
    info = {
        "CFBundleIdentifier": APP_ID, "CFBundleName": "Jev Workflow Fixture",
        "CFBundleDisplayName": "Jev Workflow Fixture", "CFBundleExecutable": executable.name,
        "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
        "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication",
    }
    (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-framework", "AppKit",
                    str(SOURCE), "-o", str(executable)], check=True, timeout=180)
    subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True, timeout=30)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True, timeout=30)
    receipt = {
        "app": str(app), "executable": str(executable),
        "source_sha256": digest(SOURCE), "binary_sha256": digest(executable),
        "platform": platform.platform(),
    }
    output = HERE / ("jev-fixture-build-" + uuid.uuid4().hex + ".json")
    save(output, receipt)
    print(output)


def scenarios():
    rows = []
    for steps in (7, 10):
        rows.append({
            "id": f"setup-{steps}", "kind": "setup", "steps": steps,
            "goal": "Complete the installer using Continue, then Finish on its final page",
            "success": "Setup complete", "expected": {"stage": steps},
        })
    rows.append({
        "id": "choice-44-of-45", "kind": "choices", "goal": "Press the last numbered Choice button",
        "success": "Selected Choice 44", "expected": {"selection": 44},
    })
    for name in ("Aster", "Mira"):
        email = name.lower() + "@example.test"
        rows.append({
            "id": "profile-" + name.lower(), "kind": "form",
            "goal": f"Replace Name with {name}, press Next, enter {email} in Email, then Submit",
            "values": {"Name": name, "Email": email},
            "success": f"Profile complete: {name} <{email}>",
            "expected": {"name": name, "email": email},
        })
    for a, operation, b, result in ((12, "*", 7, 84), (9, "+", 14, 23), (23, "*", 4, 92)):
        rows.append({
            "id": f"calculate-{a}-{'times' if operation == '*' else 'plus'}-{b}",
            "kind": "calculator",
            "goal": f"Calculate {a} {'multiplied by' if operation == '*' else 'plus'} {b}",
            "success": f"Result: {result}",
            "expected": {"operands": sorted([a, b]), "operation": operation, "result": result},
        })
    return rows


def verified(state, case):
    return verifier.verified(state, case)


def wait_state(path, process, timeout=8):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError("owned fixture exited before readiness")
        try:
            state = json.loads(path.read_text())
            if state.get("pid", 0) > 0 and state.get("window_id", 0) > 0:
                return state
        except (OSError, json.JSONDecodeError):
            pass
        time.sleep(0.02)
    raise TimeoutError("owned fixture readiness")


def stop(process):
    if process is None or process.poll() is not None:
        return
    process.terminate()
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=3)


def drive(client, arguments, timeout):
    with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
        future = pool.submit(client.call, "tools/call",
                             {"name": "drive_until", "arguments": arguments}, timeout=timeout + 5)
        try:
            return future.result(timeout=timeout), False
        except concurrent.futures.TimeoutError:
            client._send({"jsonrpc": "2.0", "method": "notifications/cancelled",
                          "params": {"requestId": client._next_id}})
            try:
                return future.result(timeout=3), True
            except Exception:
                client.close()
                raise


def run(args):
    if os.environ.get("JARVIS_P4_NATIVE") != "approved":
        raise SystemExit("BLOCKED: explicit isolated-desktop approval required")
    receipt = json.loads(Path(args.fixture).read_text())
    executable = Path(receipt["executable"])
    if digest(SOURCE) != receipt["source_sha256"] or digest(executable) != receipt["binary_sha256"]:
        raise SystemExit("BLOCKED: fixture does not match its build receipt")
    registration = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks"
                        "/LaunchServices.framework/Support/lsregister")
    subprocess.run([str(registration), "-f", receipt["app"]], check=True, timeout=20)
    binary, driver = Path(args.binary).expanduser().resolve(), Path(args.driver).expanduser().resolve()
    if ".app/Contents/MacOS/" not in str(binary):
        raise SystemExit("BLOCKED: packaged application required, not a debug test binary")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(binary.parents[2])],
                   check=True, timeout=30)
    policy = Path.home() / "Library/Application Support/JevVoice/policy.json"
    if not json.loads(policy.read_text()).get("standingGrant"):
        raise SystemExit("BLOCKED: existing user computer-use grant required; no setting changed")
    key = require_api_key()
    if not key:
        raise SystemExit("BLOCKED: model key unavailable")
    cases = [case for case in scenarios() if not args.case or case["id"] in args.case]
    if not cases or args.repeats < 1:
        raise SystemExit("invalid cases/repeats")
    control = dict(kind="form", completed=True, cancelled=False, name="Aster", email="aster@example.test")
    assert verified(control, scenarios()[3])
    assert not verified(dict(control, name="Incorrect"), scenarios()[3])
    assert not verified(dict(control, completed=False), scenarios()[3])
    run_id = uuid.uuid4().hex
    directory = HERE / ("native-" + args.label + "-" + run_id)
    directory.mkdir()
    output = directory / "results.json"
    owned = Path(tempfile.mkdtemp(prefix="jev-p4-session-"))
    sock = owned / "driver.sock"
    daemon_env = {key: value for key, value in os.environ.items()
                  if key in {"PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"}}
    daemon = None
    rows = []
    record = {
        "kind": "packaged MCP front door, real native UI, synthetic data only",
        "label": args.label, "repeats": args.repeats, "platform": platform.platform(),
        "caller_completion": "goal-only observed proof" if args.goal_only else "declared criteria",
        "binary": str(binary), "binary_sha256": digest(binary),
        "driver": str(driver), "driver_sha256": digest(driver),
        "fixture_sha256": receipt["binary_sha256"], "fixture_source_sha256": digest(SOURCE),
        "harness_sha256": digest(__file__), "workload_sha256": hashlib.sha256(
            json.dumps(dict(cases=cases, goal_only=args.goal_only,
                            caller_deadline=args.caller_deadline), sort_keys=True).encode()).hexdigest(),
        "scope": "Externally managed standard pinned daemon; NOT GUI daemon-autospawn or Fn/microphone proof",
        "fixture_registration": "Only the owned temporary bundle is registered with LaunchServices",
        "verifier_negative_controls": True, "rows": rows, "resources_clean": False,
        "base_harness_sha256": digest(HERE / "jev-native-proof.py"),
        "verifier_sha256": digest(HERE / "jev-native-verifier.py"),
        "expected_rows": len(cases) * args.repeats,
        "diagnostic_only": args.caller_deadline is not None,
        "caller_deadline_override_seconds": args.caller_deadline,
    }
    try:
        daemon = subprocess.Popen([
            str(driver), "serve", "--embedded", "--parent-liveness-stdio", "--no-permissions-gate",
            "--socket", str(sock), "--pid-file", str(owned / "driver.pid"),
            "--host-bundle-id", "com.chriswozniczek.jevvoice",
            "--permission-mode", "standard", "--grant", "existing-profile",
        ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=daemon_env)
        deadline = time.monotonic() + 10
        while True:
            if daemon.poll() is not None:
                raise RuntimeError("owned standard daemon exited")
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                connection.connect(str(sock))
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("owned daemon readiness")
                time.sleep(0.02)
            finally:
                connection.close()
        env = dict(os.environ, TYPESAFE_API_KEY=key, JEV_CUA_SOCKET=str(sock))
        slug = "p4-native-" + run_id
        for trial in range(args.repeats):
            ordered = cases if trial % 2 == 0 else list(reversed(cases))
            for case in ordered:
                state_path = directory / (case["id"] + f"-{trial}.json")
                fixture = None
                fixture_pid = None
                client = MCPStdio([str(binary), "--mcp-stdio", "--agent", slug], env, cwd=str(ROOT))
                row = {"case": case["id"], "trial": trial, "status": "setup_error",
                       "verified": False, "strict_success": False, "false_done": False}
                try:
                    fixture = subprocess.Popen([
                        "/usr/bin/open", "-n", "-W", receipt["app"], "--args",
                        "--kind", case["kind"], "--state", str(state_path),
                        "--steps", str(case.get("steps", 7)),
                    ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    initial = wait_state(state_path, fixture)
                    fixture_pid = initial["pid"]
                    image = subprocess.run(["/bin/ps", "-p", str(fixture_pid), "-o", "comm="],
                                           capture_output=True, text=True, check=True, timeout=3)
                    if Path(image.stdout.strip()).resolve() != executable.resolve():
                        raise RuntimeError("unexpected fixture executable")
                    client.start()
                    client.initialize()
                    tools = client.call("tools/list", timeout=5)
                    schema = next(tool for tool in tools["tools"] if tool["name"] == "drive_until")
                    row["declared_arguments"] = sorted(schema["inputSchema"]["properties"])
                    arguments = {
                        "goal": case["goal"], "app": APP_ID, "values": case.get("values", {}),
                        "success_contains": [case["success"]], "deny": ["Cancel", "Delete", "Quit"],
                    }
                    if args.goal_only:
                        arguments.pop("success_contains")
                    row["sent_arguments"] = sorted(arguments)
                    start = time.perf_counter()
                    row["caller_deadline_seconds"] = (
                        args.caller_deadline if args.caller_deadline is not None
                        else 8 if case["kind"] == "form" else 30)
                    result, cancelled = drive(client, arguments, row["caller_deadline_seconds"])
                    row["wall_ms"] = (time.perf_counter() - start) * 1000
                    text, is_error = tool_text(result)
                    row.update(text=text, is_error=is_error, status=classify(text, is_error),
                               cancelled_by_harness=cancelled)
                    state = json.loads(state_path.read_text())
                    if state.get("pid") != fixture_pid or state.get("window_id") != initial["window_id"]:
                        raise RuntimeError("fixture authority changed")
                    row["verified"] = verified(state, case)
                    done = row["status"] in ("done", "already")
                    row["strict_success"] = done and not is_error and row["verified"] and not cancelled
                    row["false_done"] = done and not row["verified"]
                    row["actual_state"] = state
                    if trial == 0:
                        screenshot = directory / (case["id"] + ".png")
                        capture = subprocess.run(["/usr/sbin/screencapture", "-x", "-l",
                                                  str(state["window_id"]), str(screenshot)],
                                                 capture_output=True, timeout=8)
                        row["own_window_screenshot"] = screenshot.name if capture.returncode == 0 else None
                except Exception as error:
                    row["error_type"] = type(error).__name__
                finally:
                    client.close()
                    if fixture_pid:
                        try:
                            os.kill(fixture_pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                    stop(fixture)
                rows.append(row)
                save(output, record)
                print(f'{case["id"]} trial{trial}: {row["status"]}, verified={row["verified"]}', flush=True)
    finally:
        stop(daemon)
        record["resources_clean"] = daemon is None or daemon.poll() is not None
        record["strict_run_success"] = verifier.strict_run_success(record)
        save(output, record)
    print(output)
    if not record["strict_run_success"]:
        raise SystemExit(1)


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    sub.add_parser("build")
    measure = sub.add_parser("run")
    measure.add_argument("--fixture", required=True)
    measure.add_argument("--binary", required=True)
    measure.add_argument("--driver", required=True)
    measure.add_argument("--label", required=True, choices=("before", "candidate", "pilot"))
    measure.add_argument("--repeats", type=int, default=3)
    measure.add_argument("--case", action="append")
    measure.add_argument("--goal-only", action="store_true")
    measure.add_argument("--caller-deadline", type=float)
    args = parser.parse_args()
    if args.mode == "build":
        build_fixture()
    else:
        if args.caller_deadline is not None and (
            args.label != "pilot" or not math.isfinite(args.caller_deadline)
            or not 0 < args.caller_deadline <= 180
        ):
            parser.error("deadline overrides require a pilot and 0 < seconds <= 180")
        run(args)


if __name__ == "__main__":
    main()
