import argparse
import base64
import html
import importlib.util
import json
from pathlib import Path


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("dispatch_shared_audit", HERE / "jev-calculator-comparison-report.py")
BASE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BASE)
SCOPE = ["Sources/JevVoice/Drive/DriveLoop.swift", "Sources/JevVoice/Driver/CuaConnection.swift"]


def audit(root):
    root = Path(root)
    data = BASE.audit(root, expected_delta=SCOPE, prior_names=())
    summary = BASE.read(root / "summary.json")
    origin = Path(summary["execution"]["argv"][summary["execution"]["argv"].index("--out") + 1]).parent
    setup, actors = [], []
    for row in data["rows"]:
        record = BASE.read(root / row["run"] / "results.json")
        seed = record["calculator_seed"]
        BASE.require(seed["observation_timeout_ms"] == 5000
                     and seed["final_observation"]["truncated"] is False, "setup policy or completeness changed")
        proofs = record["native_complete_reads"]
        target = seed["target"]
        BASE.require(len(proofs) >= len(seed["presses"]) + 1, "missing native setup proof")
        for proof in proofs:
            BASE.require(proof["ax_trusted"] is True and proof["target_found"] is True
                         and proof["budget_exhausted"] is False and proof["modal_sheets"] == 0
                         and proof["children_read_failures"] == 0 and proof["role_read_failures"] == 0
                         and all(proof[key] == target[key] for key in ("pid", "window_id")),
                         "incomplete or foreign native setup proof")
        actors.append(row["actor_pid"])
        setup.append(dict(run=row["run"], wall_ms=seed["setup_wall_ms"],
                          partial_reads=sum(item["truncated"] is not False for item in seed["observations"]),
                          native_proofs=len(proofs), presses=len(seed["presses"])))
    BASE.require(len(set(actors)) == len(data["rows"]), "matched goals reused a product actor")
    failures = []
    for name, seed_name in (
            ("native-d14-calculator-pilot", "calculator-cold-seed.json"),
            ("native-d14-calculator-comparison", "calculator-seed.json"),
            ("native-d14-calculator-comparison-r2", "calculator-seed.json")):
        prior = BASE.read(origin / name / "summary.json")
        run = origin / name / prior["failed_run"]
        record = BASE.read(run / "results.json")
        seed = BASE.read(run / seed_name)
        BASE.require(prior["status"] == "error" and record["resources_clean"] is True
                     and record["execution_lease_closed"] is True and record["drive_requests"] == 0
                     and record["rows"] == [] and seed["presses"] == [], "earlier setup outcome changed")
        failures.append(dict(name=name, goals=0, presses=0, error=prior["error_message"],
                             partial_reads=len(seed["observations"])))
        data["inputs"][str(run / seed_name)] = BASE.digest(run / seed_name)
        data["inputs"][str(run / "results.json")] = BASE.digest(run / "results.json")
    pilot_path = origin / "native-d14-calculator-pilot-r2/after-0/results.json"
    pilot = BASE.read(pilot_path)
    argv = summary["execution"]["argv"]
    subject = BASE.read(Path(argv[argv.index("--receipt") + 1]))["candidates"]["after"]
    BASE.require(pilot["resources_clean"] is True and pilot["execution_lease_closed"] is True
                 and pilot["drive_requests"] == 2 and len(pilot["rows"]) == 2
                 and len({row["actor_pid"] for row in pilot["rows"]}) == 1
                 and pilot["binary_sha256"] == subject["binary_sha256"]
                 and pilot["driver_sha256"] == data["driver_sha256"], "pilot ownership or subject changed")
    diagnostic_path = origin / "native-d14-calculator-readonly-5000/results.json"
    diagnostic = BASE.read(diagnostic_path)
    BASE.require(diagnostic["drive_requests"] == diagnostic["model_requests"] == diagnostic["input_actuations"] == 0
                 and diagnostic["resources_clean"] is True and diagnostic["native_scope_proven"] is True
                 and diagnostic["driver_sha256"] == data["driver_sha256"],
                 "read-only diagnostic scope changed")
    sample = diagnostic_path.parent / "driver-sample.txt"
    BASE.require(BASE.digest(sample) == diagnostic["driver_sample"]["sha256"]
                 and diagnostic["driver_sample"]["return_code"] == 0, "driver sample changed")
    for path in (pilot_path, diagnostic_path, sample):
        data["inputs"][str(path)] = BASE.digest(path)
    pairs = [(before, after) for before in data["rows"] for after in data["rows"]
             if before["run"].startswith("before-")
             and before["run"].replace("before", "after") == after["run"]
             and before["strict_success"] and after["strict_success"]]
    data.update(setup=setup, setup_failures=failures, setup_failure_goals=0,
                pilot=pilot["rows"], diagnostic_wall_ms=diagnostic["diagnostic_observation_wall_ms"],
                successful_pairs=len(pairs),
                faster_pairs=sum(after["wall_ms"] < before["wall_ms"] for before, after in pairs),
                slower_pairs=sum(after["wall_ms"] > before["wall_ms"] for before, after in pairs))
    return data


def render(data, root):
    escape = html.escape
    seconds = BASE.seconds
    candidate, baseline = data["candidate"], data["baseline"]
    comparison = ("worse" if candidate["strict_successes"] < baseline["strict_successes"] else
                  "better" if candidate["strict_successes"] > baseline["strict_successes"] else "unchanged")
    rows = "".join(
        f'<tr><td>{row["run"]}</td><td>{escape(row["status"])}</td>'
        f'<td>{escape(str(row["actual_state"]["display"]))}</td>'
        f'<td>{seconds(row["wall_ms"])}</td><td>{"pass" if row["strict_success"] else "FAIL"}</td></tr>'
        for row in data["rows"])
    setup = "".join(
        f'<tr><td>{item["run"]}</td><td>{seconds(item["wall_ms"])}</td>'
        f'<td>{item["partial_reads"]}</td><td>{item["native_proofs"]}</td></tr>'
        for item in data["setup"])
    pilots = "".join(
        f'<li>{escape(row["kind"])}: {seconds(row["wall_ms"])}; '
        f'{escape(row["status"])}; verified={row["verified"]}</li>' for row in data["pilot"])
    failures = "".join(
        f'<li>{escape(item["name"])}: {item["goals"]} goals, {item["presses"]} presses, '
        f'{item["partial_reads"]} partial observations; {escape(item["error"])}</li>'
        for item in data["setup_failures"])
    pictures = []
    for name in ("after-0", "after-2"):
        path = Path(root) / name / "calculator-after.png"
        if path.is_file():
            raw = path.read_bytes()
            BASE.require(raw.startswith(b"\x89PNG\r\n\x1a\n"), "invalid scoped screenshot")
            pictures.append(f'<figure><img alt="Calculator return state {name}" '
                            f'src="data:image/png;base64,{base64.b64encode(raw).decode()}">'
                            f'<figcaption>{name}: independent return-state capture</figcaption></figure>')
    median = ("No qualifying candidate median" if candidate["successful_median_ms"] is None
              else seconds(candidate["successful_median_ms"]) + " candidate median")
    return f'''<!doctype html><html lang="en"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>D14: P4 remains open</title><style>
:root{{color-scheme:light;--paper:#f5f2eb;--ink:#20231e;--rule:#cecfc4;--bad:#a52c24}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:18px Georgia,serif}}
main{{max-width:1060px;margin:auto;padding:44px 24px}}h1{{font-size:clamp(38px,7vw,72px);line-height:1.05}}
h2{{margin-top:42px}}p,li{{line-height:1.55}}.bad{{color:var(--bad)}}.scroll{{overflow:auto}}
table{{border-collapse:collapse;width:100%;font-variant-numeric:tabular-nums}}
td,th{{padding:12px 8px;text-align:left;border-bottom:1px solid var(--rule)}}
.pictures{{display:flex;flex-wrap:wrap;gap:28px}}figure{{margin:0;flex:1;min-width:230px}}
img{{width:100%;max-width:320px}}figcaption{{font-size:15px;padding:12px 0}}
</style><main><p>Signed native MCP front door. Prepared runtime. Not physical Fn or pill proof.</p>
<h1>P4 remains open.</h1>
<p class="bad">Candidate: {candidate["strict_successes"]}/3. Baseline: {baseline["strict_successes"]}/3.
False Done: {data["false_done"]}. Completion count is {comparison} in this comparison.</p>
<h2>{median}</h2>
<p>The unchanged bar is 4 seconds. Three strict successes are required for a qualifying median.
Baseline successful median: {seconds(baseline["successful_median_ms"])}.
There are {data["successful_pairs"]} pairs where both builds finish:
{data["faster_pairs"]} candidate returns are faster and {data["slower_pairs"]} are slower.
That does not establish an end-to-end speed or reliability win.</p>
<div class="scroll"><table><tr><th>Run</th><th>Reported</th><th>Display</th><th>Return Time</th><th>Strict</th></tr>
{rows}</table></div>
<p>Order A/B, B/A, A/B. One goal per fresh product actor. Same driver, runtime payloads,
initial 2+3=5, empty values, oracle and 30-second caller deadline. The deadline is not the release bar.</p>
<div class="pictures">{"".join(pictures)}</div>
<h2>Setup Is Not Goal Time</h2>
<p>Both arms use 5000 ms only for private setup reads. Every setup press still requires
a full non-truncated snapshot and independent complete native identity/modal checks.
Product observations and goal timing are unchanged. Setup makes this prepared-state evidence,
not production cold-start evidence. All six execution leases close cleanly.</p>
<div class="scroll"><table><tr><th>Run</th><th>Setup</th><th>Partial Reads</th><th>Native Proofs</th></tr>
{setup}</table></div>
<h2>Earlier Outcomes Stay In The Record</h2><ul>{failures}</ul>
<p>The separate pilot reuses one product actor. Actual driver transport generation/session epoch
is not exported, so the second row proves same-client reuse, not a measured cache hit.</p><ul>{pilots}</ul>
<p>Read-only diagnosis: {seconds(data["diagnostic_wall_ms"])} for a complete driver observation
under its explicit 5000 ms diagnostic budget. Zero input, goals and model requests.
The sampled driver waits in AXUIElementCopyMultipleAttributeValues during tree traversal.
Sampling time is diagnostic, not an A/B performance result.</p>
<h2>Limits</h2><p>No 95% reliability, everyday-app, physical front-door, cursor visual-quality,
production cold-start, installation or release claim. Model-request counts and driver substage
CPU costs are not measured. The failed command remains a failed command, not a fast success.</p>
<p>Generated from raw rows, seed receipts, native proofs, frozen measuring sources and signed subject
hashes. See comparison-audit.json and summary.json. No acceptance flags change.</p></main></html>'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--comparison", type=Path, required=True)
    args = parser.parse_args()
    data = audit(args.comparison)
    (args.comparison / "comparison-audit.json").write_text(json.dumps(data, indent=2) + "\n")
    (args.comparison / "report.html").write_text(render(data, args.comparison))
    print("D14 report generated; phase_qualified=false")


if __name__ == "__main__":
    main()
