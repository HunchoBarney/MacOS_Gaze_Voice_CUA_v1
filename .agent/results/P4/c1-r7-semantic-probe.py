import copy
import hashlib
import json
import os
from pathlib import Path
import sys
import time
import urllib.request


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "bench"))
from lib.mcp_stdio import require_api_key


def noul(instructions, yes, no):
    return {"type": "noul", "instructions": instructions,
            "criteria": {"true": yes, "false": no}}


def proposed(payload):
    value = copy.deepcopy(payload)
    value["state"]["scroll_defaults"] = {
        "scope": "current_window", "unit": "line", "normal_amount": 3, "small_amount": 1,
    }
    questions = value["questions"]
    questions["addressed"] = noul(
        "Does `utterance` directly request this Mac assistant to act, stop, pause, or answer a pending "
        "question in the active conversation? Judge communicative intent, not execution permission.",
        "A direct Mac-control instruction, request, control, or answer addressed to the assistant. "
        "Short imperatives and polite requests do not need a wake word or the assistant's name.",
        "Ambient speech, narration, quotation, reported or example commands, an instruction addressed "
        "to another person, or the assistant's own reply. An open microphone alone is insufficient.")
    questions["complete"] = noul(
        "Is the full intended instruction/control/answer expressed in `utterance`, considering "
        "`conversation` and the application's `scroll_defaults`? Judge missing words or clauses, "
        "not permission, whether an action has happened, or whether its result is visible.",
        "The utterance expresses a complete request, control or answer. A short imperative can be "
        "complete. An ordinary scroll can omit the current window and numeric amount because "
        "`scroll_defaults` supplies those defaults. Keep every clause and correction.",
        "Required words or an object are missing, a correction or negation is unfinished, a condition "
        "has no consequent, or a preceding clause remains unresolved. A speech segment ending is "
        "not by itself evidence of a complete instruction.")
    questions["scope"]["instructions"] = (
        "Which observed application/window does the full instruction intend to operate on? "
        "`scroll_defaults.scope` supplies the current window for an unqualified scroll request. "
        "An explicit different app, window or region overrides that default and must be preserved. "
        "Select an app only for its explicit name or unambiguous observed role. "
        "Judge intended scope, not OS permission or whether an effect occurred.")
    questions["scope"]["criteria"]["window"] = (
        "The observed current foreground window, explicitly referred to or used by an unqualified "
        "window-local instruction under `scroll_defaults`. No other window.")
    questions["scope_requested_window"] = noul(
        "Does the full instruction target the observed current window `frontmost_app`/`window_id`, "
        "using `scroll_defaults.scope` only when the scroll instruction specifies no different target? "
        "Judge the intended target relationship. Code checks live target identity and permission separately.",
        "The request explicitly refers to the current window, or is an unqualified window-local "
        "instruction using the current-window default. No explicit app/window/region contradicts it.",
        "The request targets another app/window/region, has an unresolved referent, is quoted/reported, "
        "negated or merely discussed, or no current app/window is observed. Never invent a target.")
    questions["amount"]["instructions"] = (
        "Which scroll-amount category does the full instruction request under `scroll_defaults`? "
        "Absence of an amount qualifier uses the normal default. Preserve exact units or counts.")
    questions["amount"]["criteria"] = {
        "small": "A qualitative small movement, such as a little, a bit, a touch or a tiny scroll; use the small default.",
        "normal": "An ordinary scroll with no small qualifier and no exact distance/count; use the normal default.",
        "clarify": "Conflicting amount, exact distance/pages/count, repetition, or an end condition that a default movement cannot represent.",
    }
    questions["small_requested"] = noul(
        "Does the speaker request a qualitative SMALL scroll amount in the full `utterance`?",
        "The instruction qualifies the scrolling movement as small, little, tiny, a bit or a touch, "
        "including equivalent natural wording.",
        "No small-amount qualifier is requested, an ordinary/default movement is requested, or the "
        "utterance instead specifies another exact amount. Do not infer small merely because scrolling is bounded.")
    questions["bounded_window_scroll"] = noul(
        "Suppose native code independently proves one small/ordinary scroll movement in the requested "
        "direction in the same captured current window and document. Would that evidence satisfy the "
        "ENTIRE instruction in `utterance`, in its `conversation` context and under `scroll_defaults`? "
        "Judge sufficiency of this hypothetical proof, not whether movement has already happened.",
        "The whole instruction requests only one small or ordinary scroll movement in the current "
        "window, in one direction. Independently proved movement would satisfy the entire request.",
        "A named region/sidebar, another app/window, exact distance/units/pages/counts, repetition, "
        "until/end condition, visible target, hidden/persisted state, another action or unrepresented "
        "condition remains. Also false for ambiguous, negated, quoted, reported, example or status-only "
        "commands. A useful first step is insufficient.")
    for direction in ["up", "down", "left", "right"]:
        questions["scroll_supported_" + direction] = noul(
            f"Does the full instruction request scrolling {direction} in its intended scope, using "
            "`scroll_defaults` only for an unspecified window/amount? Judge requested operation, "
            "direction and target together, not permission or observed completion.",
            f"The speaker directly requests a scroll {direction} in the identified scope. "
            "An unqualified scroll uses the observed current window; explicit scope must be preserved.",
            "A different or ambiguous direction, another operation such as moving a window, an "
            "unresolved target/region, negation, quotation, reported/example or status-only speech. "
            "A scroll tool existing does not establish a request.")
    for name in questions:
        if name.startswith("scope_requested_app_"):
            target = name.removeprefix("scope_requested_")
            questions[name] = noul(
                f"Does the full instruction explicitly request an action targeting `observed_apps.{target}` "
                "by name or unambiguous observed role? Judge intended target, not execution permission.",
                "The actual requested action targets this observed app by explicit name or "
                "unambiguous observed app role.",
                "Mere mention, quoted/reported/example text, a different target, negation or a guessed app.")
    return value


def write(path, value):
    with path.open("x") as stream:
        json.dump(value, stream, indent=2)
        stream.write("\n")


def main():
    if os.environ.get("JARVIS_C1_REAL_JEV") != "approved":
        raise SystemExit("Approved read-only C1 semantic diagnosis required")
    output = HERE / "c1-r7-semantic-meaning-prototype"
    output.mkdir(mode=0o700)
    key = require_api_key()
    if not key:
        raise SystemExit("Existing authorized Jev credential unavailable")
    baseline = HERE / "c1-r7-semantic-before"
    inputs = [json.loads((baseline / f"case-{i}.request.json").read_text()) for i in range(14)]
    extras = [
        "Scroll the other window down a bit.",
        "Scroll down in Safari.",
        "If Cedar is already visible, scroll down.",
        "Scroll it down, actually don't.",
        "Move that window down a little.",
        "Scroll down without changing the sidebar.",
        "Do not scroll; tell me where the button is.",
        "Can you scroll upwards just a touch?",
    ]
    for text in extras:
        request = copy.deepcopy(inputs[0])
        request["state"]["utterance"] = text
        inputs.append(request)
    rows = []
    report = {
        "qualification": False, "actions": 0, "microphone": False,
        "scope": "read-only question-meaning prototype using saved semantic fixture inputs",
        "not_a_latency_benchmark": True,
        "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "cases": len(inputs), "rows": rows,
    }
    for index, original in enumerate(inputs):
        payload = proposed(original)
        write(output / f"case-{index}.request.json", payload)
        request = urllib.request.Request(
            "https://api.typesafe.ai/v1/systemone", data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + key})
        started = time.monotonic()
        with urllib.request.urlopen(request, timeout=12) as response:
            body = response.read()
        (output / f"case-{index}.response.json").write_bytes(body)
        data = json.loads(body)
        row = {"index": index, "utterance": original["state"]["utterance"],
               "model": data.get("model"), "elapsed_ms": (time.monotonic() - started) * 1000,
               "answers": data.get("answers", {})}
        rows.append(row)
        (output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({"directory": str(output), "requests": len(rows), "actions": 0}))


if __name__ == "__main__":
    main()
