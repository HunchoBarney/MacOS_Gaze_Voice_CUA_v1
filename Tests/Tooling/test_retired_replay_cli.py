import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import sys
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("verify_p3", ROOT / "scripts/verify-p3.py")
verifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(verifier)


class RetiredReplayTests(unittest.TestCase):
    def test_replay_refuses_before_input_output_or_binary_access(self):
        for options in ([], ["--recordings-root", "/unused-input", "--out", "/unused-output"]):
            with self.subTest(options=options), patch.object(sys, "argv", ["verify-p3.py", "replay", *options]), \
                    patch.object(Path, "resolve", side_effect=AssertionError("resolved input")), \
                    patch.object(Path, "is_file", side_effect=AssertionError("probed input")), \
                    patch.object(Path, "open", side_effect=AssertionError("opened file")), \
                    patch.object(verifier.subprocess, "run", side_effect=AssertionError("launched binary")), \
                    redirect_stdout(io.StringIO()) as message:
                self.assertEqual(verifier.main(), 2)
                self.assertIn("073fedeb1101d50466ff46b7c007d085e08d9e15", message.getvalue())


if __name__ == "__main__":
    unittest.main()
