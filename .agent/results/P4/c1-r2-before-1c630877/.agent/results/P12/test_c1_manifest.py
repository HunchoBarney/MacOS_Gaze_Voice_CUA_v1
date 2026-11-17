import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile
import unittest


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("c1_manifest", HERE / "c1_manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class CandidateManifestTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.receipt = Path(os.environ.get("JEV_C1_RECEIPT", HERE / "c1-final-stage.json"))
        cls.data = manifest.create(cls.receipt)

    def testActualCandidateAndRequiredModelsVerifyWithoutClaimingPortability(self):
        result = manifest.verify(self.data)
        self.assertTrue(result["candidate_verified"])
        self.assertFalse(result["release_ready"])
        self.assertTrue(any("external speech model" in item for item in result["release_blockers"]))
        self.assertEqual(len(result["speech_models"]), 2)

    def testWrongBinaryFails(self):
        data = copy.deepcopy(self.data)
        data["binary_sha256"] = "0" * 64
        with self.assertRaisesRegex(ValueError, "binary identity"):
            manifest.verify(data)

    def testSDKAndDriverGenerationCannotDiverge(self):
        data = copy.deepcopy(self.data)
        data["integration"]["driver_generation"] = "0.45.4"
        with self.assertRaisesRegex(ValueError, "SDK.*generation"):
            manifest.verify(data)

    def testEscapedResourcePathFails(self):
        data = copy.deepcopy(self.data)
        data["required_resources"].append("../MacOS/JevVoice")
        with self.assertRaisesRegex(ValueError, "resource path"):
            manifest.verify(data)

    def testMissingSpeechModelFails(self):
        data = copy.deepcopy(self.data)
        data["speech_models"]["parakeet-ultra"]["root"] += "/c1-intentionally-missing"
        with self.assertRaisesRegex(ValueError, "missing speech model"):
            manifest.verify(data)

    def testMissingNoticeInIsolatedCloneFailsWithoutTouchingRollback(self):
        stage = manifest.staging()
        rollback = Path(self.data["rollback_app"])
        rollback_main = stage.digest(rollback / "Contents/MacOS/JevVoice")
        rollback_info = stage.digest(rollback / "Contents/Info.plist")
        notice = "ThirdParty/CuaDriver/THIRD_PARTY_NOTICES.md"
        rollback_notice = stage.digest(rollback / "Contents/Resources" / notice)
        source = Path(self.data["app"])
        with tempfile.TemporaryDirectory(prefix="jev-c1-negative-") as temp:
            clone = Path(temp) / "Jev Voice.app"
            shutil.copytree(source, clone, symlinks=True, copy_function=manifest.clone_file)
            (clone / "Contents/Resources" / notice).unlink()
            with self.assertRaisesRegex(ValueError, "missing resource.*NOTICES"):
                manifest.verify(self.data, app=clone)
        self.assertEqual(stage.digest(rollback / "Contents/MacOS/JevVoice"), rollback_main)
        self.assertEqual(stage.digest(rollback / "Contents/Info.plist"), rollback_info)
        self.assertEqual(stage.digest(rollback / "Contents/Resources" / notice), rollback_notice)
        self.assertTrue((source / "Contents/Resources" / notice).is_file())


if __name__ == "__main__":
    unittest.main()
