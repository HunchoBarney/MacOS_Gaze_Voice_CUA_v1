import argparse
import base64
import html
import importlib.util
import json
import math
import os
from pathlib import Path
import statistics


HERE = Path(__file__).resolve().parent


def read(path):
    return json.loads(path.read_text())


def seconds(milliseconds):
    return f"{math.ceil(milliseconds) / 1000:.3f} s"


def fraction(record):
    return f'{sum(row["strict_success"] is True for row in record["rows"])}/{len(record["rows"])}'


def picture(record_path):
    path = record_path.parent / "profile-placeholder-local.png"
    if not path.is_file():
        return ""
    image = base64.b64encode(path.read_bytes()).decode()
    return f'<img alt="Synthetic fixture window, not the user desktop" src="data:image/png;base64,{image}">'


def rows(record):
    output = []
    for row in record["rows"]:
        status = html.escape(row["status"])
        case = html.escape(row["case"])
        good = row["strict_success"] is True
        cancelled = " / caller cancelled" if row["cancelled_by_harness"] else ""
        output.append(f'<tr><td>{case} / {row["trial"] + 1}</td>'
                      f'<td class="{"good" if good else "bad"}">{status}{cancelled}</td>'
                      f'<td>{str(row["verified"]).lower()}</td>'
                      f'<td>{seconds(row["wall_ms"])}</td></tr>')
    return "".join(output)


def chart(record):
    maximum = max(10000, max(row["wall_ms"] for row in record["rows"]))
    return "".join(
        f'<div class="bar"><span>Trial {row["trial"] + 1}</span>'
        f'<i style="width:{row["wall_ms"] / maximum * 70:.4f}%"></i>'
        f'<b>{seconds(row["wall_ms"])}</b></div>' for row in record["rows"])


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--goal", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--receipt", type=Path,
                        default=HERE / "jev-candidate-stage-6ec2307771e34c8aaee594112231d5f5.json")
    args = parser.parse_args()
    before_path = HERE / "native-pilot-cec8134bb3c840efa991aea407890827/results.json"
    after_path = HERE / "native-pilot-e26e9a1d5e764aba883183cade15cc71/results.json"
    before, after = read(before_path), read(after_path)
    native, goal = read(args.native), read(args.goal)
    receipt_path = args.receipt
    receipt = read(receipt_path)
    spec = importlib.util.spec_from_file_location("clone_receipt", HERE / "jev-clone-stage.py")
    clone = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(clone)
    if clone.sources() != receipt["source_sha256"]:
        raise SystemExit("current source differs from signed receipt")
    for key in ("strict_signature", "immutable_resources_identical",
                "unchanged_designated_requirement"):
        if receipt[key] is not True:
            raise SystemExit(f"signed receipt check failed: {key}")
    app = Path(receipt["app"])
    if clone.signing_metadata(app) != receipt["unchanged_signing_metadata"]:
        raise SystemExit("candidate signing metadata differs from receipt")
    if clone.digest(app / "Contents/MacOS/JevVoice") != receipt["binary_sha256"]:
        raise SystemExit("candidate binary differs from receipt")
    for key in ("harness_sha256", "workload_sha256", "driver_sha256", "fixture_sha256",
                "fixture_source_sha256", "base_harness_sha256", "verifier_sha256"):
        if before[key] != after[key]:
            raise SystemExit(f"unmatched correctness comparison: {key}")
    if any(record["binary_sha256"] != receipt["binary_sha256"] for record in (after, native, goal)):
        raise SystemExit("candidate evidence does not match signed receipt")
    if before["binary_sha256"] != receipt["template_main_sha256"]:
        raise SystemExit("baseline evidence does not match template binary")
    if any(record["resources_clean"] is not True for record in (before, after, native, goal)):
        raise SystemExit("test resources did not cleanly stop")
    successful = [row["wall_ms"] for row in native["rows"] if row["strict_success"] is True]
    native_latency = seconds(statistics.median(successful)) if successful else "none"
    false_done = sum(row["false_done"] is True for record in (after, native, goal) for row in record["rows"])
    source_code = html.escape(receipt["binary_sha256"])
    evidence_paths = [before_path, after_path, args.native, args.goal, receipt_path]
    links = "".join(f'<li><a href="{html.escape(os.path.relpath(path, HERE))}">'
                    f'{html.escape(path.parent.name + "/" + path.name)}</a></li>' for path in evidence_paths)
    table = '<thead><tr><th>Case / trial</th><th>Reported outcome</th><th>State verified</th><th>Wall time</th></tr></thead>'
    document = f"""<!doctype html>
<html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Jev / P4 Evidence</title>
<style>
:root{{--paper:#f3f0e7;--ink:#242a26;--muted:#62685d;--line:#cecbbf;--green:#216b46;--red:#a6402a;--scale:8px}}
*{{box-sizing:border-box}}body{{margin:0;background:var(--paper);color:var(--ink);font:18px/1.5 Georgia,serif}}
main{{max-width:1248px;margin:auto;padding:64px 32px}}h1{{font-size:clamp(48px,8vw,104px);line-height:1;letter-spacing:-.055em;max-width:1000px;margin:24px 0 32px}}
h2{{font-size:36px;line-height:1.1;letter-spacing:-.025em}}p{{max-width:840px}}.mono,table,.tag,.bar{{font-family:"SF Mono","Courier New",monospace;font-size:13px}}
.tag{{text-transform:uppercase;letter-spacing:.14em;color:var(--red)}}.stats{{display:grid;grid-template-columns:repeat(4,1fr);border-block:1px solid var(--ink);margin:48px 0}}
.stat{{padding:24px 16px 24px 0}}.stat strong{{display:block;font-size:40px;font-weight:normal;letter-spacing:-.04em}}
.stat span{{font-size:14px;color:var(--muted)}}section{{border-bottom:1px solid var(--line);padding:32px 0 48px}}.pair{{display:grid;grid-template-columns:1fr 1fr;gap:32px}}
.pair article{{min-width:0}}.pair img{{width:100%;height:auto;border:1px solid var(--line);display:block}}pre{{white-space:pre-wrap;font:14px/1.7 "SF Mono","Courier New",monospace;border-left:3px solid var(--line);padding-left:16px}}
.good{{color:var(--green)}}.bad{{color:var(--red)}}.note{{font-size:15px;color:var(--muted)}}table{{width:100%;border-collapse:collapse;min-width:640px}}
td,th{{text-align:left;padding:16px 8px;border-bottom:1px solid var(--line)}}.scroll{{overflow:auto}}.bar{{display:flex;align-items:center;gap:16px;margin:16px 0}}
.bar i{{display:block;height:16px;background:var(--green)}}.bar b{{font-weight:normal;white-space:nowrap}}a{{color:inherit;text-underline-offset:4px}}li{{margin:8px 0}}
.pipeline{{padding:24px 0;font:15px/2 "SF Mono","Courier New",monospace}}code{{overflow-wrap:anywhere}}
@media(max-width:720px){{main{{padding:32px 16px}}.stats{{grid-template-columns:1fr 1fr}}.pair{{grid-template-columns:1fr}}h2{{font-size:28px}}}}
</style>
<main><div class="tag">Jev Voice / P4 qualification / no-go</div>
<h1>Fixed input.<br>Not a finished phase.</h1>
<p>Jev was told an empty field already contained the word <em>Email</em>.
The new signed build reads actual contents, keeps the original control identity,
and finishes the same test correctly. Speed and goal-only completion still do not meet the release bar.</p>
<div class="stats"><div class="stat"><strong>4 / 6</strong><span>P4 gates green, not an effort estimate</span></div>
<div class="stat"><strong>1,191</strong><span>Swift tests, 18 skipped, zero failures</span></div>
<div class="stat"><strong>234</strong><span>Tracker tests and typecheck pass</span></div>
<div class="stat"><strong>No install</strong><span>Candidate remains held</span></div></div>
<section><div class="tag">01 / actual data bug</div><h2>A hint is not an entered value.</h2>
<div class="pair"><article><h3 class="bad">Before: {fraction(before)} strict success</h3>
<pre>UI placeholder:       Email
Actual field value:   ""
Value given to Jev:   "Email"
Literal already set:  true
Saved Email:          ""</pre>{picture(before_path)}</article>
<article><h3 class="good">After: {fraction(after)} strict success</h3>
<pre>UI placeholder:       Email
Actual field value:   ""
Value given to Jev:   ""
Literal already set:  false
Saved Email:          "Email"</pre>{picture(after_path)}</article></div>
<p class="note">Same corrected workload, harness, driver, fixture and verifier hashes.
One old-build trial versus three new-build trials. Small reproduction, not a general accuracy estimate.
Both use an explicitly labelled 30-second diagnostic caller deadline.</p>
<h3>Successful corrected-input wall times</h3>{chart(after)}
<p class="note">The median is {seconds(statistics.median(row["wall_ms"] for row in after["rows"]))}.
The old build failed, so its wall time is not a successful-completion baseline. No speed improvement is claimed.</p></section>
<section><div class="tag">02 / current signed native slice</div><h2>{fraction(native)} strict successes.</h2>
<p>Original caller deadlines, no diagnostic extension. A physical state match alone does not count:
the outcome must be done/already, verified, non-error and not cancelled.</p>
<div class="scroll"><table>{table}<tbody>{rows(native)}</tbody></table></div>
<p class="note">Median successful completion: {native_latency}. Cancelled runs are censored, not completed tasks.
P4 requires at least 95% strict success and p50 at most 4 seconds.</p>
<h3>Goal-only completion: {fraction(goal)}</h3>
<div class="scroll"><table>{table}<tbody>{rows(goal)}</tbody></table></div>
<p class="note">No caller-supplied success string. A finished UI with a refusal is still a strict failure.
False completion claims in these current candidate runs: {false_done}.</p></section>
<section><div class="tag">03 / what changed</div><h2>Better evidence. Same authority.</h2>
<div class="pipeline">Goal &rarr; captured window &rarr; actual values &rarr; Jev judgment &rarr; existing executor &rarr; fresh outcome proof</div>
<p>Empty is known empty. A failed read is unknown. Secure fields are filtered before their values are read.
Only exact, unique same-window matches can correct existing driver rows. Native data cannot create control tokens.</p>
<p>There is no fixed production step ceiling. Progress can continue, but permissions, cancellation,
stale-state checks and the no-progress guard stay in force. No confidence floor was lowered.
No slower model was added to each action.</p>
<p class="note">Independent source review: SOURCEPASS. Phase review: FAIL.
This is not a full security audit or voice/microphone qualification.</p></section>
<section><div class="tag">04 / evidence discipline</div><h2>The failures stay in the record.</h2>
<p>The first new placeholder test had a bad success string: it requested the word Email but still expected
the old address. That test bug is fixed, with a failing-first corpus check and a matched rerun of both builds.
The original failed artifacts remain untouched.</p>
<p>The older 45/48 score was a small synthetic decision sample, not 48 real voice workflows.
Its three misses were refusals from follow-up checks, not wrong clicks. Later native tests exposed
additional data bugs. It would be misleading to call the product 48/48 now.</p>
<p>P4 stays open for end-to-end reliability, latency and a passing phase judge.
The candidate is not installed. No user browsers, documents, microphone tests or permission settings were reset.</p>
<ul class="mono">{links}</ul><p class="note">Signed candidate binary SHA-256:<br><code>{source_code}</code></p></section>
</main></html>"""
    output = args.output
    if args.check or output.exists():
        if not output.is_file() or output.read_text() != document:
            raise SystemExit("named report differs from current evidence; refusing to overwrite")
        print(f"{output}: unchanged; source, receipt and evidence checks passed")
        return
    with os.fdopen(os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600), "w") as handle:
        handle.write(document)
    print(output)


if __name__ == "__main__":
    main()
