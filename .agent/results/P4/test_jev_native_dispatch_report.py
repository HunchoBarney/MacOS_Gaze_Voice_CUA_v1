import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("dispatch_report_audit", HERE / "jev-calculator-comparison-report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
SCOPE = ["Sources/JevVoice/Drive/DriveLoop.swift", "Sources/JevVoice/Driver/CuaConnection.swift"]
EVIDENCE = None


class DispatchReportTests(unittest.TestCase):
    def audit(self, root):
        return REPORT.audit(root, expected_delta=SCOPE, prior_names=())

    def test_real_comparison_keeps_failed_candidate_and_has_no_qualifying_median(self):
        data = self.audit(EVIDENCE)
        self.assertEqual(data["baseline"]["strict_successes"], 3)
        self.assertEqual(data["candidate"]["strict_successes"], 2)
        self.assertIsNone(data["candidate"]["successful_median_ms"])
        self.assertAlmostEqual(data["baseline"]["successful_median_ms"], 7472.912625)
        self.assertEqual(data["false_done"], 0)
        self.assertFalse(data["p4_latency_met"])
        self.assertFalse(data["phase_qualified"])

    def test_native_report_prints_regression_and_both_slow_successes(self):
        spec = importlib.util.spec_from_file_location("native_dispatch_report", HERE / "jev-native-dispatch-report.py")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        data = module.audit(EVIDENCE)
        page = module.render(data, EVIDENCE)
        self.assertIn("Candidate: 2/3", page)
        self.assertIn("Baseline: 3/3", page)
        self.assertIn("4.023 s", page)
        self.assertIn("4.028 s", page)
        self.assertIn("No qualifying candidate median", page)
        self.assertIn("P4 remains open", page)
        self.assertEqual(data["setup_failure_goals"], 0)
        self.assertEqual(len(data["pilot"]), 2)
        self.assertEqual(data["successful_pairs"], 2)

    def damaged_copy(self, edit):
        with tempfile.TemporaryDirectory(prefix="dispatch-report-check-", dir=EVIDENCE.parent) as directory:
            root = Path(directory) / "comparison"
            shutil.copytree(EVIDENCE, root)
            edit(root)
            with self.assertRaises(ValueError):
                self.audit(root)

    def test_reviewed_source_receipt_cannot_be_substituted(self):
        def edit(root):
            path = root / "summary.json"
            summary = json.loads(path.read_text())
            argv = summary["execution"]["argv"]
            receipt = root / "substitute-review.json"
            receipt.write_text("{}")
            argv[argv.index("--reviewed-source-delta") + 1] = str(receipt)
            path.write_text(json.dumps(summary))
        self.damaged_copy(edit)

    def test_false_verified_outcome_is_rejected_even_when_summary_agrees(self):
        def edit(root):
            raw = root / "after-2/results.json"
            record = json.loads(raw.read_text())
            row = record["rows"][0]
            row.update(status="done", verified=True, strict_success=True, false_done=False)
            raw.write_text(json.dumps(record))
            path = root / "summary.json"
            summary = json.loads(path.read_text())
            summary["variants"]["after-2"]["rows"] = record["rows"]
            path.write_text(json.dumps(summary))
        self.damaged_copy(edit)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--comparison", type=Path, required=True)
    EVIDENCE = parser.parse_args().comparison
    unittest.main(argv=["native-dispatch-report-tests"])
