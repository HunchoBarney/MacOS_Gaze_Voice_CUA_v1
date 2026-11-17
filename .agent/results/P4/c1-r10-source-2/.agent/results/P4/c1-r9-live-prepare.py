import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import time
import uuid


root = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument("--label", choices=("final-r9", "final-r9-2", "final-r10"), required=True)
arguments = parser.parse_args()
receipt_path = root / f".agent/results/P12/c1-{arguments.label}-stage.json"
receipt = json.loads(receipt_path.read_text())
app = Path(receipt["app"])
binary = app / "Contents/MacOS/JevVoice"
assert hashlib.sha256(binary.read_bytes()).hexdigest() == receipt["binary_sha256"]
subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
identifier = uuid.uuid4().hex[:10]
prefix = "c1-r10" if arguments.label == "final-r10" else "c1-r9"
evidence = root / ".agent/results/P4" / (prefix + "-live-" + identifier)
fixtures = root / ".agent/results/P3" / ("user-audit-" + prefix + "-live-" + identifier)
evidence.mkdir(mode=0o700)
fixtures.mkdir(mode=0o700)
fixture = fixtures / "Jev hands-free check.txt"
text = (
    "Jev hands-free check\n\n"
    "Use your own words. No Fn key is needed for this conversation.\n"
    "Try moving down this document, asking for a little more, continuing, and stopping.\n"
    "You can also ask to open Calculator, then return here.\n"
    "This is a disposable document; it is long enough to make scrolling visible.\n\n"
    + "\n".join(f"Reading position {index:03d}." for index in range(1, 301))
    + "\nEnd of the document.\n"
)
fixture.write_text(text)
os.chmod(fixture, 0o600)
record = {
    "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
    "app": str(app),
    "binary_sha256": receipt["binary_sha256"],
    "stage_receipt_sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
    "runner_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    "same_preparation_method_as": "c1-r8-live-prepare.py",
    "source": "normal LaunchServices launch",
    "voice_provider": receipt.get("voice_provider", "local"),
    "evidence_directory": str(evidence),
    "fixture": str(fixture),
    "fixture_initial_sha256": hashlib.sha256(fixture.read_bytes()).hexdigest(),
    "physical_input_proven": False,
    "phase_acceptance": False,
    "jev_request_or_spend_cap_added": False,
    "raw_audio_recording_requested": False,
}
subprocess.run(
    ["open", "-n", "--env", f"JARVIS_VOICE_EVIDENCE_DIR={evidence}",
     "--stdout", str(evidence / "app.stdout.log"),
     "--stderr", str(evidence / "app.stderr.log"), str(app)],
    check=True, timeout=30,
)
deadline = time.monotonic() + 30
while time.monotonic() < deadline and not list(evidence.glob("health-*.json")):
    time.sleep(0.5)
record["health"] = [json.loads(path.read_text()) for path in evidence.glob("health-*.json")]
record["status"] = "controller_initialized_human_check_pending" if record["health"] else "startup_pending"
subprocess.run(["open", "-a", "TextEdit", str(fixture)], check=True, timeout=15)
record["fixture_opened"] = True
preparation = evidence / "preparation.json"
preparation.write_text(json.dumps(record, indent=2) + "\n")
(root / ".agent/results/P4" / (prefix + "-physical-current.json")).write_text(
    json.dumps({"preparation": str(preparation), **record}, indent=2) + "\n"
)
print(json.dumps({"status": record["status"], "preparation": str(preparation), "health": record["health"]}))
