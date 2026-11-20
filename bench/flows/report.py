"""Phase 0/1 flow benchmark report (JARA-41, JARA-42).

  python3 bench/flows/report.py bench/results/flows.jsonl [bench/results/realtime.jsonl]

Rows carry a label (the commit by default), so one file holds before and
after. For each label and flow the table shows the mouse-and-keyboard KLM
baselines and Jarvis's time from the final transcript to the action, with
the driver free (Jarvis's own code) and with the replayed driver profile.
Release-to-action adds the server's release-to-transcript time: measured
Realtime rows when given, else the pre-reset measurement (0.44 s p50,
1.6 s p90), labelled as cited.
"""
import itertools
import json
import math
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from klm import baselines  # noqa: E402

FLOWS = ["open_app", "click_named", "show_names", "lost_window", "switch_desktop"]
CITED_TRANSCRIPT_MS = [440.0] * 9 + [1600.0]


def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    return s[min(len(s) - 1, max(0, math.ceil(len(s) * p) - 1))]


def summed(a, b):
    return [x + y for x, y in itertools.product(a, b)]


def fmt(ms):
    return "–" if ms is None else f"{ms / 1000:.2f}"


def load(paths):
    rows = []
    for path in paths:
        for line in pathlib.Path(path).read_text().splitlines():
            if line.strip():
                rows.append(json.loads(line))
    return rows


def main(argv):
    rows = load(argv[1:])
    flows = [r for r in rows if r.get("kind") == "flow"]
    realtime = [r for r in rows if r.get("kind") == "realtime"]
    labels = list(dict.fromkeys(r["label"] for r in flows))
    klm = baselines()

    fn = [r["release_to_transcript_ms"] for r in realtime if r.get("mode") == "fn" and "release_to_transcript_ms" in r]
    transcript = fn or CITED_TRANSCRIPT_MS
    source = f"measured Realtime, n={len(fn)}" if fn else "cited pre-reset measurement"

    print("# Flow benchmark\n")
    print(f"Release-to-transcript: p50 {fmt(pct(transcript, .5))} s, p90 {fmt(pct(transcript, .9))} s ({source}).\n")
    for label in labels:
        print(f"## {label}\n")
        print("| Flow | Mouse, adult (KLM) | Mouse, 65+ (KLM) | Transcript→action, code only p50 / p90 | Transcript→action, with driver p50 / p90 | Release→action (Fn) p50 / p90 | Reads after release |")
        print("|---|---|---|---|---|---|---|")
        for flow in FLOWS:
            def series(profile):
                return [r["transcript_to_action_ms"] for r in flows
                        if r["label"] == label and r["flow"] == flow and r["profile"] == profile
                        and "transcript_to_action_ms" in r]
            zero, modeled = series("zero"), series("modeled")
            total = summed(transcript, modeled)
            reads = [tuple(r.get("reads_before_action", [])) for r in flows
                     if r["label"] == label and r["flow"] == flow and r["profile"] == "modeled"]
            typical = max(set(reads), key=reads.count) if reads else ()
            print(f"| {flow} | {klm[flow]['adult_s']:.2f} | {klm[flow]['older_s']:.2f} | "
                  f"{fmt(pct(zero, .5))} / {fmt(pct(zero, .9))} | {fmt(pct(modeled, .5))} / {fmt(pct(modeled, .9))} | "
                  f"{fmt(pct(total, .5))} / {fmt(pct(total, .9))} | {', '.join(typical) or 'none'} |")
        print()
    hands = [r for r in realtime if r.get("mode") == "handsfree"]
    if hands:
        print("## Hands-free turn end (Realtime, semantic VAD)\n")
        for key in ["speech_end_to_stopped_ms", "speech_end_to_commit_ms", "speech_end_to_transcript_ms"]:
            for label in dict.fromkeys(r["label"] for r in hands):
                values = [r[key] for r in hands if r["label"] == label and key in r]
                print(f"- {label} {key}: p50 {fmt(pct(values, .5))} s, p90 {fmt(pct(values, .9))} s, n={len(values)}")
        print()
    if realtime:
        spent = sum(r.get("usd", 0) for r in realtime)
        print(f"Realtime turns in these files: {len(realtime)}, reported spend USD {spent:.4f}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
