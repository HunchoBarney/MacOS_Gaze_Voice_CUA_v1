import argparse
import copy
import json
import os
from pathlib import Path
import time
import urllib.request
from importlib.util import module_from_spec, spec_from_file_location


HERE = Path(__file__).resolve().parent
SPEC = spec_from_file_location("native_outcome_shared", HERE / "jev-native-picture-provenance-probe.py")
SHARED = module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_JEV_ADAPTIVE") != "approved-additional":
        raise SystemExit("approved synthetic model-only scope required")
    real = SHARED.SHARED.load("native_outcome_real", "jev-realapps.py")
    receipt = json.loads((args.capture / "capture-receipt.json").read_text())
    source_path = args.capture / "request-3.json"
    source = json.loads(source_path.read_text())
    if (receipt.get("status") != "captured" or receipt.get("qualification") is not False
            or receipt.get("drive_requests") != 0 or receipt.get("resources_clean") is not True
            or source["state"]["goal"] != "Calculate 3 plus 4 and show the result."
            or len(source["assets"]) != 1
            or {f["index"] for f in source["state"]["observed_facts"]} != {-1, -2}):
        raise RuntimeError("controlled frozen Calculator image required")
    args.out = SHARED.SHARED.private_output(args.out)
    facts = {"fact_" + str(i): fact for i, fact in enumerate(source["state"]["observed_facts"])}
    questions = {
        "scope": {"type": "choice",
            "instructions": "What kind of ENTIRE outcome does goal require, independently of whether it occurred?",
            "criteria": {
                "derived_ui": "An observed or computed read-only result displayed in this UI; not literal editing or persisted state.",
                "literal": "Entering, replacing, transforming or comparing exact requested literal text.",
                "hidden": "A saved file, persisted data, sent message, remote operation or other hidden backend result.",
                "unknown": "None of these can be established.",
            }},
        "native_fact": {"type": "choice",
            "instructions": "Select the actual native fact whose displayed value, together with current_image, "
                "establishes the ENTIRE requested goal now. A button offering an action is not an outcome. "
                "Use none when any requested condition is missing.",
            "criteria": {**facts, "none": "No native fact and current visible context establish the whole goal."}},
    }
    for name in facts:
        questions["support_" + name] = {
            "type": "noul", "instructions":
                f"Does native_goal_facts.{name}, together with the actual current_image and observed context, "
                "establish the ENTIRE outcome requested by goal for this same subject now? "
                "Its value must be the actual displayed result, not an offered action, partial progress or "
                "an assumed hidden effect. Other questions' answers are not available.",
        }
    report = {
        "qualification": False, "actuations": 0, "max_requests": 4, "max_seconds": 60,
        "purpose": "native UI outcome selection feasibility; not authority or release proof",
        "source_request_sha256": real.digest(source_path), "harness_sha256": real.digest(__file__),
        "rows": [],
    }
    key = real.require_api_key()
    deadline = time.monotonic() + 60
    for name, goal in [
        ("correct-result", "Calculate 3 plus 4 and show the result."),
        ("wrong-result", "Calculate 3 plus 5 and show the result."),
        ("literal-edit", "Replace the field contents with the exact text 7."),
        ("hidden-save", "Save the exact text 7 to a file."),
    ]:
        state = copy.deepcopy(source["state"])
        state["goal"] = goal
        state["native_goal_facts"] = facts
        payload = dict(model="jev-1.14.0", state=state, assets=source["assets"], questions=questions)
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("native outcome feasibility budget exhausted")
        with urllib.request.urlopen(urllib.request.Request(
            "https://api.typesafe.ai/v1/systemone", data=json.dumps(payload).encode(),
            headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                     "TypeSafe-Danger-Zone-Images": "true"},
        ), timeout=min(20, remaining)) as response:
            answer = json.load(response)
        SHARED.validate(answer, questions)
        report["rows"].append(dict(case=name, request=payload, response=answer))
        real.write_json(args.out / "results.json", report)
        print(name, answer["answers"], flush=True)


if __name__ == "__main__":
    main()
