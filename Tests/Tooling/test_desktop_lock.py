import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

WRAPPER = Path(__file__).resolve().parents[2] / 'scripts' / 'with-desktop-lock.py'


class DesktopLockTests(unittest.TestCase):
    def test_forwards_command_failure(self):
        with tempfile.TemporaryDirectory() as home:
            result = subprocess.run(
                [sys.executable, str(WRAPPER), sys.executable, '-c', 'raise SystemExit(17)'],
                env=dict(os.environ, JARVIS_DESKTOP_LOCK_DIRECTORY=home), capture_output=True)
            self.assertEqual(result.returncode, 17)

    def test_commands_from_different_directories_do_not_overlap(self):
        with tempfile.TemporaryDirectory() as home:
            root = Path(home)
            log = root / 'events'
            command = (
                'import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); '
                'f=p.open("a"); f.write(sys.argv[2]+" start\\n"); f.flush(); '
                'time.sleep(0.15); f.write(sys.argv[2]+" end\\n"); f.close()'
            )
            processes = []
            try:
                for label in ['a', 'b']:
                    cwd = root / label
                    cwd.mkdir()
                    processes.append(subprocess.Popen(
                        [sys.executable, str(WRAPPER), sys.executable, '-c', command, str(log), label],
                        cwd=cwd, env=dict(os.environ, JARVIS_DESKTOP_LOCK_DIRECTORY=home), stdout=subprocess.DEVNULL))
                for process in processes:
                    self.assertEqual(process.wait(timeout=10), 0)
                events = log.read_text().splitlines()
                self.assertIn(events, [
                    ['a start', 'a end', 'b start', 'b end'],
                    ['b start', 'b end', 'a start', 'a end'],
                ])
            finally:
                for process in processes:
                    if process.poll() is None:
                        process.kill()
                    process.wait()
