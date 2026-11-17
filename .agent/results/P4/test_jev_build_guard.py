import importlib.util
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


class BuildSpaceTests(unittest.TestCase):
    guard = Path(__file__).with_name("jev-build-guard.py")

    def invoke(self, directory, minimum, stop, code):
        return subprocess.run(
            [sys.executable, str(self.guard), "--directory", directory,
             "--minimum-free-gib", str(minimum), "--stop-free-gib", str(stop),
             "--", sys.executable, "-c", code],
            capture_output=True, text=True, timeout=10,
        )

    def test_low_space_refuses_before_starting_child(self):
        with tempfile.TemporaryDirectory(dir=self.guard.parent) as directory:
            marker = Path(directory) / "started"
            result = self.invoke(directory, 999999, 1,
                f"from pathlib import Path; Path({str(marker)!r}).touch()")
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertIn("Insufficient build space", result.stderr)
            self.assertFalse(marker.exists())

    def test_child_failure_is_not_reported_green(self):
        with tempfile.TemporaryDirectory(dir=self.guard.parent) as directory:
            result = self.invoke(directory, 0, 0, "raise SystemExit(23)")
            self.assertEqual(result.returncode, 23, result.stderr)

    def test_running_child_is_stopped_if_space_drops(self):
        spec = importlib.util.spec_from_file_location("jev_build_guard", self.guard)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        processes = []
        popen = subprocess.Popen

        def spawn(*args, **kwargs):
            child = popen(*args, **kwargs)
            processes.append(child)
            return child

        with tempfile.TemporaryDirectory(dir=self.guard.parent) as directory:
            usage = shutil.disk_usage(directory)
            low = type(usage)(usage.total, usage.total, 0)
            with patch.object(module.shutil, "disk_usage", side_effect=[usage, low]), \
                 patch.object(module.subprocess, "Popen", side_effect=spawn):
                result = module.run(
                    [sys.executable, "-c", "import signal; signal.pause()"],
                    Path(directory), minimum=0, stop=1)
            self.assertEqual(result, 75)
            self.assertEqual(len(processes), 1)
            self.assertIsNotNone(processes[0].poll())


if __name__ == "__main__":
    unittest.main()
