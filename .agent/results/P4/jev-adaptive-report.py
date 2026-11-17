import html
import json
import math
from pathlib import Path
import statistics


ROOT = Path(__file__).resolve().parent
ARMS = [("baseline", "Before"), ("after", "First Revision"), ("after-repeat", "Current Candidate")]


def load(name):
    return json.loads((ROOT / name).read_text())


def stats(rows):
    times = sorted(row["wall_ms"] for row in rows)
    return {
        "correct": sum(row["correct"] for row in rows),
        "total": len(rows),
        "requests": sum(row["requests"] for row in rows),
        "p50_ms": statistics.median(times),
        "p95_ms": times[math.ceil(len(times) * .95) - 1],
        "wrong_actions": sum(row.get("wrong_action", False) for row in rows),
        "unsupported_done_claims": sum(row.get("unsupported_done_claim", False) for row in rows),
    }


data = {}
for arm, label in ARMS:
    observation = load(f"jev-adaptive-{arm}-r2.json")
    workflow = load(f"jev-adaptive-workflows-{arm}-r2.json")
    data[arm] = {
        "label": label,
        "observations": stats(observation["rows"]),
        "inferred": stats([r for r in observation["rows"] if r["requests"]]),
        "workflows": stats(workflow["rows"]),
        "rows": observation["rows"],
    }
before = load("jev-adaptive-baseline-r2.json")
current = load("jev-adaptive-after-repeat-r2.json")
for source in ["Tests/JevVoiceAppTests/JevAdaptiveFixtures.swift",
               "Tests/JevVoiceAppTests/JevAdaptiveLiveTests.swift"]:
    assert before["source_sha256"][source] == current["source_sha256"][source]
assert before["repeats"] == current["repeats"] == 2
assert (load("jev-adaptive-workflows-baseline-r2.json")["workflow_harness_sha256"]
        == load("jev-adaptive-workflows-after-repeat-r2.json")["workflow_harness_sha256"])
summary = {arm: {k: v for k, v in entry.items() if k != "rows"} for arm, entry in data.items()}
summary["new_grant_spent"] = load("jev-adaptive-grant.json")["spent"]
(ROOT / "jev-adaptive-summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True))
sections = []
for arm, entry in data.items():
    o, w = entry["observations"], entry["workflows"]
    percentage = o["correct"] / o["total"] * 100
    sections.append(
        f'<article><h2>{entry["label"]}</h2>'
        f'<p class="score">{o["correct"]}/{o["total"]}<span> observation checks</span></p>'
        f'<div class="track"><div style="width:{percentage}%"></div></div>'
        f'<p>{o["wrong_actions"]} wrong actions &middot; {o["unsupported_done_claims"]} unsupported done claims</p>'
        f'<p>{o["requests"]} requests &middot; p50 {o["p50_ms"]:.3f} ms &middot; p95 {o["p95_ms"]:.3f} ms</p>'
        f'<p>Verified synthetic workflows: {w["correct"]}/{w["total"]}</p></article>')
cases = []
for name in dict.fromkeys(r["fixture"] for r in current["rows"]):
    cells = []
    for arm, _ in ARMS:
        rows = [r for r in data[arm]["rows"] if r["fixture"] == name]
        cells.append(f'<td>{sum(r["correct"] for r in rows)}/{len(rows)}</td>')
    cases.append(f'<tr><th>{html.escape(name)}</th>{"".join(cells)}</tr>')
base = data["baseline"]["observations"]
final = data["after-repeat"]["observations"]
p50_change = final["p50_ms"] - base["p50_ms"]
p95_change = final["p95_ms"] - base["p95_ms"]
document = f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Jev: More Useful Decisions, Same Safety Boundary</title>
<style>
:root{{--paper:#f4f1e9;--ink:#18221e;--muted:#526159;--line:#c8cec7;--accent:#247452;--warning:#9f3e20}}
*{{box-sizing:border-box}}body{{margin:0;color:var(--ink);background:var(--paper);font:16px/1.6 Georgia,serif}}
main{{max-width:1180px;margin:auto;padding:56px 28px}}h1{{font-size:clamp(34px,5vw,64px);line-height:1.08;max-width:900px;letter-spacing:-.035em}}
h2{{font-size:23px}}.kicker,table,.meta{{font:12px/1.6 Menlo,monospace;letter-spacing:.02em}}
.deck{{display:grid;grid-template-columns:repeat(3,1fr);gap:24px;border-block:1px solid var(--line);padding:24px 0}}
article{{min-width:0}}article p{{color:var(--muted)}}.score{{font-size:42px;margin:12px 0;color:var(--ink)}}.score span{{font-size:15px}}
.track{{height:8px;background:#dce1da}}.track div{{height:100%;background:var(--accent)}}.warning{{color:var(--warning);border-left:3px solid;padding:8px 20px}}
section{{margin-top:42px}}.table{{overflow-x:auto}}table{{border-collapse:collapse;width:100%;text-align:left}}th,td{{padding:10px;border-bottom:1px solid var(--line)}}thead{{background:#e8ece3}}
a{{color:var(--accent)}}li{{margin:8px 0}}footer{{margin-top:48px;border-top:1px solid var(--line);padding-top:20px;color:var(--muted)}}
@media(max-width:780px){{main{{padding:32px 18px}}.deck{{grid-template-columns:1fr;gap:12px}}article+article{{border-top:1px solid var(--line)}}}}
</style>
<main><p class="kicker">JEV / P4 FOLLOW-UP / SYNTHETIC EVIDENCE / 2026-11-08</p>
<h1>More useful decisions.<br>Same execution boundary.</h1>
<p>Jev now chooses the next unfinished action, not just a control that completes the whole goal.
Ambiguity can trigger one focused follow-up. Code still owns literals, permissions, the captured window and completion proof.</p>
<div class="deck">{''.join(sections)}</div>
<section><h2>The cost is visible</h2>
<p class="warning">Observation latency regresses: p50 +{p50_change:.3f} ms; p95 +{p95_change:.3f} ms.
The first revision also introduces six undesired focus actions. Those failed results remain in the record.</p>
<p>Current workflow p50 is {data["after-repeat"]["workflows"]["p50_ms"]:.3f} ms and p95 is
{data["after-repeat"]["workflows"]["p95_ms"]:.3f} ms. The baseline finishes none of those workflows;
its faster failures are not successful-task speedups.</p></section>
<section><h2>What the evidence does not say</h2><ul>
<li>45/48 is not 10/10. Three observations safely abstain: one search-entry trial and both generic installer-navigation trials.</li>
<li>Two correct observation rows use a deterministic postcondition and no model request. Inference-only current score is 43/46.</li>
<li>The initial held-out slice scores 13/16. It was inspected after the candidate froze; it is no longer unseen for future work.</li>
<li>Real API calls use Jev 1.14.0. Workflow tests run the production TaskLoop with a synthetic observation source and actuator, not a physical desktop.</li>
<li>Two ordered trials per fixture do not establish broad reliability. The four-round lock remains. P4 desktop benchmark and phase review are still open.</li>
</ul></section>
<section><h2>Every fixture, including misses</h2><div class="table"><table>
<thead><tr><th>Fixture</th><th>Before</th><th>First Revision</th><th>Current</th></tr></thead>
<tbody>{''.join(cases)}</tbody></table></div></section>
<section><h2>Reproduction and provenance</h2><p>Same fixture and measurement harness hashes; same two trials;
reverse order on trial two. Each raw JSON records state, questions, answers, returned model, requests and source hashes.
p95 uses the nearest-rank method. Observation times include diagnostic accounting I/O.</p>
<p><a href="jev-adaptive-baseline-r2.json">Before JSON</a> &middot;
<a href="jev-adaptive-after-r2.json">First revision JSON</a> &middot;
<a href="jev-adaptive-after-repeat-r2.json">Current JSON</a> &middot;
<a href="jev-adaptive-boundary-probe.json">Boundary/context diagnostic</a> &middot;
<a href="jev-adaptive-summary.json">Summary JSON</a></p>
<p>The context diagnostic is not a benchmark: it deliberately changes headings and question definitions.
It supports keeping these uncertainties visible rather than lowering the action-support threshold.</p></section>
<footer>New authorized synthetic grant: {summary["new_grant_spent"]} requests, including failed experiments and diagnostics.
Previous exhausted 30-request grant remains separate and unchanged. No private desktop content is in these artifacts.</footer>
</main></html>"""
(ROOT / "jev-adaptive-report.html").write_text(document)
print(json.dumps(summary, indent=2))
