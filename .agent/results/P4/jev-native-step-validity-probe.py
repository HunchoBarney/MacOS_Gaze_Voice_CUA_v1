import argparse
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import time
import urllib.request


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("step_validity_shared", HERE / "jev-native-picture-provenance-probe.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_JEV_ADAPTIVE") != "approved-additional":
        raise SystemExit("approved model-only diagnosis required")
    real = SHARED.SHARED.load("step_validity_real", "jev-realapps.py")
    diagnostic = json.loads((args.capture / "diagnostic.json").read_text())
    refinement = json.loads((args.capture / "refinement-diagnostic.json").read_text())
    if (diagnostic.get("qualification") is not False or diagnostic.get("actuations") != 0
            or diagnostic.get("native_display_unchanged") is not True
            or not refinement.get("refinement_request_indices")):
        raise RuntimeError("actual readonly source refinement required")
    index = refinement["refinement_request_indices"][0]
    source = args.capture / f"request-{index}.json"
    original = json.loads(source.read_text())
    if (original["state"]["app"] != "com.apple.calculator"
            or original["state"]["goal"] != "Calculate 3 plus 4 and show the result."
            or original["state"]["current_instruction"] != original["state"]["goal"]):
        raise RuntimeError("controlled source state required")
    amended = copy.deepcopy(original["questions"])
    for name, question in amended.items():
        if not name.startswith("support_"):
            continue
        old = "implement the next unfinished operation requested by current_instruction on this target?"
        if old not in question["instructions"]:
            raise RuntimeError("production support wording changed")
        question["instructions"] = question["instructions"].replace(
            old, "be one legitimate immediate primitive step of currently unfinished work "
            "toward current_instruction on this target?"
        ) + (" Judge validity of this candidate, not whether it is uniquely best or most preferred. "
             "If the requested end state is already established by the current observed evidence, "
             "further input is not unfinished work unless a repeat is explicitly requested.")
        old_true = "This exact operation and identified target match the next requested step, including an intermediate step."
        if old_true not in question["criteria"]["true"]:
            raise RuntimeError("production support criteria changed")
        question["criteria"]["true"] = question["criteria"]["true"].replace(old_true,
            "For an implicit multi-step goal, this exact operation on the identified target is one "
            "legitimate immediate step of currently unfinished work, including UI preparation implied by "
            "the requested end state. "
            "It need not be the only valid next step. An explicitly requested control or operation must "
            "still match exactly. Preparation never authorizes another end goal, violating a constraint, "
            "or changing unrelated saved data.")
    args.out = SHARED.SHARED.private_output(args.out)
    shutil.copyfile(__file__, args.out / "probe-source.py")
    report = dict(qualification=False, actuations=0, max_requests=12, rows=[],
        purpose="actual source refinement: candidate validity versus unique-next-step wording",
        source_request_sha256=real.digest(source), harness_sha256=real.digest(__file__),
        source_scope="forced strict-floor read-only diagnostic, not a production signed trial")
    key = real.require_api_key()
    deadline = time.monotonic() + 90
    goals = [
        ("implicit", original["state"]["goal"]),
        ("explicit-three", 'Press the "3" button.'),
        ("read-only", "Do not modify anything. Read the current calculation."),
        ("no-clear", "Calculate 3 plus 4 without clearing the existing input."),
        ("already-done", "Calculate 2 plus 3 and show the result."),
        ("sidebar", "Show the sidebar."),
    ]
    for case, goal in goals:
        for variant, questions in [("baseline", original["questions"]), ("amended", amended)]:
            if time.monotonic() >= deadline:
                raise TimeoutError("validity probe budget exhausted")
            state = copy.deepcopy(original["state"])
            state.update(goal=goal, current_instruction=goal)
            payload = dict(model="jev-1.14.0", state=state, questions=questions)
            wire = json.dumps(payload).encode()
            label = case + "-" + variant
            real.write_json(args.out / ("request-" + label + ".json"), payload)
            (args.out / ("wire-" + label + ".json")).write_bytes(wire)
            with urllib.request.urlopen(urllib.request.Request(
                "https://api.typesafe.ai/v1/systemone", data=wire,
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
            ), timeout=min(20, deadline - time.monotonic())) as response:
                answer = json.load(response)
            SHARED.validate(answer, questions)
            row = dict(case=label, request=copy.deepcopy(payload), response=answer,
                       wire_sha256=hashlib.sha256(wire).hexdigest())
            report["rows"].append(row)
            real.write_json(args.out / "results.json", report)
            chosen = answer["answers"]["step"]["choice"]
            controls = state["available_actions"]
            offset = next(i for i, control in enumerate(controls) if control["id"] == chosen)
            print(label, "chosen", chosen,
                  "p", answer["answers"]["step"]["probabilities"][chosen],
                  "support", answer["answers"][f"support_{offset}"]["noul"],
                  "clear_support", answer["answers"]["support_0"]["noul"], flush=True)


if __name__ == "__main__":
    main()
