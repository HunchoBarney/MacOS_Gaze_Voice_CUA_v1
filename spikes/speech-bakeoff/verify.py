#!/usr/bin/env python3
"""Independent acceptance predicates for raw P2d evidence (no report imports)."""
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
import statistics
import subprocess
import wave

PACKAGE = Path(__file__).resolve().parent
ROOT = PACKAGE.parents[1]


def words(text):
    return re.findall(r"[^\W_]+", text.lower(), flags=re.UNICODE)


def edits(reference, hypothesis):
    previous = list(range(len(hypothesis) + 1))
    for i, token in enumerate(reference, 1):
        current = [i]
        for j, other in enumerate(hypothesis, 1):
            current.append(min(previous[j] + 1, current[-1] + 1, previous[j - 1] + (token != other)))
        previous = current
    return previous[-1]


def verify_attribution(data):
    recorded = [row for row in data["rows"] if row["iter"] >= 0]
    engines = data["meta"]["engines"]
    processes = data["processes"]
    assert len(set(engines)) == len(engines)
    assert Counter(p["engine"] for p in processes) == Counter(engines), "one process record per engine required"
    assert len({p["pid"] for p in processes}) == len(processes), "duplicate process PID"
    for process in processes:
        assert process["reaped"] and process["exit_code"] == 0 and not process["timeout"]
        assert process["pid"] > 0 and str(process["pid"]) == data["probe"][process["engine"] + ":pid"]

    def key(row):
        return row["engine"], row["clip"], row["iter"]

    scored = {key(row): row for row in recorded}
    assert len(scored) == len(recorded), "duplicate scored row"
    probes = data["partials_probe"]
    assert Counter(key(probe) for probe in probes) == Counter(scored.keys()), "missing or duplicate probe timeline"
    for probe in probes:
        row = scored[key(probe)]
        assert probe["kind"] == "partials_probe"
        assert probe["input_duration_ms"] == row["input_duration_ms"]
        assert probe["events"] == row["events"], "probe timeline differs from scored event trace"


def main():
    data = json.loads((PACKAGE / "results/results.json").read_text())
    assert hashlib.sha256((PACKAGE / ".build/release/bakeoff").read_bytes()).hexdigest() == data["meta"]["binary_sha256"]
    for path, expected_hash in data["meta"]["source_sha256"].items():
        assert hashlib.sha256((PACKAGE / path).read_bytes()).hexdigest() == expected_hash, f"source changed after measurement: {path}"
    assert data["meta"]["iterations"] >= 3 and not data["meta"]["clip_filter"]
    engines = data["meta"]["engines"]
    assert {"parakeet", "speechanalyzer"}.issubset(engines)
    corpus = data["corpus"]
    assert len(corpus) == 15 and all(r["status"] == "ok" and r["confirmed"] for r in corpus)
    for row in corpus:
        path = PACKAGE / "corpus" / row["wav"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == row["sha256"]
        with wave.open(str(path)) as audio:
            assert audio.getframerate() == 16000 and audio.getnchannels() == 1
            assert abs(audio.getnframes() / 16000 - row["duration_s"]) < 0.01
        assert subprocess.run(["git", "check-ignore", "-q", str(path)], cwd=ROOT).returncode == 0
    recorded = [r for r in data["rows"] if r["iter"] >= 0]
    expected = Counter({
        (engine, clip, i): 1 for engine in engines
        for clip in [r["id"] for r in corpus] + ["lib01", "lib02", "lib03"]
        for i in range(data["meta"]["iterations"])
    })
    assert Counter((r["engine"], r["clip"], r["iter"]) for r in recorded) == expected
    views = {}
    for row in recorded:
        assert row["status"] == "ok" and row["transcript_final"].strip(), row
        assert data["probe"][row["engine"] + ":build"] == "release"
        view = (row["source_sha256"], row["trim_start_ms"], row["trim_end_ms"], row["input_duration_ms"])
        assert views.setdefault(row["clip"], view) == view, "non-identical input"
        assert abs(row["final_ms_after_audio_end"] - max(0, row["wall_ms"] - row["input_duration_ms"])) < 0.01
        assert row["rss_load_mb"] > 0 and row["rss_transcribe_mb"] > 0
        partials = [event for event in row["events"] if event["type"] == "partial" and event["text"]]
        assert row["partial_count"] == len(partials)
        assert row.get("first_partial_ms") == (partials[0]["t_ms"] if partials else None)
        assert row["events"][-1]["type"] == "final"
        assert row["events"][-1]["text"] == row["transcript_final"]
        if row.get("reference"):
            ref, hyp = words(row["reference"]), words(row["transcript_final"])
            assert row["reference_words"] == len(ref)
            assert row["word_edits"] == edits(ref, hyp)
            assert abs(row["wer_final"] - edits(ref, hyp) / len(ref)) < 1e-9
    verify_attribution(data)
    for engine in engines:
        rows = [r for r in recorded if r["engine"] == engine and r.get("reference")]
        wer = sum(r["word_edits"] for r in rows) / sum(r["reference_words"] for r in rows)
        print(engine, "command rows", len(rows), "WER", round(wer * 100, 3),
              "final p50 ms", round(statistics.median(r["final_ms_after_audio_end"] for r in rows), 2))
    print(f"PASS: {len(recorded)} paired release rows, independent WER/timing/trace recomputation, all 15 audio hashes unchanged")


if __name__ == "__main__":
    main()
