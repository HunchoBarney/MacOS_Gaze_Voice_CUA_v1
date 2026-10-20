"""Pure-metadata guards: no synthetic audio or mock models."""
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("speech_report", Path(__file__).resolve().parents[1] / "report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
VERIFY_SPEC = importlib.util.spec_from_file_location("speech_verify", Path(__file__).resolve().parents[1] / "verify.py")
VERIFY = importlib.util.module_from_spec(VERIFY_SPEC)
VERIFY_SPEC.loader.exec_module(VERIFY)


class ReportTests(unittest.TestCase):
    def recorded_run(self):
        path = Path(__file__).resolve().parents[1] / "results/results.json"
        return json.loads(path.read_text())

    def test_missing_process_record_is_rejected(self):
        data = self.recorded_run()
        data["processes"].pop()
        with self.assertRaises(AssertionError):
            VERIFY.verify_attribution(data)

    def test_changed_probe_event_is_rejected(self):
        data = self.recorded_run()
        data["partials_probe"][0]["events"][0]["text"] = "tampered event metadata"
        with self.assertRaises(AssertionError):
            VERIFY.verify_attribution(data)

    def test_duplicate_probe_cannot_replace_a_missing_timeline(self):
        data = self.recorded_run()
        data["partials_probe"][1] = data["partials_probe"][0]
        with self.assertRaises(AssertionError):
            VERIFY.verify_attribution(data)

    def test_process_pid_must_match_engine_probe(self):
        data = self.recorded_run()
        process = data["processes"][0]
        data["probe"][process["engine"] + ":pid"] = str(process["pid"] + 1)
        with self.assertRaises(AssertionError):
            VERIFY.verify_attribution(data)

    def test_speed_winner_is_not_a_production_selection(self):
        path = Path(__file__).resolve().parents[1] / "results/results.json"
        report = REPORT.generate(json.loads(path.read_text()))
        self.assertIn("## Product Decision\n\n**HOLD", report)
        self.assertIn("Historical pre-run outcome", report)

    def test_even_median_is_not_the_upper_middle_item(self):
        self.assertEqual(REPORT.percentile([1, 3]), 2)
        self.assertEqual(REPORT.percentile([3, 1, 2]), 2)
        self.assertIsNone(REPORT.percentile([]))

    def test_corpus_wer_does_not_hide_long_command_errors(self):
        data = {"meta": {"engines": ["guard"]}, "rows": [
            {"engine": "guard", "iter": 0, "reference_words": 2, "word_edits": 0},
            {"engine": "guard", "iter": 0, "reference_words": 10, "word_edits": 3},
        ]}
        self.assertEqual(REPORT.scores(data)["guard"]["wer"], 0.25)

    def test_incomplete_matrix_cannot_produce_pick(self):
        data = {
            "meta": {"engines": ["parakeet", "speechanalyzer"], "iterations": 3},
            "rows": [], "corpus": [{"id": f"p{i:02}"} for i in range(1, 16)],
            "processes": [], "probe": {},
        }
        label, reason = REPORT.verdict(data, {})
        self.assertEqual(label, "INCONCLUSIVE")
        self.assertIn("missing=", reason)

    def test_warmup_cannot_enter_the_scored_rows(self):
        data = {"meta": {"engines": ["guard"]}, "rows": [
            {"engine": "guard", "iter": -1, "reference_words": 1, "word_edits": 1},
            {"engine": "guard", "iter": 0, "reference_words": 1, "word_edits": 0},
        ]}
        self.assertEqual(REPORT.scores(data)["guard"]["wer"], 0)


if __name__ == "__main__":
    unittest.main()
