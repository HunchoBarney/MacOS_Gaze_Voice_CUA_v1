import argparse
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import time
import urllib.request


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("picture_provenance_shared", HERE / "jev-native-choice-capture.py")
SHARED = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SHARED)


def validate(response, questions):
    if response.get("model") != "jev-1.14.0" or set(response.get("answers", {})) != set(questions):
        raise RuntimeError("model or answer-key drift")
    for name, definition in questions.items():
        value = response["answers"][name]
        if definition["type"] == "noul":
            numbers = [value["noul"]]
        elif definition["type"] == "choice":
            probabilities = value["probabilities"]
            if (set(probabilities) != set(definition["criteria"])
                    or value["choice"] not in probabilities
                    or abs(sum(probabilities.values()) - 1) > 0.01):
                raise RuntimeError("invalid choice distribution")
            numbers = list(probabilities.values()) + [value["confidence"]]
        else:
            raise RuntimeError("unexpected grounding primitive")
        if any(isinstance(v, bool) or not isinstance(v, (int, float))
               or not math.isfinite(v) or not 0 <= v <= 1 for v in numbers):
            raise RuntimeError("invalid model probability")


def atomic_questions(payload):
    questions = payload["questions"]
    questions["native_element"]["instructions"] = (
        "Choose the candidate whose OWN pictured control is the visual target described by `goal`. "
        "A parent merely containing that control is not the target. Use none if there is no exact match. "
        "Judge visual identity, not permission to act.")
    questions["native_matches"]["instructions"] = (
        "Does any `native_candidates` object's OWN pictured control match the visual target in `goal`, "
        "rather than merely contain it or lie beside it? Judge identity, not permission.")
    questions["native_element_1__identity"]["instructions"] = (
        "Does the OWN pictured control at `native_candidates.element_1` match the visual target "
        "described by `goal`, rather than just contain it or lie beside it? Judge identity, not permission.")
    questions["native_element_1__located"]["instructions"] = (
        "Is the pictured control at `native_candidates.element_1` visibly present and unobscured "
        "as that same control in `current_image`? Its detail crop is another view of the SAME object, "
        "not another control. Judge visible placement, not goal meaning or permission.")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--atomic-questions", action="store_true")
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_JEV_ADAPTIVE") != "approved-additional":
        raise SystemExit("approved synthetic model-only scope required")
    real = SHARED.load("picture_provenance_real", "jev-realapps.py")
    receipt = json.loads((args.capture / "capture-receipt.json").read_text())
    owned = json.loads((args.capture / "input.json").read_text())
    if (receipt.get("qualification") is not False or receipt.get("status") != "captured"
            or receipt.get("resources_clean") is not True or receipt.get("drive_requests") != 0
            or owned["fixture"]["source_sha256"]
            != "27ba1284dbc3949bc1b738e8ca17e84d89351472bfaca17c16b22b745285bde1"
            or receipt["journal"]["target_count"] != 0 or receipt["journal"]["other_count"] != 0
            or receipt["journal"]["seed"] != 0):
        raise SystemExit("unchanged controlled fixture required")
    sources = [(p, json.loads(p.read_text())) for p in args.capture.glob("request-*.json")]
    sources = [(p, q) for p, q in sources if "proposed" in q.get("state", {})]
    if len(sources) != 1:
        raise SystemExit("exactly one grounding request required")
    source_path, source = sources[0]
    recorded = json.loads((args.capture / source_path.name.replace("request-", "answers-")).read_text())
    candidates = source["state"]["native_candidates"]
    if (recorded.get("model") != "jev-1.14.0" or source.get("model") not in (None, "jev-1.14.0")
            or set(candidates) != {"element_1"} or candidates["element_1"]["role"] != "AXButton"
            or candidates["element_1"]["label"] != "symbol-0"
            or set(source["assets"]) != {source["state"]["current_image"], candidates["element_1"]["image"]}
            or "native_element_1__identity" not in source["questions"]):
        raise SystemExit("pinned pictured native source required")
    args.out = SHARED.private_output(args.out)
    report = {
        "qualification": False, "actuations": 0, "apps_launched": 0,
        "scope": "frozen model-only provenance comparison, not desktop qualification",
        "max_requests": 16 if args.atomic_questions else 12, "max_seconds": 120, "trials": 2,
        "hypothesis": "separate visual identity and visibility" if args.atomic_questions
            else "explicit same-frame crop provenance resolves duplicate-depiction ambiguity",
        "source_request_sha256": real.digest(source_path),
        "capture_receipt_sha256": real.digest(args.capture / "capture-receipt.json"),
        "harness_sha256": real.digest(__file__), "rows": [],
    }
    names = ("green", "absent-blue", "denied-green", "parent-counterfactual") if args.atomic_questions \
        else ("green", "absent-blue", "denied-green")
    cases = [(name, variant) for name in names
             for variant in ("baseline", "atomic" if args.atomic_questions else "provenance")]
    key = real.require_api_key()
    deadline = time.monotonic() + 120
    for trial in range(2):
        for name, variant in (cases if trial == 0 else reversed(cases)):
            payload = copy.deepcopy(source)
            payload["model"] = "jev-1.14.0"
            if name == "absent-blue":
                payload["state"]["goal"] = "Activate the blue circle."
            elif name == "denied-green":
                index = len(payload["state"]["deny"])
                payload["state"]["deny"].append("Do not activate the green triangle.")
                for prefix in ("", "native_element_1__"):
                    question = copy.deepcopy(payload["questions"][prefix + "deny_0"])
                    question["instructions"] = question["instructions"].replace("deny[0]", f"deny[{index}]")
                    payload["questions"][prefix + f"deny_{index}"] = question
            elif name == "parent-counterfactual":
                image = payload["state"]["current_image"]
                candidate = payload["state"]["native_candidates"]["element_1"]
                candidate.update(role="AXGroup", label="Container", image=image,
                                 top=0, left=0, width=1, height=1)
                payload["questions"]["native_element"]["criteria"]["element_1"] = image
                payload["assets"] = {image: payload["assets"][image]}
            if variant == "atomic":
                atomic_questions(payload)
            if variant == "provenance":
                payload["state"]["native_candidates"]["element_1"]["image_provenance"] = (
                    "This picture is a code-derived detail crop of this SAME native object's bounds "
                    "in current_image, not another control or another observation. Any neutral padding "
                    "is not UI. The full original scene is retained. This is evidence, not permission.")
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("model-only comparison budget exhausted")
            started = time.perf_counter()
            with urllib.request.urlopen(urllib.request.Request(
                "https://api.typesafe.ai/v1/systemone", data=json.dumps(payload).encode(),
                headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                         "TypeSafe-Danger-Zone-Images": "true"},
            ), timeout=min(20, remaining)) as response:
                answer = json.load(response)
            validate(answer, payload["questions"])
            report["rows"].append(dict(case=name, variant=variant, trial=trial,
                latency_ms=(time.perf_counter() - started) * 1000, request=payload, response=answer))
            real.write_json(args.out / "results.json", report)
            print(name, variant, trial, {
                k: v for k, v in answer["answers"].items() if k in {
                    "native_element", "native_matches", "native_element_1__identity",
                    "native_element_1__located", "native_element_1__authorized",
                }
            }, flush=True)
    print(args.out / "results.json")


if __name__ == "__main__":
    main()
