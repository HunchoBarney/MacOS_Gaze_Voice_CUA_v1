import argparse
import copy
from decimal import Decimal
import json
import os
from pathlib import Path
import time
import urllib.request

from importlib.util import module_from_spec, spec_from_file_location


HERE = Path(__file__).resolve().parent
SPEC = spec_from_file_location("completion_probe_shared", HERE / "jev-native-picture-provenance-probe.py")
SHARED = module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def display_text(value):
    if isinstance(value, str):
        return value.replace("\u200e", "").replace("\u200f", "")
    if isinstance(value, list):
        return [display_text(item) for item in value]
    if isinstance(value, dict):
        return {key: display_text(item) for key, item in value.items()}
    return value


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_JEV_ADAPTIVE") != "approved-additional":
        raise SystemExit("approved model-only scope required")
    real = SHARED.SHARED.load("completion_state_real", "jev-realapps.py")
    receipt = json.loads((args.capture / "capture-receipt.json").read_text())
    native = json.loads((args.capture / "native-before.json").read_text())
    source_path = args.capture / "request-1.json"
    source = json.loads(source_path.read_text())
    answer = json.loads((args.capture / "answers-1.json").read_text())
    if (receipt.get("status") != "captured" or receipt.get("qualification") is not False
            or receipt.get("resources_clean") is not True or receipt.get("drive_requests") != 0
            or native.get("complete") is not True or native.get("window_matches") is not True
            or answer.get("model") != "jev-1.14.0" or source.get("assets")
            or source["state"]["goal"] != "Calculate 3 plus 4 and show the result."
            or set(source["questions"]) != {"goal_complete", "goal_support_0", "goal_support_1"}):
        raise RuntimeError("controlled read-only completion capture required")
    args.out = SHARED.SHARED.private_output(args.out)
    report = {
        "qualification": False, "actuations": 0, "apps_launched": 0,
        "scope": "frozen text-only completion state experiment, not application proof",
        "hypotheses": ["UI direction marks", "missing entire-value provenance", "exact arithmetic context"],
        "max_requests": 16, "max_seconds": 120,
        "source_request_sha256": real.digest(source_path), "harness_sha256": real.digest(__file__),
        "native_provenance_variant": "hypothetical metadata; no production field authority",
        "rows": [],
    }
    cases = [(right, variant) for right in ("4", "5")
             for variant in ("baseline", "display-text", "native-provenance", "computed")]
    key = real.require_api_key()
    deadline = time.monotonic() + 120
    for trial in range(2):
        for right, variant in (cases if trial == 0 else reversed(cases)):
            payload = copy.deepcopy(source)
            payload["model"] = "jev-1.14.0"
            payload.pop("assets", None)
            state = payload["state"]
            state["goal"] = state["current_instruction"] = f"Calculate 3 plus {right} and show the result."
            if variant == "display-text":
                for name in ("observed_content", "screen_values", "goal_facts", "goal_refinement_candidates"):
                    if name in state:
                        state[name] = display_text(state[name])
            elif variant == "native-provenance":
                for name in ("goal_facts", "goal_refinement_candidates"):
                    for fact in state[name].values():
                        if fact.get("index", 0) >= 0 or fact.get("role") != "AXStaticText":
                            raise RuntimeError("unexpected native fact")
                        fact["native_value"] = {
                            "source": "native_ax_value", "extent": "entire_field",
                            "document_associated": False,
                        }
            elif variant == "computed":
                state["known_computation"] = {
                    "expression": "3 + " + right, "result": str(Decimal("3") + Decimal(right)),
                    "source": "exact arithmetic on the user instruction, not observed UI evidence",
                    "is_ui_observation": False,
                }
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("completion state experiment budget exhausted")
            started = time.perf_counter()
            with urllib.request.urlopen(urllib.request.Request(
                "https://api.typesafe.ai/v1/systemone", data=json.dumps(payload).encode(),
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json"},
            ), timeout=min(20, remaining)) as response:
                result = json.load(response)
            SHARED.validate(result, payload["questions"])
            report["rows"].append({
                "right_operand": right, "variant": variant, "trial": trial,
                "expected_complete": right == "4", "request": payload, "response": result,
                "latency_ms": (time.perf_counter() - started) * 1000,
            })
            real.write_json(args.out / "results.json", report)
            print(right, variant, trial, result["answers"], flush=True)
    print(args.out / "results.json")


if __name__ == "__main__":
    main()
