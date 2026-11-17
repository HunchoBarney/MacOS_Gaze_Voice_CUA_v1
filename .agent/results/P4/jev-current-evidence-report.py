import argparse
import base64
import hashlib
import html
import importlib.util
import json
import math
from pathlib import Path
import statistics


HERE = Path(__file__).resolve().parent


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def summarize(rows):
    successful = [row for row in rows if row.get("strict_success") is True and row.get("verified") is True]
    times = [row["wall_ms"] for row in successful
             if isinstance(row.get("wall_ms"), (int, float)) and math.isfinite(row["wall_ms"])]
    return {
        "trials": len(rows), "strict_successes": len(successful),
        "verified_outcomes": sum(row.get("verified") is True for row in rows),
        "confirmed_false_done": sum(row.get("false_done") is True for row in rows),
        "unverified_done": sum(row.get("status") in ("done", "already") and row.get("verified") is not True
                               and row.get("false_done") is not True for row in rows),
        "successful_wall_samples_ms": times,
        "successful_wall_median_ms": statistics.median(times) if len(times) >= 3 else None,
    }


def load_lane(root, name):
    path = root / name
    if not (path / "summary.json").is_file():
        return {"name": name, "state": "missing", "rows": [], "runs": [], "preflight_errors": 0,
                "resources_clean": False, "inputs": {}}
    summary = json.loads((path / "summary.json").read_text())
    result = {"name": name, "state": summary["status"], "rows": [], "runs": [],
              "inputs": {str(Path(name) / "summary.json"): digest(path / "summary.json")}}
    for source in sorted(path.glob("*/results.json")):
        record = json.loads(source.read_text())
        run = source.parent.name
        result["inputs"][str(source.relative_to(root))] = digest(source)
        result["runs"].append({
            "run": run, "resources_clean": record.get("resources_clean") is True,
            "actor_trials": len(record.get("rows", [])), "driver_sha256": record.get("driver_sha256"),
            "binary_sha256": record.get("binary_sha256"),
            "harness_sha256": record.get("harness_sha256"),
        })
        for row in record.get("rows", []):
            public = {key: row[key] for key in (
                "case", "status", "strict_success", "verified", "false_done", "wall_ms", "actor_pid",
                "actual_state", "result_text", "verification_status", "visual_trace", "visual_trace_complete",
            ) if key in row}
            result["rows"].append(dict(public, run=run))
    result["preflight_errors"] = sum(run["actor_trials"] == 0 for run in result["runs"]) if summary["status"] == "error" else 0
    result["resources_clean"] = bool(result["runs"]) and all(run["resources_clean"] for run in result["runs"])
    result["scores"] = summarize(result["rows"])
    return result


def native_context_evidence(root):
    stage = root / "native-ancestor-frozen-stage/stage-receipt.json"
    if not stage.is_file():
        return None
    lanes = {key: load_lane(root, name) for key, name in {
        "pilot": "native-ancestor-pilot-r3",
        "comparison": "native-ancestor-matched-ab",
        "resume": "native-ancestor-matched-resume",
    }.items()}
    comparison, resume = lanes["comparison"], lanes["resume"]
    baseline = [row for row in comparison["rows"] if row["run"].startswith("before")]
    candidate = [row for row in comparison["rows"] if row["run"].startswith("after")]
    candidate += [dict(row, run="resume/" + row["run"]) for row in resume["rows"]]
    hashes = {run["harness_sha256"] for lane in (comparison, resume)
              for run in lane["runs"] if run.get("harness_sha256")}
    inputs = {str(stage.relative_to(root)): digest(stage)}
    for lane in lanes.values():
        inputs.update(lane["inputs"])
    for path in [root / "native-ancestor-source-delta.json", *root.glob("native-ancestor*.log")]:
        if path.is_file():
            inputs[str(path.relative_to(root))] = digest(path)
    rows = baseline + candidate
    return {
        "lanes": lanes, "rows": rows, "inputs": inputs,
        "scores": {"baseline": summarize(baseline), "candidate": summarize(candidate)},
        "comparison_preflight_errors": comparison["preflight_errors"],
        "uninterrupted_matched_comparison": (
            comparison["state"] == "complete" and comparison["preflight_errors"] == 0
            and len(baseline) == 3 and len(candidate) == 3 and not resume["rows"]),
        "harness_hash_changed": len(hashes) > 1 if hashes else None,
        "harness_sha256": sorted(hashes),
        "native_exact_outcomes": sum(
            row.get("actual_state", {}).get("document_body_matches") is True
            and row.get("actual_state", {}).get("native_exact_value_verified") is True for row in rows),
        "confirmed_false_done": sum(row.get("false_done") is True for row in rows),
        "request_count_and_bytes": "not measured",
        "reliability_gain": "not established",
    }


def native_context_section(data, root):
    if data is None:
        return ""
    baseline, candidate = (data["scores"][key] for key in ("baseline", "candidate"))
    score = lambda item: f'{item["strict_successes"]}/{item["trials"]}'
    pilot = data["lanes"]["pilot"].get("scores", summarize([]))
    interrupted = not data["uninterrupted_matched_comparison"]
    caveat = (
        "The sequence was interrupted before the last candidate command. A one-command continuation "
        "did not replay completed commands. This is not an uninterrupted matched comparison."
        if interrupted else "All scheduled comparison commands ran without a preflight interruption.")
    return f'''<h2>Native Context Amendment: No Reliability Gain Established</h2>
<p><strong>Baseline: {score(baseline)}. Candidate: {score(candidate)}.</strong>
These are issued commands only. Native exact text: {data["native_exact_outcomes"]}/{len(data["rows"])}.
Confirmed false done: {data["confirmed_false_done"]}.</p>
<p>{caveat} Comparison preflight failures: {data["comparison_preflight_errors"]}.
Harness hash changed between segments: {escape(data["harness_hash_changed"])}.
The final harness change records readiness diagnostics; the body oracle, task and safety gates are unchanged.
It must not be presented as unchanged-harness qualification.</p>
<table><thead><tr><th>Run</th><th>Case</th><th>Reported</th><th>Native outcome</th><th>Command time</th></tr></thead>
<tbody>{trial_table(data["rows"])}</tbody></table>
<p>The separate pilot was {score(pilot)} and is excluded from these comparison scores.
The three replacement judgments still require 0.95. Optional ancestor roles are observations, not permission.
No reliability or speed win is demonstrated; return times include refusals and are rounded upward.</p>
<p class="muted">Intermittent preflight readback refusals remain unexplained. Actual request count and
request bytes were not captured. Physical Fn, microphone, gaze and release qualification are still missing.
Earlier image and everyday-app results below concern earlier candidates, not fresh qualification of this source.</p>
{picture(root, "native-ancestor-readonly-inspect-r4/before/owned-window.png",
         "Read-only inspection of the existing synthetic TextEdit document; not a completion verdict.")}'''


def playback_evidence(root, lane):
    rows = lane["rows"]
    row = rows[0] if len(rows) == 1 else {}
    unchanged = row.get("actual_state", {}).get("playback_unchanged")
    result = {
        "fingerprint_changed": not unchanged if type(unchanged) is bool else None,
        "actor_pid": row.get("actor_pid"), "actor_dispatched_input_or_playback": None,
        "causality": "not_established", "forensics_sha256": None,
        "limitation": "Original combined fingerprint cannot distinguish state from track change",
    }
    path = root / "playback-event-forensics.json"
    if not path.is_file():
        return result
    result["forensics_sha256"] = digest(path)
    trace = json.loads(path.read_text())
    if (type(row.get("actor_pid")) is int and row["actor_pid"] > 0
            and trace.get("actor_pid") == row["actor_pid"]
            and row.get("visual_trace_complete") is True
            and trace.get("visual_primary") and trace["visual_primary"] == row.get("visual_trace")
            and isinstance(trace.get("tool_dispatch_effects"), list)):
        if trace["tool_dispatch_effects"]:
            result["actor_dispatched_input_or_playback"] = True
        elif all(item.get("message", "").startswith("Visual primary operation=none ")
                 for item in trace["visual_primary"]):
            result["actor_dispatched_input_or_playback"] = False
    return result


def timing(value):
    return "not measured" if value is None else f"{math.ceil(value) / 1000:.3f} s"


def escape(value):
    return html.escape(str(value))


def trial_table(rows):
    return "".join(
        f'<tr><td>{escape(row.get("run", ""))}</td><td>{escape(row["case"])}</td>'
        f'<td class="{"good" if row.get("strict_success") is True else "bad"}">{escape(row["status"])}</td>'
        f'<td>{escape(row.get("verified", "unknown"))}</td><td>{timing(row.get("wall_ms"))}</td></tr>'
        for row in rows)


def picture(root, relative, caption):
    path = root / relative
    if not path.is_file():
        return ""
    data = path.read_bytes()
    if not data.startswith(b"\x89PNG\r\n\x1a\n"):
        raise ValueError("report screenshot is not PNG")
    return f'<figure><img alt="{escape(caption)}" src="data:image/png;base64,{base64.b64encode(data).decode()}"><figcaption>{escape(caption)}</figcaption></figure>'


def render(data, root):
    native = data["native"]
    arms = {arm: summarize([row for row in native["rows"] if row["run"].startswith(arm)])
            for arm in ("before", "after")}
    score = lambda item: f'{item["strict_successes"]}/{item["trials"]}'
    everyday = data["everyday"]
    sections = []
    for name, lane in everyday.items():
        scores = lane.get("scores", summarize([]))
        details = "".join(f'<p class="detail">{escape(row.get("result_text", ""))}</p>' for row in lane["rows"])
        sections.append(f'<article><h3>{escape(name.title())}</h3><p class="bad">{score(scores)} strict command successes</p>'
                        f'<table><thead><tr><th>Run</th><th>Case</th><th>Reported</th><th>Native outcome</th><th>Command time</th></tr></thead>'
                        f'<tbody>{trial_table(lane["rows"])}</tbody></table>{details}</article>')
    attempts = "".join(f'<tr><td>{escape(lane["name"])}</td><td>{escape(lane["state"])}</td>'
                       f'<td>{len(lane["rows"])}</td><td>{lane["preflight_errors"]}</td>'
                       f'<td>{escape(lane["resources_clean"])}</td></tr>' for lane in data["all_attempts"])
    image_stats = data["image"]["scores"]
    native_exact = sum(row.get("actual_state", {}).get("document_body_matches") is True
                       and row.get("actual_state", {}).get("native_exact_value_verified") is True
                       for row in native["rows"])
    zero_counters = sum(row.get("actual_state", {}).get("target_count") == 0
                        and row.get("actual_state", {}).get("other_count") == 0
                        for row in data["image"]["rows"])
    source = data["source"]
    event = data["playback_event"]
    dispatch = event["actor_dispatched_input_or_playback"]
    playback_trace = ("The matching retained trace records no actor input or playback command."
                      if dispatch is False else
                      "An actor actuation event is recorded; its consequence needs separate review."
                      if dispatch is True else
                      "Available forensics cannot establish whether an actor input was dispatched.")
    fingerprint = ("The external playback fingerprint changed, so testing stopped."
                   if event["fingerprint_changed"] is True else
                   "The external playback fingerprint did not change."
                   if event["fingerprint_changed"] is False else
                   "The external playback fingerprint comparison is unavailable.")
    return f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Jev P4: Current Evidence</title>
<style>
:root{{color-scheme:light;--paper:#f5f2eb;--ink:#20231e;--muted:#60665c;--rule:#cecfc4;--bad:#a52c24;--good:#356347}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:17px Georgia,serif}}
main{{max-width:1120px;margin:auto;padding:60px 30px}}h1{{font-size:clamp(38px,7vw,78px);line-height:1.02;max-width:900px;margin:20px 0 30px}}
h2{{font-size:32px;margin:55px 0 20px}}h3{{font-size:25px;margin:0 0 14px}}p{{line-height:1.55;max-width:850px}}
.label,th,.metric b{{font-family:monospace}}.label{{letter-spacing:.12em;font-size:13px}}.muted,figcaption,.detail{{color:var(--muted)}}
.bad{{color:var(--bad)}}.good{{color:var(--good)}}.metrics{{display:grid;grid-template-columns:repeat(3,1fr);border-top:1px solid var(--rule);border-bottom:1px solid var(--rule)}}
.metric{{padding:25px 20px 25px 0}}.metric b{{display:block;font-size:42px;margin-bottom:10px}}article{{padding:25px 0;border-top:1px solid var(--rule)}}
table{{border-collapse:collapse;width:100%;font-size:14px}}th,td{{text-align:left;vertical-align:top;padding:12px 8px;border-bottom:1px solid var(--rule);overflow-wrap:anywhere}}
figure{{margin:25px 0}}img{{max-width:100%;max-height:500px;object-fit:contain}}figcaption{{font-size:14px;margin-top:8px}}
.detail{{font-size:14px}}code{{font-size:13px;overflow-wrap:anywhere}}@media(max-width:650px){{main{{padding:30px 16px}}.metrics{{grid-template-columns:1fr}}.metric{{padding:16px 0}}table{{font-size:11px}}th,td{{padding:8px 3px}}}}
</style><main>
<div class="label">JEV VOICE / P4 / SIGNED APP EVIDENCE</div><h1>Correct actions are not yet reliable commands.</h1>
<p class="bad"><strong>FAIL / OPEN. Candidate not installed.</strong></p>
<p>The signed app can replace the TextEdit document and calculate the right answer, but still refuses to confirm them reliably. The screenshot fallback also refuses the tested targets. No safety floor was lowered.</p>
<div class="metrics"><div class="metric"><b>{score(arms["after"])}</b>Earlier TextEdit candidate strict successes<br><span class="muted">Earlier baseline: {score(arms["before"])}</span></div>
<div class="metric"><b>{score(image_stats)}</b>Earlier packaged visual strict successes</div>
<div class="metric"><b>{sum(lane.get("scores", {}).get("strict_successes", 0) for lane in everyday.values())}/{sum(len(lane["rows"]) for lane in everyday.values())}</b>Earlier everyday-app pilot strict successes</div></div>
{native_context_section(data.get("native_context"), root)}
<h2>Earlier TextEdit Comparison</h2>
<p>Exact requested text and native verification: {native_exact}/{len(native["rows"])} comparisons. Candidate strict command successes: {score(arms["after"])}. A correct mutation with blocked status is a failed command, not a pass. The separate successful pilot is not included in the comparison score.</p>
<table><thead><tr><th>Run</th><th>Case</th><th>Reported</th><th>Native outcome</th><th>Command time</th></tr></thead><tbody>{trial_table(native["rows"])}</tbody></table>
<p class="muted">Times are rounded upward to the next millisecond. They exclude cold startup and the external native oracle. No successful-run median or percentile is claimed with fewer than three successes.</p>
<h2>Screenshot Fallback: Safe Refusals, No Qualification</h2>
<p>Both fixture counters stay zero in {zero_counters}/{image_stats["trials"]} commands. Candidate runs that pass target presence can still fail independent target/consequence checks. A box or presence vote is not permission to click.</p>
{picture(root, "exact-native-facts-image-ab/after-0/capture.png", "Controlled visual fixture. Neither counter was activated.")}
<h2>Ordinary Apps</h2>{"".join(sections)}
<p>Spotify playback is not qualified. Local output routing is unproven. {playback_trace} {fingerprint} Causality is not established. The playback forensic input is hash-bound in the JSON.</p>
<p>Chrome and Safari use ordinary fresh windows, not CDP or flags. The one labelled Notes fixture remains. Existing documents and user tabs were not edited or closed. Test-process cleanup is separate from intentionally retained fixture windows.</p>
<h2>All Attempts, Including Harness Failures</h2>
<p>Preflight failures below ran no Jev command. They are not silently counted as passes or as incorrect Jev actions. Corrected window-readiness and native-display checks were proven with fail-first guards and source review.</p>
<table><thead><tr><th>Evidence lane</th><th>State</th><th>Actor trials</th><th>Preflight failures</th><th>Runtime clean</th></tr></thead><tbody>{attempts}</tbody></table>
<h2>Subject And Limits</h2>
<p>Current product source matches signed candidate: <strong>{escape(source["matches_signed_source"])}</strong>, {source["source_files"]} files. Main and driver hashes are retained in the source evidence for every run.</p>
<p>Front door: signed embedded daemon MCP driving real macOS apps. This is not physical Fn, microphone, gaze or daily-app GUI proof. It does not replace P3, release signing, human qualification or P4 acceptance.</p>
<p>This self-contained page is generated from <code>evidence.json</code>. That JSON contains input hashes, every scored row, preflight errors, unknown results and coverage gaps. Nothing here changes an acceptance record.</p>
</main></html>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--artifacts", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    args = parser.parse_args()
    root = args.artifacts.resolve()
    if not root.is_dir():
        raise ValueError("existing artifact parent required")
    names = ["exact-native-facts-owned-pilot", "exact-native-facts-matched-ab", "exact-native-facts-image-ab"]
    names += sorted(path.name for path in root.glob("everyday-*")
                    if path.is_dir() and (path / "summary.json").is_file())
    names += sorted(path.parent.name for path in root.glob("native-ancestor-*/summary.json"))
    lanes = {name: load_lane(root, name) for name in names}
    latest = {
        "chrome": "everyday-chrome-readiness-pilot",
        "safari": "everyday-safari-readiness-pilot",
        "notes": "everyday-notes-pilot",
        "spotify": "everyday-spotify-pilot",
        "calculator": "everyday-calculator-readiness-pilot",
    }
    receipt = json.loads(args.receipt.read_text())
    spec = importlib.util.spec_from_file_location("report_source_subject", HERE / "jev-clone-stage.py")
    clone = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(clone)
    current = clone.sources()
    subject = receipt["candidates"]["after"]
    data = {
        "phase_status": "FAIL/open", "acceptance_changed": False, "candidate_installed": False,
        "front_door": "signed embedded daemon MCP into real macOS apps; not physical Fn/voice/gaze",
        "report_generator_sha256": digest(Path(__file__)),
        "source": {
            "receipt_sha256": digest(args.receipt),
            "source_files": len(current), "matches_signed_source": current == subject["source_sha256"],
            "current_source_sha256": current,
        },
        "native": lanes[names[1]], "image": lanes[names[2]],
        "native_context": native_context_evidence(root),
        "everyday": {name: lanes[path] for name, path in latest.items()},
        "all_attempts": list(lanes.values()),
        "coverage_gaps": [
            "Exact native replacement is not reliably reported done",
            "Visual fallback did not pass the controlled fixture",
            "Everyday-app pilots fail; no reliable three-repeat qualification",
            "Spotify local output routing and playback are unqualified",
            "No physical Fn, microphone, gaze, human release or daily-app proof",
            "Native context has no demonstrated reliability gain; interrupted comparison and logging-only harness delta",
            "Intermittent preflight readback refusals remain unexplained; request count and bytes not measured",
        ],
        "playback_event": playback_evidence(root, lanes[latest["spotify"]]),
    }
    out = root / "p4-current-evidence"
    marker = out / ".owner"
    if out.exists() and (not marker.is_file() or marker.read_text() != "jev-p4-evidence-v1\n"):
        raise ValueError("report output is not an owned generated directory")
    out.mkdir(mode=0o700, exist_ok=True)
    marker.write_text("jev-p4-evidence-v1\n")
    (out / ".gitignore").write_text("*\n")
    (out / "evidence.json").write_text(json.dumps(data, indent=2) + "\n")
    page = render(data, root)
    (out / "report.html").write_text(page)
    print(out / "report.html")
    print("P4 FAIL/open; native and everyday command results remain separate from verified mutations")


if __name__ == "__main__":
    main()
