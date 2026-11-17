import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import time
import urllib.request


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("r7_semantic_meaning", HERE / "c1-r7-semantic-probe.py")
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)


def refine(payload):
    value = BASE.proposed(payload)
    questions = value["questions"]
    questions["complete"]["instructions"] += (
        " A linguistically complete request can concern an unavailable target or an unsupported "
        "scroll direction; capability and target availability are checked separately. "
        "Scrolling a window describes moving its content viewport, not moving the window frame.")
    questions["bounded_window_scroll"]["criteria"]["true"] = (
        "The requested result is one small or ordinary movement of the current window's content "
        "viewport in one direction. A relative small shift or one additional movement is still "
        "one bounded movement. Independently proved movement would satisfy the whole instruction.")
    questions["bounded_window_scroll"]["criteria"]["false"] = (
        "A named region/sidebar, another app/window, exact distance/units/pages/counts, explicit "
        "multiple or continuous movements, until/end condition, visible target, hidden/persisted "
        "state, another action or unrepresented condition remains. Also false for ambiguous, "
        "negated, quoted, reported, example or status-only commands, or moving the window frame. "
        "A useful first step is insufficient.")
    return value


def main():
    if os.environ.get("JARVIS_C1_REAL_JEV") != "approved":
        raise SystemExit("Approved read-only semantic diagnosis required")
    output = HERE / "c1-r7-semantic-meaning-refined"
    output.mkdir(mode=0o700)
    key = BASE.require_api_key()
    if not key:
        raise SystemExit("Existing Jev credential unavailable")
    original = HERE / "c1-r7-semantic-before"
    inputs = [json.loads((original / f"case-{i}.request.json").read_text()) for i in range(14)]
    prototype = HERE / "c1-r7-semantic-meaning-prototype"
    for index in range(14, 22):
        inputs.append(json.loads((prototype / f"case-{index}.request.json").read_text()))
    for text in ["Okay, keep scrolling.", "Keep going.", "A little more.", "Stop.",
                 "That's enough.", "Don't stop.", "The other way a little."]:
        value = copy.deepcopy(inputs[0])
        value["state"]["utterance"] = text
        value["state"]["conversation"] = {
            "last_request": "Scroll down a little.", "last_request_verified": True,
            "last_scope": {"app": "com.apple.TextEdit", "window": 41},
            "verified_scroll": {
                "scope": {"app": "com.apple.TextEdit", "window": 41}, "direction": "down", "small": True,
            },
        }
        inputs.append(value)
    rows = []
    report = {
        "qualification": False, "actions": 0, "microphone": False,
        "not_a_latency_benchmark": True, "cases": len(inputs), "rows": rows,
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "base_source_sha256": hashlib.sha256((HERE / "c1-r7-semantic-probe.py").read_bytes()).hexdigest(),
        "scope": "Read-only semantic feasibility/sufficiency refinement and controlled follow-up fixtures",
    }
    for index, original in enumerate(inputs):
        payload = refine(original)
        BASE.write(output / f"case-{index}.request.json", payload)
        request = urllib.request.Request(
            "https://api.typesafe.ai/v1/systemone", data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
        started = time.monotonic()
        with urllib.request.urlopen(request, timeout=12) as response:
            body = response.read()
        (output / f"case-{index}.response.json").write_bytes(body)
        data = json.loads(body)
        rows.append({"index": index, "utterance": original["state"]["utterance"],
                     "model": data.get("model"), "elapsed_ms": (time.monotonic() - started) * 1000,
                     "answers": data.get("answers", {})})
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"directory": str(output), "requests": len(rows), "actions": 0}))


if __name__ == "__main__":
    main()
