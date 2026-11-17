import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("native_signing_keeper", HERE / "jev-native-ui-fixture.py")
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)


@unittest.skipUnless(os.environ.get("JARVIS_P4_REAL_APPS") == "approved",
                     "owned local signing requires explicit approval")
class NativeFixtureSigningTests(unittest.TestCase):
    def test_forbidden_source_metadata_does_not_enter_signing_copy(self):
        real = FIXTURE.SHARED.load("native_signing_real", "jev-realapps.py")
        system_binary = Path("/bin/echo")
        system_hash = hashlib.sha256(system_binary.read_bytes()).hexdigest()
        workspace = HERE.parents[2] / "development/JevVoice/staging"
        with tempfile.TemporaryDirectory(prefix="jev-native-signing-keeper-", dir=workspace) as temporary:
            out = Path(temporary)
            bundle = out / "Documents" / "Fixture.app"
            binary = bundle / "Contents/MacOS/Fixture"
            binary.parent.mkdir(parents=True)
            shutil.copyfile(system_binary, binary)
            binary.chmod(0o755)
            info = plistlib.dumps({
                "CFBundleIdentifier": "dev.jevvoice.native-signing-keeper",
                "CFBundleExecutable": "Fixture", "CFBundlePackageType": "APPL",
            })
            (bundle / "Contents/Info.plist").write_bytes(info)
            subprocess.run(["xattr", "-wx", "com.apple.FinderInfo",
                            (b"TESTTEST" + bytes(24)).hex(), str(bundle)],
                           check=True, capture_output=True, timeout=30)
            dirty = subprocess.run(["codesign", "--force", "--sign", "-", str(bundle)],
                                   capture_output=True, text=True, timeout=30)
            self.assertNotEqual(dirty.returncode, 0)
            self.assertIn("resource fork, Finder information, or similar detritus", dirty.stderr)

            FIXTURE.seal_fixture(bundle, out, real)

            receipt = json.loads((out / "signature-copy.json").read_text())
            self.assertTrue(receipt["signed_outside_synced_tree"])
            self.assertTrue(receipt["exact_file_mode_match"])
            self.assertTrue(receipt["verified"])
            self.assertEqual((bundle / "Contents/Info.plist").read_bytes(), info)
            self.assertTrue((bundle / "Contents/_CodeSignature/CodeResources").is_file())
        self.assertEqual(hashlib.sha256(system_binary.read_bytes()).hexdigest(), system_hash)


if __name__ == "__main__":
    unittest.main()
