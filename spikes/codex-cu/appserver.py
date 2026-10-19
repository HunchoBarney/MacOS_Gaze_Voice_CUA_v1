"""Line-framed JSON-RPC client for `codex app-server` (stdio). Stdlib only.

One JSON object per line each way, WITHOUT a "jsonrpc" member. Adapted
from bench/lib/mcp_stdio.py: spawn, deadline reads, kill-on-timeout.
Server->client requests (approvals, user input, elicitations) are
answered by a pluggable `answer` callback — an unanswered request hangs
the turn. The default answerer DECLINES everything: no human is present.
"""

import json
import os
import select
import shutil
import signal
import subprocess
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
CODEX_BIN = os.path.join(REPO, "build", "vendor", "CodexRuntime", "bin",
                         "codex")
CODEX_VERSION = "0.160.0"
SPIKE_HOME = os.path.join(HERE, "home")
HOST_AUTH = os.path.expanduser("~/.codex/auth.json")
ENV_ALLOW = ("PATH", "LANG", "LC_ALL", "TMPDIR", "USER", "LOGNAME",
             "SHELL", "TERM", "__CF_USER_TEXT_ENCODING", "HTTP_PROXY",
             "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy",
             "https_proxy", "all_proxy", "no_proxy", "SSL_CERT_FILE")


class RPCError(Exception):
    """Transport/RPC failure."""


class RPCTimeout(RPCError):
    """A read deadline passed."""


def child_env(codex_home):
    """Allowlist env — never the full host env. HOME is the spike home."""
    env = {k: os.environ[k] for k in ENV_ALLOW if k in os.environ}
    env.setdefault("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    env["HOME"] = SPIKE_HOME
    env["CODEX_HOME"] = codex_home
    return env


def make_home(name, config_toml=""):
    """Fresh CODEX_HOME under spikes/codex-cu/home/<name>: auth.json is a
    SYMLINK to the existing login (contents never read), plus config."""
    home = os.path.join(SPIKE_HOME, name)
    if os.path.isdir(home) and os.path.realpath(home).startswith(
            os.path.realpath(SPIKE_HOME) + os.sep):
        shutil.rmtree(home)  # unlinks the auth symlink, never follows it
    os.makedirs(home)
    if os.path.lexists(HOST_AUTH):
        os.symlink(HOST_AUTH, os.path.join(home, "auth.json"))
    with open(os.path.join(home, "config.toml"), "w") as f:
        f.write(config_toml)
    return home


def decline(method, params):
    """No-human answerer: the most conservative valid reply per method."""
    if method in ("item/commandExecution/requestApproval",
                  "item/fileChange/requestApproval"):
        return {"decision": "decline"}
    if method in ("execCommandApproval", "applyPatchApproval"):
        return {"decision": "denied"}
    if method == "mcpServer/elicitation/request":
        return {"action": "decline"}
    if method == "item/permissions/requestApproval":
        return {"permissions": {}}
    if method == "item/tool/requestUserInput":
        return {"answers": {}}
    if method == "item/tool/call":
        return {"contentItems": [], "success": False}
    return None  # -> JSON-RPC error reply


def form_defaults(schema):
    """Accept-content for a form elicitation: each field's default, else the
    first enum/const option, else True for booleans."""
    out = {}
    for name, p in ((schema or {}).get("properties") or {}).items():
        if p.get("default") is not None:
            out[name] = p["default"]
        elif p.get("enum"):
            out[name] = p["enum"][0]
        elif p.get("oneOf"):
            out[name] = p["oneOf"][0].get("const")
        elif p.get("type") == "boolean":
            out[name] = True
    return out


def allowlist(apps):
    """Programmatic client policy (no human): ACCEPT an MCP elicitation only
    when its message/meta names an allow-listed app (bundle id or display
    name); every other server request falls through to `decline`."""
    keys = [a.lower() for a in apps]

    def answer(method, params):
        if method == "mcpServer/elicitation/request":
            blob = json.dumps({k: params.get(k) for k in ("message", "_meta")
                               }).lower()
            if params.get("mode") != "url" and any(k in blob for k in keys):
                return {"action": "accept",
                        "content": form_defaults(params.get("requestedSchema"))}
            return {"action": "decline"}
        return decline(method, params)
    return answer


class AppServer:
    """One `codex app-server` child in its own process group."""

    def __init__(self, codex_home, cwd=None, extra_args=(), log=None,
                 answer=decline):
        self.codex_home = codex_home
        self.argv = [CODEX_BIN, "app-server"] + list(extra_args)
        self.cwd = cwd or HERE
        self.log = log  # callable(direction, obj) or None
        self.answer = answer
        self.proc = None
        self._buf = b""
        self._next_id = 0
        self.notifications = []  # unread notifications, in order
        self.server_requests = []  # every server->client request + reply
        self.stderr_path = os.path.join(codex_home, "app-server.stderr")

    def start(self):
        self._err = open(self.stderr_path, "ab")
        self.proc = subprocess.Popen(
            self.argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=self._err, env=child_env(self.codex_home), cwd=self.cwd,
            start_new_session=True)
        return self

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def close(self, grace=3.0):
        """close stdin -> wait -> SIGTERM group -> wait -> SIGKILL group."""
        proc, self.proc = self.proc, None
        if proc is None:
            return
        try:
            proc.stdin.close()
        except OSError:
            pass
        for sig, wait in ((None, grace), (signal.SIGTERM, 2.0),
                          (signal.SIGKILL, 2.0)):
            if sig is not None:
                try:
                    os.killpg(proc.pid, sig)
                except (ProcessLookupError, PermissionError):
                    pass
            try:
                proc.wait(timeout=wait)
                break
            except subprocess.TimeoutExpired:
                continue
        try:
            os.killpg(proc.pid, signal.SIGKILL)  # stragglers in the group
        except (ProcessLookupError, PermissionError):
            pass
        try:
            self._err.close()
        except Exception:
            pass

    def _send(self, frame):
        if self.log:
            self.log(">", frame)
        try:
            self.proc.stdin.write((json.dumps(frame) + "\n").encode())
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError, AttributeError) as exc:
            raise RPCError("write to app-server failed: %s" % exc) from exc

    def _readline(self, deadline):
        fd = self.proc.stdout.fileno()
        while True:
            nl = self._buf.find(b"\n")
            if nl >= 0:
                line, self._buf = self._buf[:nl], self._buf[nl + 1:]
                return line.decode("utf-8", "replace")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RPCTimeout("read deadline exceeded")
            ready, _, _ = select.select([fd], [], [], min(remaining, 1.0))
            if not ready:
                continue
            chunk = os.read(fd, 1 << 20)
            if not chunk:
                return None
            self._buf += chunk

    def _dispatch(self, obj):
        """Route one inbound frame; returns it if it is a response."""
        if "method" in obj and "id" in obj:  # server -> client request
            method, params = obj["method"], obj.get("params") or {}
            reply = self.answer(method, params)
            entry = {"id": obj["id"], "method": method, "params": params,
                     "reply": reply, "t": time.time()}
            self.server_requests.append(entry)
            if reply is None:
                self._send({"id": obj["id"], "error": {
                    "code": -32601, "message": "spike client: unsupported"}})
            else:
                self._send({"id": obj["id"], "result": reply})
            return None
        if "method" in obj:
            self.notifications.append(obj)
            return None
        return obj

    def pump(self, timeout):
        """Read frames until `timeout` elapses or EOF. Returns False on EOF."""
        deadline = time.monotonic() + timeout
        while True:
            try:
                line = self._readline(deadline)
            except RPCTimeout:
                return True
            if line is None:
                return False
            obj = self._parse(line)
            if obj is not None:
                self._dispatch(obj)

    def next_notification(self, deadline):
        """Next notification (dict) before `deadline`; None on EOF;
        RPCTimeout at deadline."""
        while not self.notifications:
            line = self._readline(deadline)
            if line is None:
                return None
            obj = self._parse(line)
            if obj is not None:
                self._dispatch(obj)
        return self.notifications.pop(0)

    def _parse(self, line):
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            return None
        if not isinstance(obj, dict):
            return None
        if self.log:
            self.log("<", obj)
        return obj

    def call(self, method, params=None, timeout=60):
        """Request -> result. Notifications/server requests arriving
        meanwhile are queued/answered. RPCError on error frame/EOF."""
        if not self.alive():
            raise RPCError("app-server is not running")
        self._next_id += 1
        rid = self._next_id
        frame = {"id": rid, "method": method}
        if params is not None:
            frame["params"] = params
        self._send(frame)
        deadline = time.monotonic() + timeout
        while True:
            line = self._readline(deadline)
            if line is None:
                raise RPCError("app-server closed stdout during %s" % method)
            obj = self._parse(line)
            if obj is None:
                continue
            resp = self._dispatch(obj)
            if resp is None or resp.get("id") != rid:
                continue
            if resp.get("error") is not None:
                raise RPCError("%s -> %s" % (method, resp["error"]))
            return resp.get("result")

    def notify(self, method, params=None):
        frame = {"method": method}
        if params is not None:
            frame["params"] = params
        self._send(frame)

    def initialize(self, timeout=30):
        result = self.call("initialize", {
            "clientInfo": {"name": "p2c-spike", "version": "1"},
            "capabilities": {"experimentalApi": True}}, timeout=timeout)
        self.notify("initialized", {})
        return result
