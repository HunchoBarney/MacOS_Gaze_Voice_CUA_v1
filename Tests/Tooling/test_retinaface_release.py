import os
import hashlib
import json
from pathlib import Path
import subprocess
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[2] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import retinaface_release as profile


class ReleaseTrackerTests(unittest.TestCase):
    def test_missing_manifest_cannot_use_developer_tracker_or_host_node(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            app = tmp / "extracted" / "Jev Voice.app"
            tracker = app / "Contents/Resources/EyeTracker"
            for name in ("bin/node", "node_modules/.bin/electron",
                         "node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
                         "TRACKER_BUNDLE.json", "scripts/start-prod.cjs", "electron/main.cjs",
                         "electron/preload.cjs", "node_modules/electron/cli.js", "dist/index.html",
                         "dist/assets/index.js", "dist/.vite/manifest.json"):
                file = tracker / name
                file.parent.mkdir(parents=True, exist_ok=True)
                file.write_text("fixture")
                file.chmod(0o700)
            (tracker.parent / "EyeTracking").symlink_to("EyeTracker")
            (tracker / "dist/index.html").write_text('<script type="module" src="./assets/index.js"></script>')
            decoy = tmp / "developer"
            (decoy / "dist/.vite").mkdir(parents=True)
            (tracker / "dist/.vite/manifest.json").rename(decoy / "dist/.vite/manifest.json")
            node = decoy / "node"
            node.write_text('#!/bin/sh\ntouch "$HOME/used-host-node"\nexit 99\n')
            node.chmod(0o700)
            def refusal(reason):
                result = subprocess.run([sys.executable, str(SCRIPTS / "check-packaged-tracker.py"), str(app)],
                                        cwd=tmp, env={"PATH": str(decoy) + os.pathsep + "/usr/bin:/bin",
                                                      "HOME": str(tmp), "JARVIS_EYE_TRACKER_DIR": str(decoy)},
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 1)
                self.assertIn(reason, result.stderr)
                self.assertFalse((tmp / "used-host-node").exists())

            refusal("missing or unusable tracker payload: dist/.vite/manifest.json")
            (tracker / "dist/assets/stale.js").write_text("fixture")
            (tracker / "dist/.vite/manifest.json").write_text(json.dumps({
                "index.html": {"file": "assets/stale.js", "isEntry": True}}))
            refusal("renderer HTML does not match the generated manifest")

    def test_release_cannot_build_an_alternate_checkout(self):
        with tempfile.TemporaryDirectory() as tmp:
            result = subprocess.run(["bash", str(SCRIPTS / "bundle-tracker.sh"),
                                     "--release", str(Path(tmp) / "fixture.app")],
                                    env={"TRACKER_SRC": tmp, "PATH": "/usr/bin:/bin"},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("requires the repository tracker source", result.stderr)

    def test_model_inventory_controls_without_real_weights(self):
        hashes = {name: hashlib.sha256(name.encode()).hexdigest() for name in profile.PINS}
        excluded = b"fixture-only-excluded-weight"
        for damage in ["none", "missing", "corrupt", "extra", "nested", "linked-file", "linked-directory",
                       "linked-ancestor", "unlisted-onnx", "renamed-copy"]:
            with self.subTest(damage=damage), tempfile.TemporaryDirectory() as tmp:
                app = Path(tmp).resolve() / "test.app"
                tracker = app / "Contents/Resources/EyeTracker"
                models = tracker / "dist/models"
                models.mkdir(parents=True)
                (tracker.parent / "EyeTracking").symlink_to("EyeTracker")
                for name in hashes:
                    (models / name).write_bytes(name.encode())
                target = models / next(iter(hashes))
                if damage == "missing":
                    target.unlink()
                elif damage == "corrupt":
                    target.write_bytes(b"wrong")
                elif damage == "extra":
                    (models / "yolo.onnx").write_bytes(excluded)
                elif damage == "nested":
                    (models / "nested").mkdir()
                elif damage == "linked-file":
                    target.unlink()
                    target.symlink_to(models / list(hashes)[1])
                elif damage == "linked-directory":
                    (tracker / "other").symlink_to("dist/models")
                elif damage == "linked-ancestor":
                    (tracker / "other").symlink_to("dist")
                elif damage == "unlisted-onnx":
                    (app / "other.onnx").write_bytes(b"unexpected")
                elif damage == "renamed-copy":
                    (app / "index.bin").write_bytes(excluded)
                with patch.object(profile, "PINS", hashes), patch.object(profile, "EXCLUDED", {hashlib.sha256(excluded).hexdigest()}):
                    if damage == "none":
                        profile.verify_models(tracker)
                    else:
                        with self.assertRaises(ValueError):
                            profile.verify_models(tracker)

    def test_uncleared_release_stops_before_provisioning(self):
        with tempfile.TemporaryDirectory() as tmp:
            checkout = Path(tmp) / "fixture"
            for file in ["Makefile", "scripts/bundle-tracker.sh", "scripts/retinaface_release.py",
                         "EyeTracking/scripts/retinaface-release.sha256", "EyeTracking/scripts/required-models.sha256"]:
                (checkout / file).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(SCRIPTS.parent / file, checkout / file)
            for command in (["make", "dist", "VERSION=fixture", "STAGE_APP=" + tmp + "/held.app"],
                            ["bash", "scripts/bundle-tracker.sh", "--release", tmp + "/held.app"]):
                result = subprocess.run(command, cwd=checkout, env={"PATH": "/usr/bin:/bin", "HOME": tmp},
                                        capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("weight redistribution", result.stderr)
                self.assertFalse((Path(tmp) / "held.app").exists())

    def test_conflicting_modes_never_downgrade_release(self):
        for flags in [["--release", "--if-present"], ["--require", "--release"]]:
            result = subprocess.run(["bash", str(SCRIPTS / "bundle-tracker.sh"), *flags],
                                    env={"PATH": "/usr/bin:/bin", "SKIP_TRACKER_BUNDLE": "1"},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 1)
            self.assertIn("Choose one tracker staging mode", result.stderr)


if __name__ == "__main__":
    unittest.main()
