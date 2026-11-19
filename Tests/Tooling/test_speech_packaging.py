import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
BUNDLER = ROOT / "scripts/bundle-conversation-vad.py"


class SpeechPackagingTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.app = self.root / "stage with spaces.app"
        self.vad = self.app / "Contents/Resources/ConversationVAD"
        self.source = self.root / "build/vendor/ConversationVAD"
        self.source.mkdir(parents=True)
        shutil.copy(ROOT / "Makefile", self.root)
        shutil.copy(ROOT / "Info.plist", self.root)
        scripts = self.root / "scripts"
        scripts.mkdir()
        shutil.copy(BUNDLER, scripts)
        signer, seal, _ = (ROOT / "scripts/sign-app.sh").read_text().partition("xattr -dr")
        self.assertTrue(seal)
        self.write("scripts/sign-app.sh", signer + 'echo "fixture reached seal boundary"\nexit "${FIXTURE_STOP:-0}"\n', True)
        self.write("scripts/bundle-tracker.sh", "#!/bin/sh\nexit 0\n", True)
        self.write("scripts/check-tracker.sh", "#!/bin/sh\nexit 0\n", True)
        self.write("scripts/check-packaged-tracker.py", "print('fixture strict tracker check')\n")
        for name in ("Sources/JevVoice/Voice/ConversationCapture.swift", "main",
                     "build/vendor/cua-driver", "build/vendor/CodexRuntime/codex",
                     "ThirdParty/FluidVoice/LICENSE", "ThirdParty/FluidVoice/NOTICE.md",
                     "ThirdParty/Cua/LICENSE.md", "ThirdParty/Cua/THIRD_PARTY_NOTICES.md"):
            self.write(name, "fixture")
        self.write("sitecustomize.py", "import sys\n"
                   "def offline(event, args):\n"
                   "    if event in ('urllib.Request', 'socket.connect'):\n"
                   "        raise RuntimeError('network forbidden in fixture')\n"
                   "sys.addaudithook(offline)\n")
        self.env = dict(PATH=os.defpath, HOME=str(self.root), JEV_CONVERSATION_VAD_SOURCE=str(self.source),
                        PYTHONPATH=str(self.root), PYTHONDONTWRITEBYTECODE="1")

    def write(self, name, text, executable=False):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        if executable:
            path.chmod(0o700)

    def invoke(self, *command):
        return subprocess.run(command, cwd=self.root, env=self.env,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)

    def make(self, *args):
        return self.invoke("make", "-o", "build", "-o", "vendor", f"APP={self.app}",
                           f"STAGE_APP={self.app}", "BINARY=main", *args)

    def test_default_stage_and_sign_never_provision_vad(self):
        self.env["STAGE_APP"] = str(self.root / "unrelated.app")
        result = self.make("app")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("fixture reached seal boundary", result.stdout)
        self.assertFalse(self.vad.exists())
        self.assertTrue((self.app / "Contents/MacOS/JevVoice").is_file())
        self.assertTrue((self.app / "Contents/Resources/ThirdParty/FluidVoice/LICENSE").is_file())
        self.assertFalse((self.root / "unrelated.app").exists())

    def test_dist_graph_reaches_seal_without_resource(self):
        self.env["FIXTURE_STOP"] = "71"
        result = self.make("-o", "tracker-deps", "dist")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("fixture reached seal boundary", result.stdout)
        if "dist: bundle-tracker" in (self.root / "Makefile").read_text():
            self.assertIn("fixture strict tracker check", result.stdout)
        self.assertFalse(self.vad.exists())

    def test_diagnostic_make_and_historical_sign_require_pinned_resource(self):
        result = self.make("app", "JEV_SPEECH_PACKAGE=diagnostic")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing conversation resource", result.stdout)
        self.assertFalse(self.app.exists())
        (self.app / "Contents/Resources").mkdir(parents=True)
        result = self.invoke("scripts/sign-app.sh", str(self.app))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing conversation resource", result.stdout)
        self.assertNotIn("fixture reached seal boundary", result.stdout)

    def test_stale_payload_and_symlinked_targets_refused_before_copy(self):
        self.vad.mkdir(parents=True)
        (self.vad / "receipt").write_text("keep")
        for profile, error in (("realtime", "already exists"), ("diagnostic", "missing conversation resource"),
                               ("typo", "invalid choice")):
            result = self.make("stage", "JEV_SPEECH_PACKAGE=" + profile)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stdout)
            self.assertFalse((self.app / "Contents/MacOS").exists())
            self.assertEqual((self.vad / "receipt").read_text(), "keep")
        self.vad.rename(self.root / "retained")
        self.vad.symlink_to(self.root / "missing")
        result = self.make("stage")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a plain staging directory", result.stdout)
        self.assertTrue(self.vad.is_symlink())
        self.app.rename(self.root / "retained.app")
        self.app.symlink_to(self.root / "retained.app")
        result = self.make("stage", "JEV_SPEECH_PACKAGE=diagnostic")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a plain staging directory", result.stdout)
        self.assertFalse((self.app / "Contents/MacOS").exists())

    def test_valid_diagnostic_resource_round_trip_and_signer_recheck(self):
        spec = importlib.util.spec_from_file_location("vad", BUNDLER)
        vad = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(vad)
        original = json.loads(vad.conversation_pin())
        for name in original["files"]:
            file = self.source / name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_bytes(name.encode())
            original["files"][name] = hashlib.sha256(file.read_bytes()).hexdigest()
        receipt = (json.dumps(original, sort_keys=True, indent=2) + "\n").encode()
        (self.source / "resource.json").write_bytes(receipt)
        with patch.object(vad, "RUNTIME", original), patch.object(
                vad, "VAD_RECEIPT_SHA256", hashlib.sha256(receipt).hexdigest()), patch.object(
                sys, "argv", ["bundle", "--app", str(self.app), "--profile", "diagnostic",
                              "--source", str(self.source)]), contextlib.redirect_stdout(io.StringIO()):
            vad.main()
            vad.main()
            self.assertEqual({str(p.relative_to(self.vad)) for p in self.vad.rglob("*") if p.is_file()},
                             set(original["files"]) | {"resource.json"})
            (self.vad / "LICENSE").write_text("changed")
            with self.assertRaisesRegex(ValueError, "resource changed"):
                vad.main()
        for profile, error in (("realtime", "already exists"), ("diagnostic", "manifest changed")):
            self.env["JEV_SPEECH_PACKAGE"] = profile
            result = self.invoke("scripts/sign-app.sh", str(self.app))
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(error, result.stdout)
            self.assertNotIn("fixture reached seal boundary", result.stdout)


if __name__ == "__main__":
    unittest.main()
