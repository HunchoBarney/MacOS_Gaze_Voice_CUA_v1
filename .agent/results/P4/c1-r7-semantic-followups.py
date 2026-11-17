import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import time
import urllib.request


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("r7_semantic_refinement", HERE / "c1-r7-semantic-refinement.py")
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)


def proposed(payload):
    value = BASE.refine(payload)
    q = value["questions"]
    q["kind"]["criteria"]["scroll"] = (
        "One bounded scroll, including a small additional movement or a bounded direction reversal.")
    q["kind"]["criteria"]["continue_scroll"] = (
        "Explicitly keep repeating the last verified scroll until stopped. A little more is one "
        "bounded movement, not an instruction to scroll indefinitely.")
    q["complete"]["criteria"]["true"] += (
        " A contextually resolved follow-up need not repeat the prior action's words. "
        "A stop/pause control needs no object or window; a request to keep a verified action going "
        "needs no fixed amount or explicit ending time.")
    q["small_requested"] = BASE.BASE.noul(
        "Does a qualitative SMALL amount qualify the requested movement in the full `utterance`? "
        "Judge the amount qualifier; operation and target are judged separately.",
        "The requested movement is qualified as little, small, tiny, a bit, a touch or an equivalent "
        "qualitative amount, including a small relative or additional movement.",
        "There is no small-amount qualifier on the movement, or another exact amount is requested. "
        "A small object/window, quoted small amount or a merely bounded movement does not qualify.")
    q["direction"]["instructions"] = (
        "Which scroll direction does the full instruction request in `conversation`? A direct "
        "reference to the verified scroll can retain its direction or explicitly reverse it. "
        "No default direction is allowed without words or a valid referenced scroll.")
    for direction in ["up", "down", "left", "right"]:
        q["scroll_supported_" + direction]["instructions"] = (
            f"Does the full instruction in `conversation` request scrolling {direction} in its intended "
            "scope? A direct reference to the verified scroll may supply the operation/direction/region; "
            "an explicit new direction overrides the old one. Use `scroll_defaults` only for an "
            "unspecified current window/amount. Judge requested operation, direction and target "
            "together, not permission or observed completion.")
        q["scroll_supported_" + direction]["criteria"]["true"] = (
            f"The requested movement is a scroll {direction} in the identified scope, stated directly "
            "or through an unambiguous reference to the verified scroll. Preserve explicit scope.")
    q["scroll_extent"] = {
        "type": "choice",
        "instructions": "Does the entire scroll instruction request one bounded movement or ongoing repetition? Preserve all clauses.",
        "criteria": {
            "single": "One bounded movement, including a little more or a bounded reversal. An ordinary unqualified scroll is single.",
            "ongoing": "Explicitly keep scrolling until the user stops it, with no different end condition or extra action.",
            "clarify": "A compound instruction, exact distance/count, named end condition, conflicting duration or unclear request.",
        },
    }
    q["continuous_requested"] = BASE.BASE.noul(
        "Does the ENTIRE instruction explicitly request ongoing repetition of `conversation.verified_scroll` "
        "in its same scope and direction until the user stops it?",
        "The user expressly asks to keep the verified scroll going in the same scope/direction, "
        "without another end condition, exact amount, extra action or changed region.",
        "Only one movement or a little more is requested; no verified scroll exists; a different "
        "scope/direction/region, named until/end condition, exact amount, compound action, negation, "
        "quotation, reported/example or status-only speech occurs. Context alone is not a request.")
    q["scroll_reference"] = {
        "type": "choice",
        "instructions": "Which observed subject supplies the requested scroll's scope/region in this conversation?",
        "criteria": {
            "current_window": "A fresh instruction about the current window, using the current-window default if unqualified.",
            "verified_scroll": "An explicit contextual reference such as more, again or the other way to the stored verified scroll's same window/document/region.",
            "clarify": "The reference is missing, ambiguous, targets another window/region, or the required verified scroll is absent.",
        },
    }
    q["verified_scroll_reference"] = BASE.BASE.noul(
        "Does the full instruction directly refer to the SAME window/document/region as "
        "`conversation.verified_scroll`? Judge the intended subject, not permission or an effect.",
        "An explicit contextual reference to the existing verified scroll's subject. Direction or "
        "qualitative amount may be explicitly updated, but its window/document/region stays the same.",
        "No verified scroll exists, the reference is unresolved, an app/window/region changes, or "
        "the utterance is negated, quoted, reported, hypothetical or status-only. Mere stored context "
        "does not establish that the new request refers to it.")
    return value


def main():
    if os.environ.get("JARVIS_C1_REAL_JEV") != "approved":
        raise SystemExit("Approved read-only semantic diagnosis required")
    output = HERE / "c1-r7-semantic-followup-prototype"
    output.mkdir(mode=0o700)
    key = BASE.BASE.require_api_key()
    if not key:
        raise SystemExit("Existing Jev credential unavailable")
    before = HERE / "c1-r7-semantic-meaning-refined"
    inputs = [json.loads((before / f"case-{i}.request.json").read_text()) for i in range(29)]
    for text in ["A bit more, please.", "Scroll a little further down.",
                 "Keep scrolling until Cedar is visible.", "Again.",
                 "Keep scrolling the sidebar.", "Keep scrolling in Safari."]:
        request = copy.deepcopy(inputs[22])
        request["state"]["utterance"] = text
        inputs.append(request)
    changed = copy.deepcopy(inputs[24])
    changed["state"]["window_id"] = 42
    inputs.append(changed)
    rows = []
    report = {
        "qualification": False, "actions": 0, "microphone": False, "cases": len(inputs),
        "not_a_latency_benchmark": True, "rows": rows,
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "base_sources_sha256": {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
                               for name in ["c1-r7-semantic-probe.py", "c1-r7-semantic-refinement.py"]},
        "scope": "Final bounded question-composition hypothesis; explicit single/ongoing and native subject references",
    }
    for index, original in enumerate(inputs):
        payload = proposed(original)
        BASE.BASE.write(output / f"case-{index}.request.json", payload)
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
