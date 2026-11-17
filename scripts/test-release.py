import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ReleaseTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = ROOT / ".github/workflows/release.yml"
        cls.jobs = json.loads(subprocess.check_output([
            "ruby", "-ryaml", "-rjson", "-e", "puts YAML.load_file(ARGV[0])['jobs'].to_json", str(path)]))

    def test_tag_and_cask_checkouts_are_separate(self):
        steps = self.jobs["release"]["steps"]
        refs = [s["with"]["ref"] for s in steps if s.get("uses", "").startswith("actions/checkout@")]
        self.assertEqual(refs, ["${{ github.sha }}"])
        commands = "\n".join(s.get("run", "") for s in steps)
        gates = ["${GITHUB_REF}^{commit}", "verification-lane.sh release-dist", "ditto -x -k", "codesign --verify --deep --strict",
                 'scripts/check-packaged-tracker.py "$app"', "shasum -a 256", "gh release create"]
        self.assertEqual(sorted(gates, key=commands.index), gates)
        cask = self.jobs["cask"]
        self.assertEqual(cask["needs"], "release")
        self.assertEqual(cask["steps"][0]["with"]["ref"], "main")
        update = cask["steps"][-1]["run"]
        self.assertIn("git push origin HEAD:main", update)
        self.assertNotIn("--force", update)

    def test_same_version_different_commit_is_rejected(self):
        check = next(s["run"] for s in self.jobs["release"]["steps"] if "GITHUB_REF_TYPE" in s.get("run", ""))
        with tempfile.TemporaryDirectory() as tmp:
            repo = Path(tmp)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=repo, text=True).strip()
            git("init", "-q")
            root = git("-C", str(ROOT), "rev-parse", "HEAD")
            objects = git("-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-path", "objects")
            (repo / ".git/objects/info/alternates").write_text(objects + "\n")
            git("update-ref", "HEAD", root)
            (repo / "Info.plist").write_bytes((ROOT / "Info.plist").read_bytes())
            version = subprocess.check_output(["/usr/libexec/PlistBuddy", "-c",
                "Print :CFBundleShortVersionString", str(repo / "Info.plist")], text=True).strip()
            tag = "v" + version
            git("tag", tag)
            env = dict(os.environ, GITHUB_SHA=root, GITHUB_REF_TYPE="tag", GITHUB_REF_NAME=tag,
                       GITHUB_REF="refs/tags/" + tag, GITHUB_ENV=str(repo / "job.env"))
            subprocess.run(["bash", "-ec", check], cwd=repo, env=env, check=True)
            git("update-ref", "refs/tags/" + tag, git("rev-parse", "HEAD^"))
            self.assertNotEqual(subprocess.run(["bash", "-ec", check], cwd=repo, env=env).returncode, 0)

    def test_external_tracker_never_satisfies_archive_check(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "staged.app"
            resources = app / "Contents/Resources"
            resources.mkdir(parents=True)
            target = Path(tmp) / "checkout"
            target.mkdir()
            (resources / "EyeTracker").symlink_to(target)
            (resources / "EyeTracking").symlink_to("EyeTracker")
            result = subprocess.run(["python3", str(ROOT / "scripts/check-packaged-tracker.py"), str(app)],
                                    env=dict(os.environ, JARVIS_EYE_TRACKER_DIR=str(target)), capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b"does not resolve inside the app", result.stderr)

    def test_missing_worker_and_dynamic_import_fail_before_signing(self):
        with tempfile.TemporaryDirectory() as tmp:
            app = Path(tmp) / "fixture.app"
            root = app / "Contents/Resources/EyeTracker"
            for name in ("bin/node", "node_modules/.bin/electron", "node_modules/electron/dist/Electron.app/Contents/MacOS/Electron",
                         "TRACKER_BUNDLE.json", "scripts/start-prod.cjs", "electron/main.cjs", "electron/preload.cjs",
                         "node_modules/electron/cli.js", "dist/index.html", "dist/assets/index.js", "dist/.vite/manifest.json"):
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("fixture")
                path.chmod(0o700)
            (root.parent / "EyeTracking").symlink_to("EyeTracker")
            (root / "dist/index.html").write_text('<script src="./assets/index.js"></script>')
            (root / "dist/assets/index.js").write_text('new URL("inferenceWorker-123.js", import.meta.url)')
            (root / "dist/.vite/manifest.json").write_text(json.dumps({
                "index.html": {"file": "assets/index.js"}, "dynamic": {"file": "assets/inference.js"}}))
            for missing in ("inference.js", "inferenceWorker-123.js"):
                result = subprocess.run(["python3", str(ROOT / "scripts/check-packaged-tracker.py"), str(app)],
                                        capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(("dist/assets/" + missing).encode(), result.stderr)
                (root / "dist/assets" / missing).write_text("fixture")

    def test_launcher_does_not_inherit_electron_override(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("dist", "scripts", "node_modules/.bin"):
                (root / name).mkdir(parents=True)
            (root / "dist/index.html").touch()
            launcher = root / "scripts/start-prod.cjs"
            launcher.write_bytes((ROOT / "EyeTracking/scripts/start-prod.cjs").read_bytes())
            probe = root / "node_modules/.bin/electron"
            probe.write_text('#!/bin/sh\ntest -z "${ELECTRON_OVERRIDE_DIST_PATH+x}" && echo fixture-launcher\n')
            probe.chmod(0o700)
            result = subprocess.run(["node", launcher], env=dict(os.environ, ELECTRON_OVERRIDE_DIST_PATH="/stale"),
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), "fixture-launcher")


if __name__ == "__main__":
    unittest.main(verbosity=2)
