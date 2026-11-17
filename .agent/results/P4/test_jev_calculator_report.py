import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("calculator_report", HERE / "jev-calculator-comparison-report.py")
REPORT = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(REPORT)
EVIDENCE = None


class CalculatorReportTests(unittest.TestCase):
    def test_real_comparison_has_no_successful_baseline_timing(self):
        data = REPORT.audit(EVIDENCE)
        self.assertEqual(data["order"], ["before-0", "after-0", "after-1", "before-1", "before-2", "after-2"])
        self.assertEqual(data["baseline"]["strict_successes"], 0)
        self.assertIsNone(data["baseline"]["successful_median_ms"])
        self.assertEqual(data["candidate"]["strict_successes"], 3)
        self.assertAlmostEqual(data["candidate"]["successful_median_ms"], 7476.82475)
        self.assertEqual(data["false_done"], 0)
        self.assertFalse(data["p4_latency_met"])
        page = REPORT.render(data, EVIDENCE)
        self.assertIn("7.477 s", page)
        self.assertIn("No successful baseline", page)
        self.assertIn("P4 remains open", page)

    def damaged_copy(self, edit):
        with tempfile.TemporaryDirectory(prefix="calculator-report-check-", dir=EVIDENCE.parent) as directory:
            root = Path(directory) / "comparison"
            shutil.copytree(EVIDENCE, root)
            edit(root)
            with self.assertRaises(ValueError):
                REPORT.audit(root)

    def test_missing_seed_is_not_admitted(self):
        self.damaged_copy(lambda root: (root / "after-0/calculator-seed.json").unlink())

    def test_disagreeing_summary_row_is_not_admitted(self):
        def edit(root):
            path = root / "summary.json"
            data = json.loads(path.read_text())
            data["variants"]["after-0"]["rows"][0]["wall_ms"] = 1
            path.write_text(json.dumps(data))
        self.damaged_copy(edit)

    def test_modified_measuring_instrument_is_not_admitted(self):
        def edit(root):
            path = root / "harness-source/jev-everyday-apps.py"
            path.write_text(path.read_text() + "\nchanged\n")
        self.damaged_copy(edit)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--comparison", type=Path, required=True)
    EVIDENCE = parser.parse_args().comparison
    unittest.main(argv=["calculator-report-tests"])
