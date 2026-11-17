import argparse
import hashlib
import html
import json
import math
import os
from pathlib import Path
import statistics


ROOT = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
EVIDENCE = {}


def read(name, required=True):
    path = ROOT / name
    if not path.exists() and not required:
        return None
    EVIDENCE[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return json.loads(path.read_text())


def stats(values):
    if not values:
        return None
    assert all(math.isfinite(value) and value >= 0 for value in values)
    return {"n": len(values), "median_ms": statistics.median(values),
            "min_ms": min(values), "max_ms": max(values), "samples_ms": values}


def native(label):
    data = read(f".agent/results/P3/normal-voice-qualification/speed-{label}/results.json")
    timed = [row for row in data["rows"] if not row.get("profiled")
             and row["status"] == "passed" and row.get("exact_insertion") and row.get("decoy_unchanged")]
    return {"artifact": data["signed_sha256"], "stats": stats([row["elapsed_ms"] for row in timed]),
            "all_attempts": len(data["rows"]), "failed_attempts": len(data["rows"]) - len(timed),
            "correct": len(timed), "rows": data["rows"]}


def focus(label):
    data = read(f".agent/results/P4/c1-focus-{label}.json")
    rows = [row for row in data["rows"] if row["passed"] and row["documents_restored"]]
    return {"artifact": data["binary_sha256"], "stats": stats([r["context_to_verified_ms"] for r in rows]),
            "failed_attempts": len(data["rows"]) - len(rows), "correct": len(rows),
            "visible_effect": stats([r["visible_effect_ms"] for r in rows])}


def speech(label):
    data = read(f".agent/results/P3/c1-signed-asr-{label}.json")
    times = [(r["marks"]["authoritative_final"] - r["marks"]["fn_up"]) * 1000 for r in data["rows"]]
    return {"artifact": data["artifact_sha256"], "stats": stats(times),
            "word_edits": sum(r["word_edits"] for r in data["rows"]),
            "reference_words": sum(r["reference_words"] for r in data["rows"]),
            "critical_action_errors": data["wrong_critical_actions"],
            "failed_available_cases": data["failed_available_cases"], "missing": data["missing"],
            "preparation_ms": data["preparation_ms"], "manifest_sha256": data["manifest_sha256"],
            "models_sha256": data["model_assets_sha256"],
            "transcripts": {r["case_id"]: r["transcript_sha256"] for r in data["rows"]}}


def scroll(label):
    data = read(f".agent/results/P4/c1-scroll-{label}/comparison.json", required=False)
    if data is None:
        return {"status": "not_collected", "stats": None}
    rows = [row for row in data["rows"] if row.get("strict_success")]
    return {"status": data["status"], "stats": stats([row["wall_ms"] for row in rows]),
            "verified": stats([row["actual_state"]["verified_elapsed_ms"] for row in rows]),
            "failed_attempts": len(data["rows"]) - len(rows),
            "documents_restored": data.get("documents_restored"),
            "error": data.get("error"), "artifact": data["binary_sha256"],
            "harness_sha256": data["harness_sha256"],
            "attempts": data["rows"],
            "reported_outcomes": [row.get("result_text", row.get("error_type", "")) for row in data["rows"]]}


def exclusive_timeline(row):
    marks = {event["stage"]: event["monotonic"] for event in row["trace"]}
    begin, end = marks["contextBegin"], marks["executorEnd"]
    definitions = [
        ("Insertion", "nativeTextInsertionBegin", "nativeTextInsertionEnd"),
        ("Resolver", "resolveBegin", "resolveEnd"),
        ("Gaze", "gazeBegin", "gazeEnd"),
        ("Context", "contextBegin", "contextEnd"),
        ("Admission", "localBegin", "localEnd"),
        ("Queue", "localEnd", "executorBegin"),
        ("Verification", "nativeTextInsertionEnd", "executorEnd"),
        ("Preflight", "resolveEnd", "nativeTextInsertionBegin"),
    ]
    ranges = [(name, max(begin, marks[a]), min(end, marks[b]))
              for name, a, b in definitions if a in marks and b in marks and marks[b] >= marks[a]]
    boundaries = sorted({begin, end, *(edge for _, a, b in ranges for edge in (a, b))})
    totals = {}
    for a, b in zip(boundaries, boundaries[1:]):
        middle = (a + b) / 2
        category = next((name for name, first, last in ranges if first <= middle < last), "Other")
        totals[category] = totals.get(category, 0) + (b - a) * 1000
    assert abs(sum(totals.values()) - (end - begin) * 1000) < 0.001
    return {"total_ms": (end - begin) * 1000, "segments_ms": totals}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--scroll-before", default="before5")
    parser.add_argument("--scroll-after", default="final5")
    args = parser.parse_args()
    before_receipt = read(".agent/results/P12/c1-before-stage.json")
    receipt = read(".agent/results/P12/c1-final-stage.json")
    component = read(".agent/results/P12/component-manifest.json")
    delivery = read(".agent/results/P12/c1-delivery-receipt.json", required=False)
    if delivery:
        assert delivery["binary_sha256"] == receipt["binary_sha256"]
        assert delivery["strict_signature_verified"] and delivery["exact_paths_bytes_modes_and_symlinks"]
    review = read(".agent/results/P4/c1-g4-verdict.json")
    assert review["reviewed_executable_sha256"] == receipt["binary_sha256"]
    typing = {"before": native("c1before"), "after": native("c1final")}
    focusing = {"before": focus("before"), "after": focus("final")}
    asr = {"before": speech("before"), "after": speech("final")}
    scrolling = {"before": scroll(args.scroll_before), "after": scroll(args.scroll_after)}
    scroll_attempts = {}
    for path in sorted(HERE.glob("c1-scroll-*/comparison.json")):
        value = read(str(path.relative_to(ROOT)))
        scroll_attempts[path.parent.name] = {
            "status": value["status"], "timed_rows": len(value["rows"]),
            "documents_restored": value.get("documents_restored"), "error": value.get("error"),
            "harness_sha256": value["harness_sha256"],
        }
    for pair in (typing, focusing, asr):
        assert pair["before"]["artifact"] == before_receipt["binary_sha256"]
        assert pair["after"]["artifact"] == receipt["binary_sha256"]
    if "artifact" in scrolling["before"] and "artifact" in scrolling["after"]:
        assert scrolling["before"]["artifact"] == before_receipt["binary_sha256"]
        assert scrolling["after"]["artifact"] == receipt["binary_sha256"]
        assert scrolling["before"]["harness_sha256"] == scrolling["after"]["harness_sha256"]
    assert asr["before"]["manifest_sha256"] == asr["after"]["manifest_sha256"]
    assert asr["before"]["models_sha256"] == asr["after"]["models_sha256"]
    assert set(asr["before"]["transcripts"]) == set(asr["after"]["transcripts"])
    assert component["binary_sha256"] == receipt["binary_sha256"]
    current_source_matches = all(hashlib.sha256((ROOT / name).read_bytes()).hexdigest() == digest
                                 for name, digest in receipt["source_sha256"].items())
    assert current_source_matches
    history = {}
    for label in ["c1after", "c1afterr2", "c1afterr3", "c1final", "c1finalr2"]:
        path = ROOT / f".agent/results/P3/normal-voice-qualification/speed-{label}/results.json"
        if path.exists():
            history[label] = native(label)
    comparisons = []
    for title, pair, clock in [
        ("Literal typing", typing, "Scripted normal-controller submission → exact insertion and settlement; fresh Jev process."),
        ("Focus Calculator", focusing, "Context capture → verified completion; already-running Calculator, fresh Jev process."),
        ("Speech replay", asr, "Recorded-audio seal marker → authoritative final transcript. No physical Fn or field insertion."),
        ("Owned-window scroll", scrolling, "Packaged MCP request → response; bound-window mode with gaze unavailable."),
    ]:
        before, after = pair["before"].get("stats"), pair["after"].get("stats")
        delta = (after["median_ms"] / before["median_ms"] - 1) * 100 if before and after else None
        comparisons.append({"name": title, "clock": clock, "before": before, "after": after, "delta_percent": delta})
    traces = {}
    for side in ["before", "after"]:
        rows = sorted(typing[side]["rows"], key=lambda row: row["elapsed_ms"])
        traces[side] = exclusive_timeline(rows[len(rows) // 2])
    payload = {"artifact": receipt["binary_sha256"], "app": receipt["app"], "delivery": delivery,
               "independent_review": review,
               "rollback": receipt["rollback_app"], "rollback_sha256": receipt["rollback_sha256"],
               "current_source_matches": current_source_matches,
               "physical_input_verified": False, "phase_accepted": False,
               "typing": typing, "focus": focusing, "speech": asr, "scroll": scrolling,
               "scroll_pair": [args.scroll_before, args.scroll_after], "scroll_attempts": scroll_attempts,
               "comparisons": comparisons, "trace_partitions": traces, "native_experiments": history,
               "same_transcripts": sum(asr["before"]["transcripts"][k] == v
                                       for k, v in asr["after"]["transcripts"].items()),
               "evidence_sha256": EVIDENCE,
               "limitations": [
                   "Three scripted trials per desktop operation do not establish p95 or reliability.",
                   "Desktop trials are fresh-process measurements on one shared Mac, not warm Fn latency.",
                   "Speech preparation cache state was not matched; its observed change is not a claimed speedup.",
                   "Wispr Flow was not installed at the checked application locations; no parity claim.",
                   "Physical Fn/pill, full speech-to-insertion timing and combined normal-GUI resources remain unverified.",
                   "External speech models and C3 transitive/portable-package qualification block release preflight.",
               ]}
    if scrolling["after"].get("failed_attempts"):
        payload["limitations"].append(
            "The owned 300-line TextEdit window was not scrolled: the packaged MCP goal path "
            "returned Jev HTTP 400 max_tokens_exceeded on both builds. This is a real blocked "
            "attempt, not successful scrolling or a speed result. No usage cap was imposed.")
    (HERE / "c1-report.json").write_text(json.dumps(payload, indent=2) + "\n")
    esc = html.escape
    number = lambda value: f"{value:,.3f}"
    rows_html = ""
    charts = ""
    for item in comparisons:
        a, b = item["before"], item["after"]
        if a and b:
            delta = item["delta_percent"]
            style = "bad" if delta > 0 else "good"
            rows_html += f'<tr><td>{esc(item["name"])}</td><td>{number(a["median_ms"])}</td><td>{number(b["median_ms"])}</td><td class="{style}">{delta:+.2f}%</td><td>{a["n"]} / {b["n"]}</td></tr>'
            scale = max(a["max_ms"], b["max_ms"])
            bars = ""
            for side, values in [("Before", a), ("After", b)]:
                bars += f'<div class="bar"><span>{side}</span><div class="track"><i style="width:{values["median_ms"] / scale * 100:.5f}%"></i></div><b>{number(values["median_ms"])} ms</b></div>'
            charts += f'<article><h3>{esc(item["name"])}</h3><p class="note">{esc(item["clock"])}</p>{bars}<p class="note">Observed range: before {number(a["min_ms"])}–{number(a["max_ms"])} ms; after {number(b["min_ms"])}–{number(b["max_ms"])} ms.</p></article>'
        else:
            rows_html += f'<tr><td>{esc(item["name"])}</td><td colspan="4">Unavailable; see coverage record. No successful latency inferred.</td></tr>'
    regressions = [item for item in comparisons if item["delta_percent"] is not None and item["delta_percent"] > 0]
    regressions_html = "".join(f'<li>{esc(item["name"])} median increased {item["delta_percent"]:.2f}%.</li>' for item in regressions)
    regressions_html += '<li>The discarded window-inventory experiment passed correctness but was slower; its source change was reverted.</li>'
    experiments_html = "".join(
        f'<tr><td>{esc(name)}</td><td>{number(data["stats"]["median_ms"])}</td><td>{esc(", ".join(number(x) for x in data["stats"]["samples_ms"]))}</td><td>{"Selected" if name == "c1final" else "Intermediate / not selected"}</td></tr>'
        for name, data in history.items() if data["stats"])
    trace_html = ""
    colors = {"Insertion": "#24744e", "Resolver": "#ba7b23", "Gaze": "#877548", "Context": "#647e91",
              "Admission": "#9e90a9", "Queue": "#c9bd9a", "Verification": "#7ca692", "Preflight": "#a85e45", "Other": "#aaa59b"}
    trace_scale = max(trace["total_ms"] for trace in traces.values())
    for side, trace in traces.items():
        parts = "".join(
            f'<i title="{esc(name)}: {number(value)} ms" style="width:{value / trace_scale * 100:.5f}%;background:{colors[name]}"></i>'
            for name, value in trace["segments_ms"].items())
        legend = "; ".join(f"{name} {number(value)} ms" for name, value in trace["segments_ms"].items())
        trace_html += f'<h3>{side.title()} · {number(trace["total_ms"])} ms traced</h3><div class="partition">{parts}</div><p class="note">{esc(legend)}</p>'
    links = "".join(f'<li><a href="{esc(os.path.relpath(ROOT / path, HERE))}">{esc(path)}</a></li>' for path in EVIDENCE)
    limitations = "".join(f"<li>{esc(item)}</li>" for item in payload["limitations"])
    asr_before, asr_after = asr["before"], asr["after"]
    scroll_failures = "".join(
        f"<li>{esc(side)}: {esc(outcome)}</li>" for side in ["before", "after"]
        for outcome in scrolling[side].get("reported_outcomes", [])
        if scrolling[side].get("failed_attempts"))
    delivery_html = f'<p>Stable byte-identical delivery copy: <code>{esc(delivery["app"])}</code>. Strict signing, paths, bytes, modes and symlinks match the tested artifact. Physical use of this copy is pending.</p>' if delivery else ""
    document = f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Jev Voice C1 evidence</title>
<style>
:root{{--paper:#f3f0e7;--ink:#242a26;--muted:#62685d;--line:#cecbbf;--green:#216b46;--red:#a6402a}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:18px/1.5 Georgia,serif;overflow-wrap:anywhere}}
main{{max-width:1200px;margin:auto;padding:48px 32px}}h1{{font-size:clamp(40px,6vw,76px);line-height:1.05;letter-spacing:-.04em;margin:24px 0}}h2{{font-size:30px}}h3{{font-size:22px}}
section{{padding:28px 0;border-top:1px solid var(--line)}}.note{{color:var(--muted);font-size:15px}}.tag,table,code,.bar,.partition{{font-family:ui-monospace,"SF Mono",monospace;font-size:13px}}.tag{{text-transform:uppercase;letter-spacing:.1em}}.good{{color:var(--green)}}.bad{{color:var(--red)}}code{{overflow-wrap:anywhere}}table{{width:100%;border-collapse:collapse;min-width:620px}}td,th{{padding:14px 10px;text-align:left;border-bottom:1px solid var(--line)}}.overflow{{overflow:auto}}.bar{{display:flex;align-items:center;gap:12px;margin:12px 0}}.bar span{{min-width:52px}}.track{{flex:1;min-width:0}}.bar i{{display:block;height:16px;background:var(--green)}}.bar:first-of-type i{{background:#9b9b8f}}.bar b{{white-space:nowrap;font-weight:normal;min-width:160px;text-align:right}}.partition{{display:flex;height:24px;width:100%}}.partition i{{height:100%;display:block}}article{{padding:12px 0 24px}}a{{color:inherit;text-underline-offset:3px}}li{{margin:8px 0}}p{{max-width:900px}}
@media(max-width:700px){{main{{padding:28px 16px}}.bar{{gap:6px;font-size:11px}}.bar span{{min-width:40px}}.bar b{{min-width:116px}}}}
</style>
<main><p class="tag">Jev Voice / C1 / signed candidate / acceptance still open</p>
<h1>Faster scripted commands.<br>Speech goals still open.</h1>
<p>The selected candidate improved the measured typing and app-focus medians. Speech replay became slower while preserving the same recorded-word error count. The windows experiment that regressed was reverted.</p>
<p class="note">All numbers below come from the linked JSON. Three desktop trials are a small diagnostic sample. They do not measure physical Fn release or prove the warm speed targets.</p>
<p>Independent source/candidate G4: <strong>{esc(review["verdict"])}</strong>. <a href="c1-g4-review.md">Review record</a> · <a href="c1-handoff.md">Candidate handoff</a> · <a href="c1-physical-check.md">Brief physical check</a>. Phase acceptance remains open.</p>
<section><h2>Matched measurements</h2><div class="overflow"><table><thead><tr><th>Operation</th><th>Before median ms</th><th>After median ms</th><th>Change</th><th>n before / after</th></tr></thead><tbody>{rows_html}</tbody></table></div>{charts}</section>
<section><h2 class="bad">Regressions and discarded work</h2><ul class="bad">{regressions_html}</ul>
<p>The third app-focus trial was slower after the change: {number(focusing["before"]["stats"]["samples_ms"][2])} → {number(focusing["after"]["stats"]["samples_ms"][2])} ms. All attempts remain in the evidence.</p>
<div class="overflow"><table><thead><tr><th>Native experiment</th><th>Median ms</th><th>All three samples ms</th><th>Disposition</th></tr></thead><tbody>{experiments_html}</tbody></table></div></section>
<section><h2>Where typing time went</h2><p class="note">Each bar partitions the traced interval of that population's median trial. Overlapping spans receive one category, so time is never added twice. These are individual traces, not a sum of independent medians.</p>{trace_html}</section>
<section><h2>Speech and correctness</h2><p>Before and after: {asr_after["stats"]["n"]} existing recordings; {asr_before["word_edits"]} → {asr_after["word_edits"]} word edits across {asr_after["reference_words"]} reference words; {asr_before["critical_action_errors"]} → {asr_after["critical_action_errors"]} wrong critical actions. {payload["same_transcripts"]} transcript hashes match across the pair. Models and corpus hashes match.</p>
<p>Preparation was observed at {number(asr_before["preparation_ms"])} → {number(asr_after["preparation_ms"])} ms. Cache/cold state was not matched, so this is not attributed to C1. No ASR model, decoder policy, recording, final-word rule or cleanup model was changed.</p>
<p>Typing passed exact insertion, exactly one dispatch and an unchanged decoy in all selected trials. Focus trials used the normal controller and verified the intended app/window. Scroll uses the packaged MCP front door; its coverage and failures remain in <a href="c1-report.json">the generated data</a>.</p></section>
<section><h2 class="bad">Scroll coverage remains blocked</h2><ul class="bad">{scroll_failures}</ul><p>The 300-line owned document and its decoy were unchanged, and the fixture documents were restored. Earlier attempts stopped in harness setup before a goal was sent; every attempt is retained. This MCP goal path is distinct from the normal controller's direct scroll route. It does not prove that route or physical Fn scrolling.</p></section>
<section><h2>What changed</h2><ul>
<li>VisualGoalProof and JevVisualDecision preserve independent exact/hidden-state requirements, literal facts, identity, permission and consequence.</li>
<li>Dwell defaults safely off, learned writes cannot create consent, and opted-in delays have a one-second floor.</li>
<li>Periodic permission status reads run off the UI thread, coalesce, reject stale results and preserve microphone revoke/grant lifecycle behavior.</li>
<li>Both native execution callers verify the captured app/window owner before avoiding redundant app inventory. Missing or changed ownership retains the resolver and fresh field/result checks.</li>
</ul><p class="note">Code references: VisualGoalProof.swift:47–73, JevVisualDecision.swift:415 onward, DwellClick.swift:158 onward, Permissions.swift:122 onward, main.swift:232, DriveLoop.swift:948, FastLaneExecutor.swift:capturedForegroundApplication. The G4 packet contains the scoped source hashes/diff.</p></section>
<section><h2>Verification and limits</h2><p>Required integrated lane: 1,399 Swift tests, 25 skips, zero failures; 27 Python evidence checks; TypeScript typecheck and 234 tracker tests passed. P12: 26 existing Swift checks and six artifact/failure controls passed. Independent G4 is recorded separately; this report does not grant phase acceptance.</p><ul>{limitations}</ul>
<p>Warm goals remain unproven: 50/150 ms dictation and 100/250 ms simple command completion (median/p95). The scripted clocks above cannot be substituted for those clocks.</p></section>
<section><h2>Exact candidate</h2><p><code>{esc(receipt["app"])}</code></p>{delivery_html}<p>Executable SHA256: <code>{receipt["binary_sha256"]}</code></p><p>Strict signing and component preflight passed. Current production source matches the staged snapshot. The daily app was not replaced.</p><p>Rollback: <code>{esc(receipt["rollback_app"])}</code><br><code>{receipt["rollback_sha256"]}</code></p></section>
<section><h2>Raw evidence</h2><p>Regenerate with <code>python3 .agent/results/P4/c1-report.py --scroll-before {esc(args.scroll_before)} --scroll-after {esc(args.scroll_after)}</code>. Full precision, sample membership, every scroll setup attempt and evidence hashes: <a href="c1-report.json">c1-report.json</a>.</p><ul>{links}</ul></section></main></html>"""
    (HERE / "c1-report.html").write_text(document)
    print(json.dumps({"report": str(HERE / "c1-report.html"), "comparisons": comparisons}, indent=2))


if __name__ == "__main__":
    main()
