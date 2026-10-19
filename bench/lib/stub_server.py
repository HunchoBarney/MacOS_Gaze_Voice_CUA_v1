#!/usr/bin/env python3
"""Stub MCP stdio server — BENCH_STUB=1 backend + selftest fixture.

Speaks newline JSON-RPC on stdin/stdout. `tools/call drive_until` returns
canned result text keyed on a substring of `goal` so every classifier
status is reachable without the app. `--delay ms` stalls every reply.

Run: python3 bench/lib/stub_server.py [--delay 250]
"""

import json
import sys
import time

DELAY_MS = 0.0

TOOLS = [
    {"name": "drive_until",
     "description": "Stub: canned result text by goal keyword.",
     "inputSchema": {"type": "object",
                     "properties": {"goal": {"type": "string"},
                                    "app": {"type": "string"}},
                     "required": ["goal"]}},
    {"name": "suggest_action",
     "description": "Stub: one canned suggestion.",
     "inputSchema": {"type": "object",
                     "properties": {"goal": {"type": "string"},
                                    "app": {"type": "string"}},
                     "required": ["goal"]}},
]


def emit(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def reply(rid, payload):
    emit({"jsonrpc": "2.0", "id": rid, "result": payload})


def tool_result(text, is_error=False):
    payload = {"content": [{"type": "text", "text": text}]}
    if is_error:
        payload["isError"] = True
    return payload


def canned(goal):
    """goal substring -> canned drive_until result payload."""
    g = goal.lower()
    if "sleep" in g:
        time.sleep(30)  # timeout testing — the client must fire first
        return tool_result("Done. slept")
    if "succeed" in g:
        return tool_result("Done.")
    if "already" in g:
        return tool_result("Already satisfied: x.")
    if "refuse" in g:
        return tool_result("Refused by policy. No grant or approval path "
                           "changes that.")
    if "blocked" in g:
        return tool_result("Blocked: x")
    if "stuck" in g:
        return tool_result("Stuck: x. tail")
    if "needsinput" in g:
        return tool_result("Needs input: text for x.")
    if "ambiguous" in g:
        return tool_result("Ambiguous: which of a, b?")
    if "maxsteps" in g:
        return tool_result("Ran out of steps. x")
    if "cancel" in g:
        return tool_result("Cancelled.")
    if "iserror" in g:
        return tool_result("TYPESAFE_API_KEY is not configured for this "
                           "agent.", is_error=True)
    return tool_result("Done.")


def main():
    global DELAY_MS
    argv = sys.argv[1:]
    if "--delay" in argv:
        DELAY_MS = float(argv[argv.index("--delay") + 1])
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            frame = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(frame, dict) or "id" not in frame:
            continue  # notifications get no reply
        rid, method = frame["id"], frame.get("method")
        if DELAY_MS:
            time.sleep(DELAY_MS / 1000.0)
        if method == "initialize":
            # A spec-legal notification before the response — exercises
            # the client's non-response-frame skip path.
            emit({"jsonrpc": "2.0", "method": "notifications/message",
                  "params": {"level": "info", "data": "stub up"}})
            reply(rid, {
                "protocolVersion": (frame.get("params") or {}).get(
                    "protocolVersion", "2025-06-18"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "jev-bench-stub", "version": "1"}})
        elif method == "ping":
            reply(rid, {})
        elif method == "tools/list":
            reply(rid, {"tools": TOOLS})
        elif method == "tools/call":
            params = frame.get("params") or {}
            args = params.get("arguments") or {}
            if params.get("name") == "drive_until":
                reply(rid, canned(str(args.get("goal", ""))))
            elif params.get("name") == "suggest_action":
                reply(rid, tool_result("Suggested: click the obvious thing."))
            else:
                reply(rid, tool_result(
                    "Unknown tool %s." % params.get("name"), is_error=True))
        else:
            emit({"jsonrpc": "2.0", "id": rid, "error": {
                "code": -32601, "message": "Unknown method %s" % method}})


if __name__ == "__main__":
    main()
