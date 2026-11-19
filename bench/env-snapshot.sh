#!/usr/bin/env bash
# Snapshot the bench environment -> bench/results/env-<UTC ts>.json.
# No secrets: never reads or prints Keychain material.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTDIR="$ROOT/bench/results"
mkdir -p "$OUTDIR"
TS="$(date -u +%Y%m%dT%H%M%SZ)"
python3 - "$TS" "$ROOT" "$OUTDIR/env-$TS.json" <<'PY'
import json
import os
import platform
import plistlib
import socket
import subprocess
import sys

ts, root, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(root, "bench"))
from lib.mcp_stdio import resolve_binary


def sh(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True,
                              timeout=10).stdout.strip()
    except Exception:
        return ""


support = os.path.expanduser("~/Library/Application Support/Jarvis")

sock_path = os.environ.get("JEV_CUA_SOCKET") or None
if not sock_path:
    try:
        sock_path = open(os.path.join(support, "cua.socket")) \
            .read().strip() or None
    except OSError:
        sock_path = None
reachable = False
if sock_path:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(sock_path)
        s.close()
        reachable = True
    except OSError:
        reachable = False

grant = None
try:
    grant = bool(json.load(open(os.path.join(support, "policy.json")))
                 .get("standingGrant"))
except Exception:
    grant = None

try:
    ram = int(sh(["sysctl", "-n", "hw.memsize"]))
    ram_gb = round(ram / (1 << 30)) or None
except Exception:
    ram_gb = None

plist = os.path.expanduser(
    "~/jarvis-local/Jarvis.app/Contents/Info.plist")
try:
    with open(plist, "rb") as fh:
        app_version = plistlib.load(fh).get(
            "CFBundleShortVersionString", "unknown")
except Exception:
    app_version = "not-installed"

try:
    binary = resolve_binary(root)
except Exception:
    binary = "missing"

doc = {
    "ts": ts,
    "sw_vers_productversion": sh(["sw_vers", "-productVersion"]),
    "hw_model": sh(["sysctl", "-n", "hw.model"]),
    "ram_gb": ram_gb,
    "arch": platform.machine(),
    "app_version": app_version,
    "daemon_socket_reachable": reachable,
    "standing_grant": grant,
    "binary": binary,
}
with open(out_path, "w") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
print(out_path)
PY
