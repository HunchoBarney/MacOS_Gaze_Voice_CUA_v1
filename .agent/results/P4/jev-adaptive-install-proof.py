import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time
import urllib.request


ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
APP = Path.home() / "jarvis-local/Jev Voice.app"
INSTALLED = APP / "Contents/MacOS/JevVoice"
RELEASE = REPO / ".build/release/JevVoice"
OUTPUT = ROOT / "jev-adaptive-install-receipt.json"
if OUTPUT.exists():
    raise SystemExit("refusing to overwrite an installation receipt")
install_log = (ROOT / "jev-adaptive-install.log").read_text()
assert "Build complete!" in install_log and "Jev Voice is running" in install_log
late_ready = "tracker not ready after 90s" in install_log
assert "verification lane green" in install_log or late_ready, "installation has not finished"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def file_sections(path):
    listing = subprocess.check_output(["otool", "-l", str(path)], text=True)
    sections = []
    active = None
    for line in listing.splitlines():
        if line.strip() == "Section" or line.startswith("Load command"):
            if active:
                sections.append(active)
            active = {} if line.strip() == "Section" else None
        elif active is not None:
            parts = line.split()
            if len(parts) == 2 and parts[0] in {"sectname", "segname", "size", "offset", "flags"}:
                active[parts[0]] = parts[1]
    if active:
        sections.append(active)
    data = path.read_bytes()
    records = {}
    for section in sections:
        size = int(section["size"], 0)
        offset = int(section["offset"], 0)
        if not size or int(section["flags"], 0) & 0xff in {1, 12, 18}:
            continue
        assert 0 <= offset <= len(data) and offset + size <= len(data)
        name = section["segname"] + "." + section["sectname"]
        assert name not in records
        records[name] = {
            "length": size,
            "sha256": hashlib.sha256(data[offset:offset + size]).hexdigest(),
        }
    assert records and "__TEXT.__text" in records
    return records


measured = json.loads((ROOT / "jev-adaptive-after-repeat-r2.json").read_text())["source_sha256"]
for name, expected in measured.items():
    assert digest(REPO / name) == expected, name
installed_sections = file_sections(INSTALLED)
assert installed_sections == file_sections(RELEASE), "installed file-backed sections differ from release"
assert b"focus and enter text in one operation" in RELEASE.read_bytes(), "adaptive build marker absent"
verification = subprocess.run(
    ["codesign", "--verify", "--deep", "--strict", str(APP)],
    text=True, capture_output=True, check=True)
pattern = "^" + re.escape(str(INSTALLED)) + "( |$)"
pids = subprocess.check_output(["pgrep", "-f", pattern], text=True).split()
main_pids = []
for pid in pids:
    args = subprocess.check_output(["ps", "-p", pid, "-o", "args="], text=True)
    if "--mcp-stdio" not in args and "--headless" not in args:
        main_pids.append(int(pid))
assert main_pids, "normal app process is not running"
with urllib.request.urlopen("http://127.0.0.1:47892/ready", timeout=3) as response:
    status = response.status
assert status == 200
time.sleep(3)
for pid in main_pids:
    os.kill(pid, 0)
receipt = {
    "app": str(APP),
    "installation_lane_exit": 2 if late_ready else 0,
    "installation_tracker_wait_timed_out": late_ready,
    "installed_signed_sha256": digest(INSTALLED),
    "release_artifact_sha256": digest(RELEASE),
    "file_backed_macho_sections_match": True,
    "matching_section_count": len(installed_sections),
    "macho_sections": installed_sections,
    "codesign_deep_strict_exit": verification.returncode,
    "running_main_pids": main_pids,
    "process_rechecked_after_seconds": 3,
    "tracker_ready_http": status,
    "diagnostic_requests_spent_new_grant": json.loads(
        (ROOT / "jev-adaptive-grant.json").read_text())["spent"],
    "measured_source_sha256": measured,
    "additional_source_sha256": {
        name: digest(REPO / name) for name in [
            "Sources/JevVoice/Drive/DriveLoop.swift",
            "Sources/JevVoiceCore/Models/JevClient.swift",
            "Sources/JevVoiceCore/Models/JevModels.swift",
        ]
    },
}
OUTPUT.write_text(json.dumps(receipt, indent=2, sort_keys=True))
print(json.dumps({key: value for key, value in receipt.items()
                  if key not in {"macho_sections", "measured_source_sha256", "additional_source_sha256"}},
                 indent=2))
