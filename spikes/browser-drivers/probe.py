#!/usr/bin/env python3
"""P2b environment probe. Prints PASS or blocked_env per check and
records the block into results/results.json under "probe". Stdlib only.
"""

import base64
import hashlib
import http.client
import json
import os
import plistlib
import socket
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ops
from mcp import MCPError, MCPTimeout


def _check(name):
    return {"check": name, "status": None, "detail": "", "ms": None}


def _ws_handshake(port, path):
    """Raw stdlib ws handshake against the toggle endpoint -> 101."""
    key = base64.b64encode(os.urandom(16)).decode()
    sock = socket.create_connection(("127.0.0.1", port), timeout=10)
    try:
        req = ("GET %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\n"
               "Upgrade: websocket\r\nConnection: Upgrade\r\n"
               "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n"
               "\r\n" % (path, port, key))
        sock.sendall(req.encode())
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = sock.recv(4096)
            if not chunk:
                raise MCPError("ws handshake: connection closed")
            resp += chunk
        head = resp.split(b"\r\n\r\n", 1)[0].decode("latin1")
        status = head.splitlines()[0]
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()
        ).digest()).decode()
        if " 101 " not in status:
            raise MCPError("ws handshake status: %s" % status)
        if accept not in head:
            raise MCPError("ws handshake: bad Sec-WebSocket-Accept")
        return status
    finally:
        sock.close()


def main():
    checks = []

    # 1. daemon socket hint + bundled binary + real proxy handshake.
    c = _check("cua_daemon")
    t0 = time.monotonic()
    try:
        sock = ops.read_socket_hint()
        if not (os.path.isfile(ops.CUA_BIN)
                and os.access(ops.CUA_BIN, os.X_OK)):
            raise ops.BlockedEnv("bundled cua-driver not executable")
        client = ops.MCPStdio(
            [ops.CUA_BIN, "mcp", "--embedded", "--socket", sock,
             "--host-bundle-id", ops.HOST_BUNDLE_ID],
            env=dict(os.environ), stderr=subprocess.DEVNULL)
        try:
            client.start()
            init = client.initialize()
            tools = client.tools_list()
            c["status"] = "PASS"
            c["detail"] = ("socket=%s server=%s tools=%d"
                           % (sock, (init.get("serverInfo") or {})
                              .get("version", "?"), len(tools)))
        finally:
            client.close()
    except ops.BlockedEnv as exc:
        c["status"], c["detail"] = "blocked_env", str(exc)
    except (MCPError, OSError) as exc:
        c["status"], c["detail"] = "blocked_env", "proxy handshake: %s" % exc
    c["ms"] = round((time.monotonic() - t0) * 1000, 1)
    checks.append(c)

    # 2. DevToolsActivePort + real ws handshake + record /json/* 404.
    c = _check("devtools_ws_endpoint")
    t0 = time.monotonic()
    try:
        with open(ops.DEVTOOLS_PORT_FILE) as fh:
            lines = fh.read().splitlines()
        port, path = int(lines[0].strip()), lines[1].strip()
        status = _ws_handshake(port, path)
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        conn.request("GET", "/json/version")
        code = conn.getresponse().status
        conn.close()
        c["status"] = "PASS"
        c["detail"] = ("%s; /json/version -> %d (ws-only endpoint)"
                       % (status, code))
    except (OSError, MCPError, IndexError, ValueError) as exc:
        c["status"], c["detail"] = "blocked_env", str(exc)
    c["ms"] = round((time.monotonic() - t0) * 1000, 1)
    checks.append(c)

    # 3. Chrome >= 144.
    c = _check("chrome_version")
    try:
        with open(os.path.join(ops.CHROME_APP, "Contents/Info.plist"),
                  "rb") as fh:
            version = plistlib.load(fh).get("CFBundleShortVersionString", "")
        major = int(version.split(".")[0])
        if major < 144:
            raise ops.BlockedEnv("Chrome %s < 144" % version)
        if ops.chrome_pid() is None:
            raise ops.BlockedEnv("Chrome %s not running" % version)
        c["status"] = "PASS"
        c["detail"] = "Chrome %s running pid=%d" % (version,
                                                  ops.chrome_pid())
    except (OSError, ValueError, ops.BlockedEnv) as exc:
        c["status"], c["detail"] = "blocked_env", str(exc)
    checks.append(c)

    # 4. existing_profile feasibility: attach + read-only bind only.
    c = _check("cua_existing_profile")
    t0 = time.monotonic()
    sess = None
    try:
        sess, _ms, status, detail, _label = ops.attach("cua", "A")
        if sess is None:
            c["status"], c["detail"] = status, detail
        else:
            # One read-only snapshot against the bound tab — no mutation.
            r = sess.client.tool_call("get_browser_state", {
                "target_id": sess.target_id, "tab_id": sess.tab_id,
                "session": sess.label}, timeout=15)
            refused, d = ops._is_refusal(r)
            if refused or r.get("isError"):
                c["status"], c["detail"] = ("blocked_env",
                                            "bound read failed: %s" % d)
            else:
                c["status"] = "PASS"
                c["detail"] = ("bound target=%s tab=%s url=%s"
                               % (sess.target_id, sess.tab_id,
                                  ops._cap(sess.bound_url, 80)))
    except Exception as exc:
        c["status"], c["detail"] = "blocked_env", "%r" % exc
    finally:
        if sess is not None:
            ops.teardown(sess)
    c["ms"] = round((time.monotonic() - t0) * 1000, 1)
    checks.append(c)

    data = ops.load_results()
    data["probe"] = {"ran_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
                     "checks": checks}
    ops.save_results(data)

    worst = "PASS"
    for c in checks:
        print("%-24s %-11s %8sms  %s" % (c["check"], c["status"],
                                        c["ms"], c["detail"]))
        if c["status"] != "PASS":
            worst = "blocked_env"
    print("probe: %s" % worst)
    return 0 if worst == "PASS" else 1


if __name__ == "__main__":
    sys.exit(main())
