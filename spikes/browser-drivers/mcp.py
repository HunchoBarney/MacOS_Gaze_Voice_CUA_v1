"""Newline-delimited JSON-RPC MCP stdio client.

Adapted from bench/lib/mcp_stdio.py (client core only — the JevVoice
binary/keychain resolution is dropped; both spike children are spawned
with explicit argv). One JSON object per line in each direction — the
transport spoken by `cua-driver mcp --embedded` (MCPFrames,
Sources/JevVoiceCore/Models/JSONValue.swift) and by
chrome-devtools-mcp on stdio. Stdlib only.
"""

import json
import os
import select
import subprocess
import time

PROTOCOL_VERSION = "2025-06-18"


class MCPError(Exception):
    """Transport/RPC failure — the caller respawns the child."""


class MCPTimeout(MCPError):
    """A call exceeded its deadline; the child has been closed."""


class MCPStdio:
    """One MCP child. Sequential calls only — the spike never pipelines."""

    def __init__(self, argv, env, cwd=None, stderr=None):
        self.argv = list(argv)
        self.env = dict(env)
        self.cwd = cwd
        self.stderr = stderr
        self.proc = None
        self._buf = b""
        self._next_id = 0

    def start(self):
        if self.proc is not None and self.proc.poll() is None:
            return
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self.stderr, env=self.env, cwd=self.cwd)
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

    def initialize(self, timeout=120):
        """MCP handshake + notifications/initialized."""
        result = self.call("initialize", {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {},
            "clientInfo": {"name": "p2b-browser-drivers-spike", "version": "1"},
        }, timeout=timeout)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        return result

    def tool_call(self, name, arguments=None, timeout=120):
        """tools/call -> raw result dict (content/structuredContent/isError)."""
        return self.call("tools/call", {
            "name": name, "arguments": arguments or {}}, timeout=timeout)

    def tools_list(self):
        """tools/list -> {name: inputSchema} across cursors."""
        tools, cursors, cursor = {}, set(), None
        while True:
            params = {"cursor": cursor} if cursor else {}
            page = self.call("tools/list", params)
            for tool in page.get("tools", []):
                tools[tool["name"]] = tool.get("inputSchema", {})
            cursor = page.get("nextCursor")
            if not cursor or cursor in cursors:
                return tools
            cursors.add(cursor)


def tool_text(result):
    """(text, is_error) out of an MCP tool result dict."""
    if not isinstance(result, dict):
        return "", False
    texts = [str(c.get("text", "")) for c in result.get("content", [])
             if isinstance(c, dict) and c.get("type") == "text"]
    return "\n".join(t for t in texts if t), bool(result.get("isError"))
