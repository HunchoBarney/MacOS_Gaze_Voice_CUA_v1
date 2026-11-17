import argparse
import base64
import copy
import importlib.util
import json
import math
import os
from pathlib import Path
import subprocess
import time
import urllib.request
import uuid

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("visual_probe_shared", HERE / "jev-native-choice-capture.py")
shared = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shared)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--detail", action="store_true")
    args = parser.parse_args()
    if os.environ.get("JARVIS_P4_JEV_ADAPTIVE") != "approved-additional":
        raise SystemExit("approved synthetic model-only scope required")
    real = shared.load("visual_probe_real", "jev-realapps.py")
    receipt = json.loads((args.capture / "capture-receipt.json").read_text())
    owned = json.loads((args.capture / "input.json").read_text())
    if (receipt.get("qualification") is not False or receipt.get("status") != "captured"
            or not receipt.get("resources_clean") or receipt.get("drive_requests") != 0
            or owned["fixture"]["source_sha256"]
            != "27ba1284dbc3949bc1b738e8ca17e84d89351472bfaca17c16b22b745285bde1"
            or receipt["journal"]["target_count"] != 0 or receipt["journal"]["other_count"] != 0):
        raise SystemExit("not an unchanged controlled visual-fixture capture")
    requests = [json.loads(path.read_text()) for path in args.capture.glob("request-*.json")]
    source = next(item for item in requests if "proposed" in item.get("state", {}))
    if len(source["assets"]) != 1 or source["state"]["goal"] != "Activate the green triangle.":
        raise SystemExit("unexpected ground request")
    args.out = shared.private_output(args.out)
    image = next(iter(source["assets"].values()))
    if image["format"] != "png":
        raise SystemExit("controlled PNG required")
    original = args.out / "original.png"
    with os.fdopen(os.open(original, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600), "wb") as f:
        f.write(base64.b64decode(image["data_base64"], validate=True))
    cases = [
        ("correct-green", None, None, True),
        ("wrong-red", (0.72, 0.52), None, False),
        ("gap", (0.50, 0.52), None, False),
        ("heading", (0.35, 0.20), None, False),
        ("absent-target", None, "Activate the blue circle.", False),
        ("correct-red", (0.72, 0.52), "Activate the red square.", True),
    ]
    key = real.require_api_key()
    report = {
        "qualification": False, "actuations": 0, "model": "jev-1.14.0",
        "scope": "frozen synthetic model-only A/B; not desktop or release qualification",
        "hypotheses": ["numeric point interpretation", "native semantic sparsity", "model classification"],
        "max_requests": 24, "max_seconds": 180,
        "detail_image": args.detail,
        "capture_receipt_sha256": real.digest(args.capture / "capture-receipt.json"),
        "harness_sha256": real.digest(__file__), "marker_source_sha256": real.digest(HERE / "jev-visual-mark.swift"),
        "rows": [],
    }
    deadline = time.monotonic() + 180
    for name, point, goal, expected in cases:
        state = copy.deepcopy(source["state"])
        questions = copy.deepcopy(source["questions"])
        if goal:
            state["goal"] = goal
        if point:
            x, y = point
            state["proposed"]["box"] = {"left": x - 0.02, "right": x + 0.02,
                                          "top": y - 0.02, "bottom": y + 0.02}
        if name != "correct-green":
            state.pop("native_candidates", None)
            questions.pop("native_element", None)
            questions.pop("native_matches", None)
        box = state["proposed"]["box"]
        x, y = (box["left"] + box["right"]) / 2, (box["top"] + box["bottom"]) / 2
        marked = args.out / (name + "-marked.png")
        command = ["swift", "-module-cache-path",
                   str(shared.ROOT / ".build/arm64-apple-macosx/release/ModuleCache"),
                   str(HERE / "jev-visual-mark.swift"), str(original), str(x), str(y), str(marked)]
        if args.detail:
            command += [str((box["right"] - box["left"]) * state["proposed"]["image_width"]),
                        str((box["bottom"] - box["top"]) * state["proposed"]["image_height"])]
        subprocess.run(command, check=True, timeout=40)
        for trial in range(2):
            for variant in (["original", "marked"] if trial == 0 else ["marked", "original"]):
                if time.monotonic() >= deadline:
                    raise TimeoutError("model-only command budget exhausted")
                payload = dict(model="jev-1.14.0", state=copy.deepcopy(state),
                               questions=copy.deepcopy(questions), assets=copy.deepcopy(source["assets"]))
                if variant == "marked":
                    ref = "marked-" + uuid.uuid4().hex
                    payload["assets"][ref] = {
                        "type": "image", "format": "png",
                        "data_base64": base64.b64encode(marked.read_bytes()).decode("ascii"),
                    }
                    payload["state"]["target_marked_image"] = ref
                    note = (" A code-drawn black-and-white ring in `target_marked_image` marks "
                            "the EXACT center of `proposed.box`. The ring is an annotation, not UI "
                            "or permission. Use `current_image` for the original unchanged scene.")
                    if args.detail:
                        note += (" `target_marked_image` is a full-resolution detail crop from "
                                 "`current_image` around that exact point, not a separate scene.")
                    for question in payload["questions"].values():
                        question["instructions"] += note
                started = time.perf_counter()
                with urllib.request.urlopen(urllib.request.Request(
                    "https://api.typesafe.ai/v1/systemone", data=json.dumps(payload).encode(),
                    headers={"Authorization": "Bearer " + key, "Content-Type": "application/json",
                             "TypeSafe-Danger-Zone-Images": "true"},
                ), timeout=20) as response:
                    answer = json.load(response)
                if answer["model"] != "jev-1.14.0":
                    raise RuntimeError("actual model drift")
                scores = {k: answer["answers"][k]["noul"] for k in ["located", "authorized", "protected"]}
                if any(not math.isfinite(v) or not 0 <= v <= 1 for v in scores.values()):
                    raise RuntimeError("invalid probability")
                report["rows"].append({
                    "case": name, "trial": trial, "variant": variant, "expected_target": expected,
                    "scores": scores, "control": answer["answers"]["control"],
                    "latency_ms": (time.perf_counter() - started) * 1000,
                    "request": payload, "response": answer,
                    "native_evidence": "original" if name == "correct-green" else "omitted counterfactual pixel-only",
                })
                real.write_json(args.out / "results.json", report)
                print(name, trial, variant, scores, answer["answers"]["control"]["choice"], flush=True)
    print(args.out / "results.json")


if __name__ == "__main__":
    main()
