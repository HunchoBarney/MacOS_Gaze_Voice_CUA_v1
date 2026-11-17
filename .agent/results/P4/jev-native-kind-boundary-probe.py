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
SPEC = importlib.util.spec_from_file_location("kind_boundary_shared", HERE / "jev-native-picture-provenance-probe.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def amended_kind(original):
    result = copy.deepcopy(original)
    result["instructions"] += (
        " With native_outcome_candidates, exact_text also covers a derived readonly displayed OUTPUT value "
        "whose exact value needs native evidence, not only caller-specified text. This describes the kind "
        "of proof required, not whether the goal is achieved. Separate native scope, fact, support and "
        "fresh-read checks decide whether a readonly claim is admissible.")
    result["criteria"]["exact_text"] = (
        "Exact displayed text or value, including a derived readonly output value; not merely a general "
        "status or the state of a control. Hidden or persisted conditions still require hidden_backend.")
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_JEV_ADAPTIVE") != "approved-additional":
        raise SystemExit("approved model-only diagnosis required")
    real = SHARED.SHARED.load("kind_boundary_real", "jev-realapps.py")
    receipt = json.loads((args.capture / "capture-receipt.json").read_text())
    source_path = args.capture / "request-2.json"
    source = json.loads(source_path.read_text())
    if (receipt.get("qualification") is not False or receipt.get("status") != "captured"
            or receipt.get("drive_requests") != 0 or receipt.get("resources_clean") is not True
            or source["state"]["goal"] != "Calculate 3 plus 4 and show the result."
            or source["state"]["native_outcome_candidates"]["outcome_1"]["value"] != "\u200e7"):
        raise RuntimeError("controlled read-only source required")
    args.out = SHARED.SHARED.private_output(args.out)
    shutil.copyfile(__file__, args.out / "probe-source.py")
    base = {k: copy.deepcopy(source["questions"][k])
            for k in ("goal_kind", "native_outcome_scope", "goal_evidence")}
    candidate = copy.deepcopy(base)
    candidate["goal_kind"] = amended_kind(base["goal_kind"])
    report = dict(qualification=False, actuations=0, apps_launched=0, max_requests=10,
        purpose="primary native-proof category contract, not outcome proof or signed qualification",
        source_request_sha256=real.digest(source_path), harness_sha256=real.digest(__file__), rows=[])
    deadline = time.monotonic() + 90
    key = real.require_api_key()
    for case, goal in [
        ("correct", source["state"]["goal"]),
        ("wrong-result", "Calculate 3 plus 5 and show the result."),
        ("literal", "Replace the field contents with the exact text 7."),
        ("hidden", "Calculate 3 plus 4 and save the result to a file."),
        ("text-transform", "Show the uppercase version of the text hello."),
    ]:
        for variant, questions in [("baseline", base), ("amended", candidate)]:
            if time.monotonic() >= deadline:
                raise TimeoutError("kind boundary probe budget exhausted")
            state = copy.deepcopy(source["state"])
            state["goal"] = goal
            payload = dict(model="jev-1.14.0", state=state, questions=questions, assets=source["assets"])
            wire = json.dumps(payload).encode()
            label = case + "-" + variant
            (args.out / ("wire-" + label + ".json")).write_bytes(wire)
            with urllib.request.urlopen(urllib.request.Request(
                "https://api.typesafe.ai/v1/systemone", data=wire,
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                         "TypeSafe-Danger-Zone-Images": "true"},
            ), timeout=min(20, deadline - time.monotonic())) as response:
                answer = json.load(response)
            SHARED.validate(answer, questions)
            report["rows"].append(dict(case=label, request=copy.deepcopy(payload), response=answer,
                                       wire_sha256=hashlib.sha256(wire).hexdigest()))
            real.write_json(args.out / "results.json", report)
            print(label, answer["answers"], flush=True)


if __name__ == "__main__":
    main()
