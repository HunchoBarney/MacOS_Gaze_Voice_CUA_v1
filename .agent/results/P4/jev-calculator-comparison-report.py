import argparse
import base64
import hashlib
import html
import json
import math
from pathlib import Path
import statistics


ORDER = ["before-0", "after-0", "after-1", "before-1", "before-2", "after-2"]
GOAL = "Calculate 3 plus 4 and show the result."


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise ValueError("unreadable evidence: " + path.name) from error


def digest(path):
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except OSError as error:
        raise ValueError("missing evidence: " + path.name) from error


def stats(rows):
    times = [row["wall_ms"] for row in rows if row["strict_success"]]
    return dict(trials=len(rows), strict_successes=len(times),
                successful_median_ms=statistics.median(times) if len(times) >= 3 else None,
                successful_samples_ms=times)


def audit(root, expected_delta=None, prior_names=None):
    root = Path(root)
    summary = read(root / "summary.json")
    require(summary.get("status") in ("pass", "fail"), "comparison did not complete")
    require(list(summary["variants"]) == ORDER and summary["repeats"] == 3, "comparison order or count changed")
    argv = summary["execution"]["argv"]
    receipts = {}
    for arm, flag, key in (("before", "--baseline-receipt", "baseline_receipt_sha256"),
                           ("after", "--receipt", "receipt_sha256")):
        path = Path(argv[argv.index(flag) + 1])
        require(digest(path) == summary[key], "stage receipt changed")
        receipts[arm] = read(path)["candidates"]["after"]
    for key in ("driver_sha256", "unsigned_driver_sha256", "code_resources_sha256"):
        require(receipts["before"][key] == receipts["after"][key], "driver or resources differ")
    for subject in receipts.values():
        require(subject.get("strict_signature") is True and subject.get("frozen_payload_verified") is True,
                "missing signed payload admission")
        require(digest(Path(subject["app"]) / "Contents/MacOS/JevVoice") == subject["binary_sha256"],
                "retained signed executable changed")
    before, after = (receipts[arm]["source_sha256"] for arm in ("before", "after"))
    require(before.keys() == after.keys(), "production source set differs")
    delta = [key for key in before if before[key] != after[key]]
    legacy_delta = ["Sources/JevVoice/Drive/JevVisualDecision.swift"]
    expected_delta = legacy_delta if expected_delta is None else expected_delta
    require(set(delta) == set(expected_delta), "unexpected production delta")
    if expected_delta != legacy_delta:
        path = Path(argv[argv.index("--reviewed-source-delta") + 1])
        require(digest(path) == summary["reviewed_source_delta_sha256"], "reviewed source receipt changed")
        reviewed = read(path)
        require(reviewed.get("verdict") == "PASS"
                and set(reviewed["source_changes"]) == set(delta), "source review scope differs")
        require(digest(Path(reviewed["review_receipt"])) == reviewed["review_receipt_sha256"],
                "source review changed")
        for name in delta:
            require(reviewed["source_changes"][name] == dict(before=before[name], after=after[name]),
                    "source review does not bind signed subjects")
    frozen = read(root / "harness-source/sha256.json")
    for name, expected in frozen.items():
        require(digest(root / "harness-source" / name) == expected, "measuring instrument changed")
    require(frozen["jev-vision-qualification.py"] == summary["harness_sha256"]
            and frozen["jev-realapps.py"] == summary["session_harness_sha256"]
            and frozen["jev-realapps-native.py"] == summary["native_helpers_sha256"],
            "measuring instrument does not match run")
    rows, inputs, setup_presses = [], {}, 0
    for run in ORDER:
        path = root / run / "results.json"
        record = read(path)
        seed = read(root / run / "calculator-seed.json")
        require(record.get("resources_clean") is True and record.get("execution_lease_closed") is True,
                "run resources not clean")
        require(record.get("calculator_seed") == seed and seed.get("verified") is True
                and seed.get("display") == "5" and seed.get("expression_present") is True,
                "initial state not verified")
        require(1 <= len(seed["presses"]) <= 6, "setup action budget exceeded")
        setup_presses += len(seed["presses"])
        require(record["driver_sha256"] == receipts[run.split("-")[0]]["driver_sha256"]
                and record["binary_sha256"] == receipts[run.split("-")[0]]["binary_sha256"],
                "run subject mismatch")
        require(record["harness_sha256"] == frozen["jev-realapps.py"]
                and record["everyday_helpers_sha256"] == frozen["jev-everyday-apps.py"]
                and record["native_oracle_source_sha256"] == frozen["jev-native-field-probe.swift"],
                "run instrument mismatch")
        require(record["drive_requests"] == 1 and len(record["rows"]) == 1
                and record["rows"] == summary["variants"][run]["rows"], "summary and raw rows disagree")
        row = record["rows"][0]
        require(row["goal"] == GOAL and row["completion_hints_sent"] is False
                and row["caller_deadline_seconds"] == 30, "task changed")
        require(isinstance(row["wall_ms"], (int, float)) and math.isfinite(row["wall_ms"])
                and row["wall_ms"] > 0, "invalid task timing")
        require(row["strict_success"] is (row["status"] in ("done", "already")
                and row["verified"] is True and row["is_error"] is False
                and row["cancelled_by_harness"] is False), "strict verdict disagrees")
        actual = row["actual_state"]
        require(actual["expected"] == "7" and row["verified"] is (
            actual.get("display_evidence_available") is True and actual.get("display") == "7"),
            "independent display outcome disagrees")
        require(row["false_done"] is (row["status"] in ("done", "already") and not row["verified"]),
                "false Done verdict disagrees")
        rows.append(dict(row, run=run))
        for source in (path, root / run / "calculator-seed.json"):
            inputs[str(source.relative_to(root))] = digest(source)
    baseline = stats([row for row in rows if row["run"].startswith("before")])
    candidate = stats([row for row in rows if row["run"].startswith("after")])
    prior_attempts = []
    origin = Path(argv[argv.index("--out") + 1]).parent
    if prior_names is None:
        prior_names = ("native-d13-calculator-comparison", "native-d13-calculator-comparison-r2",
                       "native-d13-calculator-comparison-r3")
    for name in prior_names:
        prior_summary = read(origin / name / "summary.json")
        failed = origin / name / prior_summary["failed_run"]
        prior_record = read(failed / "results.json")
        prior_seed = read(failed / "calculator-seed.json")
        require(prior_record.get("resources_clean") is True and prior_record.get("drive_requests") == 0,
                "prior preparation outcome changed")
        prior_attempts.append(dict(name=name, setup_presses=len(prior_seed["presses"]),
                                   error=prior_summary["error_message"], goals=0))
    return dict(order=list(ORDER), rows=rows, baseline=baseline, candidate=candidate,
                setup_presses=setup_presses, false_done=sum(row["false_done"] is True for row in rows),
                p4_latency_met=candidate["successful_median_ms"] is not None
                and candidate["successful_median_ms"] <= 4000,
                phase_qualified=False, inputs=inputs, source_delta=delta,
                prior_attempts=prior_attempts,
                driver_sha256=receipts["after"]["driver_sha256"],
                unsigned_driver_sha256=receipts["after"]["unsigned_driver_sha256"],
                summary_sha256=digest(root / "summary.json"))


def seconds(value):
    return "No successful baseline" if value is None else f"{math.ceil(value) / 1000:.3f} s"


def render(data, root):
    escape = html.escape
    cells = "".join(f'<tr><td>{row["run"]}</td><td>{escape(row["status"])}</td>'
                    f'<td>{escape(str(row["actual_state"]["display"]))}</td>'
                    f'<td>{escape(str(row["strict_success"]))}</td><td>{seconds(row["wall_ms"])}</td></tr>'
                    for row in data["rows"])
    screenshots = []
    prior_presses = sum(item["setup_presses"] for item in data["prior_attempts"])
    for run in ("after-0", "before-1"):
        path = root / run / "calculator-after.png"
        if path.is_file():
            raw = path.read_bytes()
            require(raw.startswith(b"\x89PNG\r\n\x1a\n"), "invalid screenshot")
            screenshots.append(f'<figure><img alt="Calculator {run}" src="data:image/png;base64,'
                               f'{base64.b64encode(raw).decode()}"><figcaption>{run}: retained window readback</figcaption></figure>')
    return f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Jev Calculator: P4 Remains Open</title><style>
:root{{color-scheme:light;--paper:#f5f2eb;--ink:#20231e;--rule:#cecfc4;--bad:#a52c24}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:18px Georgia,serif}}
main{{max-width:1040px;margin:auto;padding:48px 24px}}h1{{font-size:clamp(36px,7vw,72px);line-height:1.05}}
h2{{margin-top:48px}}p{{line-height:1.55;max-width:75ch}}.bad{{color:var(--bad)}}
table{{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}}
td,th{{padding:12px 6px;text-align:left;border-bottom:1px solid var(--rule)}}.scroll{{overflow:auto}}
.pictures{{display:flex;gap:24px;flex-wrap:wrap}}figure{{margin:0;flex:1;min-width:230px}}
img{{display:block;width:100%;max-width:320px}}figcaption{{padding:12px 0;font-size:15px}}
</style><main><p>Signed embedded MCP control loop. Not physical Fn, pill or microphone proof.</p>
<h1>Completion improves in this slice.<br>P4 remains open.</h1>
<p>Baseline: {data["baseline"]["strict_successes"]}/3 strict successes.
Candidate: {data["candidate"]["strict_successes"]}/3. False Done: {data["false_done"]}.
Every goal starts from a separately verified 2+3=5.</p>
<h2 class="bad">{seconds(data["candidate"]["successful_median_ms"])} successful median</h2>
<p>The P4 limit is 4 seconds. Baseline successful median: {seconds(data["baseline"]["successful_median_ms"])}.
There is no successful baseline for a speed-gain claim. Three candidate successes do not establish 95% reliability.</p>
<div class="scroll"><table><tr><th>Run</th><th>Reported</th><th>Display</th><th>Strict</th><th>Return Time</th></tr>{cells}</table></div>
<p>Order: A/B, B/A, A/B. Same signed and unsigned driver payload across arms.
Setup: {data["setup_presses"]} native presses, excluded from task timing.
All six runtimes close cleanly. The caller deadline is 30 seconds, not the P4 speed bar.</p>
<div class="pictures">{"".join(screenshots)}</div>
<h2>Limits</h2><p>Earlier preparation attempts stop before any goal: SDK projected completeness,
readonly expression parsing, then an unexplained native scope refusal. {prior_presses} earlier setup presses are retained;
none is a product success. The one-run 12.074-second D13 pilot is separate.</p>
<p>Native input uses Accessibility. Screenshot-assisted completion does not qualify screenshot-only targeting.
No everyday-app release set is requalified here. Cold runtime preparation remains separate.
The measured harness sends empty values and no answer hint; actual request bytes are not retained.
Model-request counts and driver substage CPU costs are not measured.</p>
<p>Generated from raw session records, seed receipts, signed stage identities and frozen harness hashes.
See comparison-audit.json and summary.json beside this page. No install or acceptance flag change.</p></main></html>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--comparison", type=Path, required=True)
    args = parser.parse_args()
    data = audit(args.comparison)
    (args.comparison / "comparison-audit.json").write_text(json.dumps(data, indent=2) + "\n")
    (args.comparison / "report.html").write_text(render(data, args.comparison))
    print("comparison audit and report written; phase_qualified=false")


if __name__ == "__main__":
    main()
