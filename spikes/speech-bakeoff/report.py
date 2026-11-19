#!/usr/bin/env python3
"""Recompute metrics and a directional verdict from raw release rows."""
import argparse
from collections import Counter
import math
from pathlib import Path
import statistics

import json


def percentile(values, quantile=0.5):
    if not values:
        return None
    return statistics.median(values) if quantile == 0.5 else sorted(values)[math.ceil(len(values) * quantile) - 1]


def metric(rows, key, quantile=0.5):
    return percentile([r[key] for r in rows if r.get(key) is not None], quantile)


def fmt(value):
    return "unavailable" if value is None else f"{value:.1f}"


def scores(data):
    output = {}
    for engine in data["meta"]["engines"]:
        rows = [r for r in data["rows"] if r["engine"] == engine and r["iter"] >= 0]
        commands = [r for r in rows if r.get("reference_words")]
        words = sum(r["reference_words"] for r in commands)
        output[engine] = {
            "rows": rows, "commands": commands,
            "wer": sum(r["word_edits"] for r in commands) / words if words else None,
            "first": metric(commands, "first_partial_ms"),
            "onset": metric(commands, "first_partial_after_onset_ms"),
            "final": metric(commands, "final_ms_after_audio_end"),
            "p95_final": metric(commands, "final_ms_after_audio_end", 0.95),
        }
    return output


def coverage(data):
    engines = data["meta"]["engines"]
    iterations = data["meta"]["iterations"]
    clips = [r["id"] for r in data["corpus"]] + ["lib01", "lib02", "lib03"]
    expected = {(e, c, i) for e in engines for c in clips for i in range(iterations)}
    counts = Counter((r["engine"], r["clip"], r["iter"]) for r in data["rows"] if r["iter"] >= 0)
    missing = expected - counts.keys()
    duplicate = {key: count for key, count in counts.items() if count != 1}
    failed = [r for r in data["rows"] if r["iter"] >= 0 and r["status"] != "ok"]
    problems = []
    if len(engines) < 2 or len(data["corpus"]) < 10 or iterations < 3 or data["meta"].get("clip_filter"):
        problems.append("insufficient engines/clips/iterations or clip-filtered smoke run")
    if not {"parakeet", "speechanalyzer"}.issubset(engines):
        problems.append("incumbent and standard Apple baseline are both required")
    if missing or duplicate or failed:
        problems.append(f"missing={len(missing)}, duplicate={len(duplicate)}, non-ok={len(failed)}")
    if any(p["exit_code"] != 0 or not p["reaped"] for p in data["processes"]):
        problems.append("failed/unreaped engine process")
    if any(data["probe"].get(f"{engine}:build") != "release" for engine in engines):
        problems.append("not all variants used a release build")
    return problems


def verdict(data, summary):
    problems = coverage(data)
    if problems:
        return "INCONCLUSIVE", "; ".join(problems)
    if any(s["wer"] is None or s["final"] is None or s["first"] is None for s in summary.values()):
        return "INCONCLUSIVE", "a required WER/final/partial metric is unavailable"
    names = sorted(summary)
    winner = names[0]
    for name in names[1:]:
        a, b = summary[winner], summary[name]
        if abs(a["final"] - b["final"]) > 50:
            if b["final"] < a["final"]:
                winner = name
        elif abs(a["wer"] - b["wer"]) > 0.02:
            if b["wer"] < a["wer"]:
                winner = name
        elif b["first"] < a["first"] - 50:
            winner = name
    partial_best = min(names, key=lambda name: summary[name]["first"])
    accuracy_best = min(names, key=lambda name: summary[name]["wer"])
    if (partial_best != accuracy_best
            and summary[partial_best]["wer"] - summary[accuracy_best]["wer"] > 0.02
            and summary[accuracy_best]["first"] - summary[partial_best]["first"] > 50):
        return f"HYBRID: {partial_best} partials / {accuracy_best} finals", (
            "Strict streaming-vs-accuracy split. Combined runtime/resource use remains unmeasured; "
            "do not claim the pair meets the product latency budget."
        )
    return f"PICK {winner}", (
        "Directional priority: final latency, corpus WER, then first partial; "
        "50 ms / 2 percentage points are engineering tolerances, not significance tests. "
        "Apple service/asset attribution gaps qualify the resource comparison."
    )


def generate(data):
    summary = scores(data)
    label, reason = verdict(data, summary)
    lines = [
        "# P2d Speech Bake-Off",
        "", f"Run `{data['meta']['run_id']}`; raw evidence `results/results.json`.",
        "", "## Product Decision", "",
        "**HOLD: no production ASR selected.**",
        "Post-run user directive: correctness gates speed. A known action-changing error such as GitHub -> GateHub blocks promotion; a 66 ms median speed advantage does not override it.",
        "No engine can guarantee perfect recognition. The product must validate intent and critical entities, and clarify genuine ambiguity rather than silently act on the wrong target.",
        "Before promotion, correct known critical regressions and test previously unseen/confusable names, dates, recipients and targets. Do not force the expected transcript, blindly rewrite similar names, or count asking on every turn as successful automation.",
        "", "## Performance-Only Verdict", "", f"Historical pre-run outcome: **{label}**", "", reason,
        "", "This is one speaker's 15 prompted commands, repeated measurements, not a general ASR accuracy study.",
        "No production engine has been replaced. G4 independent review and G7 commit remain separate gates.",
        "", "## Recorded Commands",
        "", "| engine | ok / measured | corpus WER | first partial p50 ms | after onset p50 ms | final p50 ms | final p95 ms |",
        "|---|---:|---:|---:|---:|---:|---:|",
    ]
    for engine, s in summary.items():
        rows = s["commands"]
        wer = "unavailable" if s["wer"] is None else f"{s['wer']:.2%}"
        lines.append(
            f"| {engine} | {sum(r['status']=='ok' for r in rows)} / {len(rows)} | {wer} | "
            f"{fmt(s['first'])} | {fmt(s['onset'])} | {fmt(s['final'])} | {fmt(s['p95_final'])} |")
    lines += ["", "First-partial target: 300 ms from capture start. Final target: 200 ms after scheduled input end.",
              "Final latency includes model backlog; it is not measured from when the engine finishes consuming audio.",
              "Each engine sees the identical energy-delimited PCM view. Source WAVs remain unchanged.",
              "The 200 ms trailing padding is included; this is not a physical Fn-release measurement.",
              "Energy onset is a proxy, not a manually annotated speech boundary; breaths/clicks can affect it.",
              "", "## Paired Per-Command Medians", "",
              "| command | engine | final ms | first partial ms | WER | partial count |", "|---|---|---:|---:|---:|---:|"]
    for clip in data["corpus"]:
        for engine, s in summary.items():
            rows = [r for r in s["commands"] if r["clip"] == clip["id"]]
            words = sum(r.get("reference_words", 0) for r in rows)
            wer = sum(r.get("word_edits", 0) for r in rows) / words if words else None
            lines.append(
                f"| {clip['id']} | {engine} | {fmt(metric(rows,'final_ms_after_audio_end'))} | "
                f"{fmt(metric(rows,'first_partial_ms'))} | {fmt(None if wer is None else wer*100)}% | {fmt(metric(rows,'partial_count'))} |")
    lines += ["", "## Accuracy Audit", "",
              "Every command with word edits in iteration 0 is shown; repetitions remain in raw JSON.",
              "Numeral/hyphen formatting is not the same as a wrong entity. In particular, Apple's GitHub -> GateHub error is meaningful and must not be hidden behind the aggregate WER.",
              "", "| engine | clip | reference | observed final | edits |", "|---|---|---|---|---:|"]
    for engine, s in summary.items():
        for row in s["commands"]:
            if row["iter"] == 0 and row["word_edits"]:
                lines.append(f"| {engine} | {row['clip']} | {row['reference']} | {row['transcript_final']} | {row['word_edits']} |")
    lines += ["", "A directional speed pick is not a ship-quality accuracy claim. P3 must guard entity/intent correctness; the SDK exposes AnalysisContext.contextualStrings[.general] for a prospective vocabulary experiment, but no context-biased run was measured here."]
    lines += ["", "## Resources And Startup", "",
              "| engine | fresh-process load ms | warm reuse ms | first inference ms | client load peak MB | client inference peak MB | model bytes |",
              "|---|---:|---:|---:|---:|---:|---:|"]
    for engine, r in data["resources"].items():
        values = [r.get(k) for k in ("load_cold_ms", "warm_reuse_ms", "first_inference_ms", "rss_load_peak_mb", "rss_transcribe_peak_mb", "disk_bytes")]
        lines.append(f"| {engine} | " + " | ".join(fmt(v) for v in values) + " |")
    for engine, r in data["resources"].items():
        baseline = r["rss_baseline_mb"]
        load_delta = r.get("rss_load_peak_mb", baseline) - baseline
        inference_delta = r.get("rss_transcribe_peak_mb", baseline) - baseline
        lines.append(f"- {engine}: pre-load baseline {fmt(baseline)} MB; load/inference sampled peak deltas from that baseline {fmt(load_delta)}/{fmt(inference_delta)} MB (not an inference-only allocation delta).")
    lines += ["", "Caches were not cleared. 'Warm reuse' is reusing an already-loaded driver, not a new model load.",
              "Client RSS is sampled at 50 ms and excludes Apple XPC/ANE allocations; do not compare it as total engine RAM.",
              "Apple shared service observations (not causally attributable to this process):"]
    for observed in data["service_observations"]:
        totals = [sum(p["rss_mb"] for p in sample["services"]) for sample in observed["samples"]]
        lines.append(f"- {observed['engine']}: shared localspeechrecognition RSS baseline {fmt(totals[0] if totals else None)} MB, observed peak {fmt(max(totals) if totals else None)} MB.")
    assets = data["meta"]["apple_assets"]
    lines += [f"- Apple shared ASR asset directory bytes: {assets['shared_asset_directory_bytes']}; exclusive en_US bytes: unavailable.",
              "- RAM 2x / disk 1.5x veto cannot be certified for Apple with the attribution gaps; packaging/resource gate stays open.",
              "", "## Streaming Diagnosis", ""]
    for engine, s in summary.items():
        rows = s["commands"]
        mid = sum(any(e["type"] == "partial" and e["t_ms"] < r.get("input_duration_ms", 0) for e in r.get("events", [])) for r in rows)
        lines.append(f"- [verified] {engine}: {mid}/{len(rows)} rows emit a partial before scheduled audio end; feed lag p50 {fmt(metric(rows,'feed_lag_ms'))} ms; per-turn prepare p50 {fmt(metric(rows,'prepare_ms'))} ms.")
        first_hits = sum(r.get("first_partial_ms", float("inf")) <= 300 for r in rows)
        final_hits = sum(r.get("final_ms_after_audio_end", float("inf")) <= 200 for r in rows)
        gaps = []
        for row in rows:
            partials = [e["t_ms"] for e in row.get("events", []) if e["type"] == "partial" and e["text"]]
            gaps.extend(b - a for a, b in zip(partials, partials[1:]))
        lines.append(f"- {engine} target hits: first partial <=300 ms {first_hits}/{len(rows)}, final <=200 ms {final_hits}/{len(rows)}; partial-update gap p50/p95 {fmt(percentile(gaps))}/{fmt(percentile(gaps,0.95))} ms. Missing partials are misses, not zero latency.")
    lines += ["- [verified] This is chunked-file replay, not the app's Fn/microphone front door. Mid-stream output does not establish production routing is correct or that first partials meet 300 ms.",
              "- [code-inspected] Concrete display-wiring gap: `Sources/Jarvis/main.swift:599-613` connects local partials only to LocalCommandRouter when spotting is enabled, and clears callbacks in STT-only mode. `LocalCommandRouter.swift:146-157` uses partials for command speculation, not transcript display.",
              "- [code-inspected] The visible partial event instead comes from remote transcript deltas (`RealtimeVoiceLane.swift:716-720`), which `VoiceController.swift:988-993` copies into the overlay. P3 must wire turn-tagged LOCAL partials to that display path without dispatching actions twice.",
              "- [unverified] Fn-up/start races, local model-readiness drops and backlog remain additional integration hypotheses. The shipped app's physical Fn/mic path still needs a live check after the P3 wiring fix.",
              "", "## Coverage, Authorization And Limits", "",
              f"- Coverage problems: {coverage(data) or 'none'}.",
              f"- Scored rows: {sum(r['iter']>=0 for r in data['rows'])}; first-inference warm-ups excluded: {sum(r['iter']<0 for r in data['rows'])}.",
              "- Libraries have tail-phrase checks, not full ground-truth WER."]
    for engine, s in summary.items():
        library = [r for r in s["rows"] if r["clip"].startswith("lib")]
        lines.append(f"- {engine} library tail matches: {sum(r.get('tail_contains') is True for r in library)}/{len(library)}.")
    lines += ["- [verified] Existing local models used; benchmark code has no model download or network-transcription fallback.",
              "- [unverified] XPC-service network activity and clean-Mac onboarding attribution were not independently tested.",
              "- SpeechAnalyzer requires macOS 26+, matching the current root Package.swift deployment floor.",
              "- WER is literal lowercase/punctuation-normalized word edits; numeral spellings and contractions can count as errors despite equivalent intent. No normalization was tuned to these results.",
              "- Microphone authorization was read, not requested; no recording is performed by this benchmark."]
    for engine in data["meta"]["engines"]:
        lines.append(f"- {engine} authorization: mic={data['probe'].get(engine+':microphone_authorization')}; speech={data['probe'].get(engine+':speech_authorization')}.")
    lines += ["", "## Recompute", "",
              "```bash", "python3 spikes/speech-bakeoff/report.py --check", "```", ""]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--results", type=Path, default=Path(__file__).parent / "results/results.json")
    parser.add_argument("--output", type=Path, default=Path(__file__).parent / "results/REPORT.md")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    data = json.loads(args.results.read_text())
    text = generate(data)
    if args.check:
        assert args.output.read_text() == text, "report differs from raw recomputation"
        assert not coverage(data), coverage(data)
        print("PASS report recomputation and full release coverage")
    else:
        args.output.write_text(text)
        print("WROTE", args.output)
    print("Product: HOLD (accuracy validation pending). Historical pre-run outcome:", verdict(data, scores(data)))


if __name__ == "__main__":
    main()
