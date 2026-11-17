import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import urllib.error
import urllib.request


HERE = Path(__file__).resolve().parent
CAPTURE = Path("/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/"
               "development/JevVoice/c1-scroll-request-r4-second")
SOURCE_SHA = "571b2585e905348a086944dfacb8905e9cbe8d8160c6e13afc7c65e2dd492dfd"


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, HERE / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--include-scroll-arguments", action="store_true")
    parser.add_argument("--include-window-scope", action="store_true")
    args = parser.parse_args()
    if os.environ.get("JARVIS_C1_SCROLL_SUPPORT_DIAGNOSTIC") != "approved":
        raise SystemExit("C1 model-only support diagnosis approval required")
    real = load("c1_scroll_support_real", "jev-realapps.py")
    validation = load("c1_scroll_support_validation", "jev-native-picture-provenance-probe.py")
    receipt = json.loads((CAPTURE / "receipt.json").read_text())
    source = CAPTURE / "fragment-prototype-request.json"
    if (real.digest(source) != SOURCE_SHA or receipt.get("qualification") is not False
            or receipt.get("captured") is not True or receipt.get("documents_restored") is not True
            or receipt.get("content_unchanged") is not True
            or real.digest(CAPTURE / "request-0.json") != receipt["body_sha256"]):
        raise RuntimeError("verified owned native capture required")
    original = json.loads(source.read_text())
    if (original["model"] != "jev-1.14.0"
            or original["state"]["goal"] != "scroll down"
            or original["state"]["current_instruction"] != "scroll down"
            or original["state"]["app"] != "com.apple.TextEdit"
            or len(original["state"]["available_actions"]) != 20):
        raise RuntimeError("unexpected captured request")
    baseline = original["questions"]["action_support_15"]
    if "candidate_details.scroll:down" not in baseline["instructions"]:
        raise RuntimeError("captured support question must concern scroll down")
    prefix = ("For an implicit multi-step goal, this exact operation on the identified target is one "
              "legitimate immediate step of currently unfinished work, including UI preparation implied by "
              "the requested end state.")
    if not baseline["criteria"]["true"].startswith(prefix):
        raise RuntimeError("captured support criterion differs")
    proposed = copy.deepcopy(baseline)
    proposed["criteria"]["true"] = (
        "This exact operation on the identified target directly carries out the user's current instruction, "
        "or is one legitimate immediate step of currently unfinished work in an implicit multi-step goal, "
        "including UI preparation implied by the requested end state."
        + baseline["criteria"]["true"][len(prefix):])
    questions = {"baseline": baseline, "direct_or_preparation": proposed}
    output = args.out.resolve()
    if output.parent != CAPTURE.parent.resolve() or not output.name.startswith("c1-scroll-support-"):
        raise RuntimeError("private C1 diagnostic output location required")
    output.mkdir(mode=0o700)
    report = {
        "qualification": False, "actuations": 0, "source_request_sha256": SOURCE_SHA,
        "harness_sha256": real.digest(__file__), "status": "running", "rows": [],
        "boundary": "older retained native R4 state, no UI or product execution; no source/policy promotion",
        "hypothesis": "TRUE criterion may omit explicit single-step instructions",
        "fixed_cases": ["direct", "opposite", "other-window", "status-only", "explicit-page"],
        "state_changes": "only goal/current_instruction in declared counterfactual cases; all candidates retained",
        "question_changes": "only TRUE criterion's first sentence in proposed Noul",
        "support_floor_unchanged": 0.9,
        "include_scroll_arguments": args.include_scroll_arguments,
        "include_window_scope": args.include_window_scope,
    }
    if args.include_scroll_arguments:
        definition = HERE.parents[2] / "Sources/JevVoice/Drive/DriveCandidates.swift"
        source_text = definition.read_text()
        expected = ('args: ["direction": .string(dir),\n'
                    '                           "by": .string("page"), "amount": .number(1),\n'
                    '                           "delivery_mode": .string("background")]')
        if expected not in source_text:
            raise RuntimeError("declared scroll arguments differ from production")
        report["state_changes"] += "; add actual declared scroll-down arguments, no inferred scope or permission"
        report["argument_source_sha256"] = real.digest(definition)
    if args.include_window_scope:
        report["state_changes"] += "; declare operation target as the existing observed bound app/window, no named-region or permission claim"
        report["scope_source_sha256"] = real.digest(HERE.parents[2] / "Sources/JevVoice/Drive/DriveLoop.swift")
    real.write_json(output / "results.json", report)
    key = real.require_api_key()
    if not key:
        raise RuntimeError("existing TypeSafe key unavailable")
    cases = [
        ("direct", "scroll down"),
        ("opposite", "scroll up"),
        ("other-window", "Scroll the other window down. Keep this window unchanged."),
        ("status-only", "Do not scroll. Tell me whether this document is at the top."),
        ("explicit-page", "Scroll down one page in this window."),
    ]
    if args.include_window_scope:
        cases.append(("sidebar", "Scroll the sidebar down. Keep the main document unchanged."))
        report["fixed_cases"].append("sidebar")
    try:
        for label, goal in cases:
            state = copy.deepcopy(original["state"])
            state["goal"] = goal
            state["current_instruction"] = goal
            if args.include_scroll_arguments:
                state["candidate_details"]["scroll:down"]["arguments"] = {
                    "direction": "down", "by": "page", "amount": 1, "delivery_mode": "background",
                }
            if args.include_window_scope:
                state["candidate_details"]["scroll:down"]["target_scope"] = {
                    "kind": "window", "app": state["app"], "window": state["window"],
                }
            payload = {"model": original["model"], "state": state, "questions": questions}
            wire = json.dumps(payload).encode()
            real.write_json(output / ("request-" + label + ".json"), payload)
            with urllib.request.urlopen(urllib.request.Request(
                    "https://api.typesafe.ai/v1/systemone", data=wire,
                    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"}),
                    timeout=30) as response:
                answer = json.load(response)
            validation.validate(answer, questions)
            real.write_json(output / ("response-" + label + ".json"), answer)
            values = {name: answer["answers"][name]["noul"] for name in questions}
            report["rows"].append({"case": label, "probabilities": values,
                                   "request_sha256": hashlib.sha256(wire).hexdigest()})
            real.write_json(output / "results.json", report)
            print(label, values, flush=True)
        report["status"] = "completed"
    except urllib.error.HTTPError as error:
        report["status"] = "http_failure"
        report["http_status"] = error.code
        raise
    except BaseException as error:
        report["status"] = "failed"
        report["error_type"] = type(error).__name__
        raise
    finally:
        real.write_json(output / "results.json", report)


if __name__ == "__main__":
    main()
