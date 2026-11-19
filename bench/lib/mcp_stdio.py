"""Newline-delimited JSON-RPC MCP stdio client + binary/key resolution.

One JSON object per line in each direction on the child's stdio — the
transport `Jarvis --mcp-stdio --agent <slug>` speaks
(Sources/Jarvis/Drive/CuaDriveServer.swift). Stdlib only.
"""

import json
import os
import select
import subprocess
import time

PROTOCOL_VERSION = "2025-06-18"
INSTALLED_BINARY = os.path.expanduser(
    "~/jarvis-local/Jarvis.app/Contents/MacOS/Jarvis")
KEYCHAIN_SERVICE = "com.karanvirkang.jarvis"
KEYCHAIN_ACCOUNT = "typesafeAPIKey"


class MCPError(Exception):
    """Transport/RPC failure — the caller respawns the child."""


class MCPTimeout(MCPError):
    """A call exceeded its deadline; the child has been closed."""


class MCPStdio:
    """One MCP child. Sequential calls only — the bench never pipelines."""

    def __init__(self, argv, env, cwd=None):
        self.argv = list(argv)
        self.env = dict(env)
        self.cwd = cwd
        self.proc = None
        self._buf = b""
        self._next_id = 0

    def start(self):
        if self.proc is not None and self.proc.poll() is None:
            return
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            env=self.env, cwd=self.cwd)  # stderr passes through to ours
        self._buf = b""
        self._next_id = 0

    def close(self):
        """Terminate -> wait 2s -> kill; never leaves a zombie."""
        proc, self.proc = self.proc, None
        if proc is None:
            return
        try:
            if proc.stdin:
                proc.stdin.close()
        except OSError:
            pass
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=2)
        else:
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()

    def _send(self, frame):
        self.proc.stdin.write((json.dumps(frame) + "\n").encode())
        self.proc.stdin.flush()

    def _readline(self, deadline):
        """Next stdout line (str), None on EOF, MCPTimeout at deadline."""
        fd = self.proc.stdout.fileno()
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                return line.decode("utf-8", "replace")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise MCPTimeout("read deadline exceeded")
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise MCPTimeout("read deadline exceeded")
            chunk = os.read(fd, 65536)
            if not chunk:
                return None
            self._buf += chunk

    def call(self, method, params=None, timeout=120):
        """One request -> parsed `result` dict. MCPError on error
        frame/EOF; MCPTimeout (after close()) on deadline."""
        if self.proc is None or self.proc.poll() is not None:
            raise MCPError("mcp child is not running")
        self._next_id += 1
        rid = self._next_id
        frame = {"jsonrpc": "2.0", "id": rid, "method": method}
        if params is not None:
            frame["params"] = params
        try:
            self._send(frame)
        except (BrokenPipeError, OSError) as exc:
            raise MCPError("write to mcp child failed: %s" % exc) from exc
        deadline = time.monotonic() + timeout
        try:
            while True:
                line = self._readline(deadline)
                if line is None:
                    raise MCPError("mcp child closed stdout")
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue  # not a JSON object — skip
                if not isinstance(obj, dict) or obj.get("id") != rid:
                    continue  # notification or stale response — skip
                if obj.get("error") is not None:
                    raise MCPError("rpc error: %s" % obj["error"])
                return obj.get("result")
        except MCPTimeout:
            self.close()
            raise

    def initialize(self):
        """MCP handshake + notifications/initialized."""
        result = self.call("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "jev-bench", "version": "1"},
        })
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result

    def drive_until(self, goal, app=None, timeout=120):
        """tools/call drive_until -> (result text, is_error, elapsed_ms)."""
        arguments = {"goal": goal}
        if app:
            arguments["app"] = app
        t0 = time.perf_counter()
        result = self.call("tools/call", {
            "name": "drive_until", "arguments": arguments}, timeout=timeout)
        elapsed_ms = (time.perf_counter() - t0) * 1000.0
        text, is_error = tool_text(result)
        return text, is_error, elapsed_ms


def tool_text(result):
    """(text, is_error) out of an MCP tool result dict."""
    if not isinstance(result, dict):
        return "", False
    texts = [str(c.get("text", "")) for c in result.get("content", [])
             if isinstance(c, dict) and c.get("type") == "text"]
    return "\n".join(t for t in texts if t), bool(result.get("isError"))


def resolve_binary(repo_root, override=None):
    """--binary wins; else the installed app, else .build/release."""
    if override:
        if os.path.isfile(override) and os.access(override, os.X_OK):
            return override
        raise MCPError("--binary %s is not an executable file" % override)
    release = os.path.join(str(repo_root), ".build", "release", "Jarvis")
    for path in (INSTALLED_BINARY, release):
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    raise MCPError(
        "no Jarvis binary: looked at %s and %s (or pass --binary)"
        % (INSTALLED_BINARY, release))


def require_api_key():
    """TYPESAFE_API_KEY from the env, else the Keychain item. Returns
    None when unavailable; the value is never logged or written."""
    key = os.environ.get("TYPESAFE_API_KEY", "").strip()
    if key:
        return key
    try:
        out = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE,
             "-a", KEYCHAIN_ACCOUNT, "-w"],
            capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    return out.stdout.strip() or None
