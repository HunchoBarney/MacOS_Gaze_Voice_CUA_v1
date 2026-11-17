#!/usr/bin/env python3
"""Capture raw native observations around normal clicks in the owned fixture."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("native_proof", HERE / "jev-native-proof.py")
native = importlib.util.module_from_spec(spec)
spec.loader.exec_module(native)


def main():
    if os.environ.get("JARVIS_P4_NATIVE") != "approved":
        raise SystemExit("explicit synthetic desktop approval required")
    receipt = json.loads((HERE / "jev-fixture-build-c96108c5eb844df7965643742c76fb57.json").read_text())
    if native.digest(receipt["executable"]) != receipt["binary_sha256"]:
        raise SystemExit("fixture identity changed")
    directory = HERE / ("native-raw-" + uuid.uuid4().hex)
    directory.mkdir()
    owned = Path(tempfile.mkdtemp(prefix="jev-p4-raw-"))
    sock = owned / "driver.sock"
    driver = Path.home() / "jarvis-local/Jev Voice.app/Contents/Resources/cua-driver"
    env = {key: value for key, value in os.environ.items()
           if key in {"PATH", "HOME", "TMPDIR", "USER", "LOGNAME", "LANG", "LC_ALL", "SHELL"}}
    daemon = fixture = client = None
    pid = None
    try:
        daemon = subprocess.Popen([
            str(driver), "serve", "--embedded", "--parent-liveness-stdio", "--no-permissions-gate",
            "--socket", str(sock), "--pid-file", str(owned / "driver.pid"),
            "--host-bundle-id", "com.chriswozniczek.jevvoice",
            "--permission-mode", "standard", "--grant", "existing-profile",
        ], stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=env)
        deadline = time.monotonic() + 10
        while True:
            connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                connection.connect(str(sock))
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("diagnostic daemon readiness")
                time.sleep(0.02)
            finally:
                connection.close()
        state_path = directory / "fixture-state.json"
        fixture = subprocess.Popen([
            "/usr/bin/open", "-n", "-W", receipt["app"], "--args", "--kind", "setup",
            "--state", str(state_path), "--steps", "7",
        ], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        initial = native.wait_state(state_path, fixture)
        pid = initial["pid"]
        image = subprocess.run(["/bin/ps", "-p", str(pid), "-o", "comm="],
                               capture_output=True, text=True, check=True, timeout=3)
        if Path(image.stdout.strip()).resolve() != Path(receipt["executable"]).resolve():
            raise RuntimeError("foreign fixture process")
        client = native.MCPStdio([
            str(driver), "mcp", "--embedded", "--socket", str(sock),
            "--host-bundle-id", "com.chriswozniczek.jevvoice",
        ], env, cwd=str(native.ROOT))
        client.start()
        client.initialize()
        tools = client.call("tools/list", timeout=5)
        schema = next(tool for tool in tools["tools"] if tool["name"] == "get_window_state")
        native.save(directory / "get-window-state-schema.json", schema)
        if os.environ.get("JARVIS_P4_NATIVE_SCHEMA_ONLY") == "1":
            return
        session = "p4-raw-" + uuid.uuid4().hex
        client.call("tools/call", {"name": "start_session", "arguments": {"session": session}}, timeout=5)
        for step in range(3):
            arguments = {"session": session, "pid": pid, "window_id": initial["window_id"],
                         "max_elements": 600, "max_depth": 20, "include_screenshot": False,
                         "tree_format": "both"}
            raw = client.call("tools/call", {"name": "get_window_state", "arguments": arguments}, timeout=8)
            native.save(directory / f"snapshot-{step}.json", raw)
            if step == 2:
                break
            content = raw.get("structuredContent", raw)
            element = next(e for e in content["elements"] if e.get("label") == "Continue")
            click = dict(session=session, pid=pid, window_id=initial["window_id"])
            if element.get("element_token"):
                click["element_token"] = element["element_token"]
            else:
                click.update(element_index=element["element_index"], snapshot_id=content["snapshot_id"])
            result = client.call("tools/call", {"name": "click", "arguments": click}, timeout=8)
            native.save(directory / f"click-{step}.json", result)
            time.sleep(0.15)
    finally:
        if client:
            client.close()
        if pid:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        native.stop(fixture)
        native.stop(daemon)
        print(directory)


if __name__ == "__main__":
    main()
