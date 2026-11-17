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
        cls.receipt = Path(os.environ.get("JEV_C1_RECEIPT", HERE / "c1-final-r3-stage.json"))
        cls.data = manifest.create(cls.receipt)

    def testActualCandidateAndDeclaredSpeechRequirementsVerifyWithoutClaimingPortability(self):
        result = manifest.verify(self.data)
        self.assertTrue(result["candidate_verified"])
        self.assertFalse(result["release_ready"])
        if self.data.get("voice_provider") == "openai-realtime":
            self.assertFalse(any("external speech model" in item for item in result["release_blockers"]))
            self.assertEqual(result["speech_models"], [])
            self.assertIsNone(self.data["conversation_vad"])
            self.assertFalse(any(item.startswith("ConversationVAD/") for item in self.data["required_resources"]))
        else:
            self.assertTrue(any("external speech model" in item for item in result["release_blockers"]))
            self.assertEqual(len(result["speech_models"]), 2)
            self.assertEqual(self.data["conversation_vad"]["manifest_sha256"], manifest.VAD_RECEIPT_SHA256)

    def testChangedConversationDeclarationFails(self):
        data = copy.deepcopy(self.data)
        if data["conversation_vad"] is None:
            data["conversation_vad"] = {"revision": "unreviewed"}
        else:
            data["conversation_vad"]["revision"] = "unreviewed"
        with self.assertRaisesRegex(ValueError, "conversation model declaration"):
            manifest.verify(data)

    def testMissingAndTamperedConversationFilesFailBeforeModelLoad(self):
        source = Path(self.data["app"]) / "Contents/Resources/ConversationVAD"
        declaration = manifest.conversation_resource(source)
        with tempfile.TemporaryDirectory(prefix="jev-c1-vad-control-") as temporary:
            copied = Path(temporary) / "ConversationVAD"
            shutil.copytree(source, copied)
            (copied / "LICENSE").unlink()
            with self.assertRaisesRegex(ValueError, "missing conversation resource"):
                manifest.conversation_resource(copied)
            shutil.copyfile(source / "LICENSE", copied / "LICENSE")
            member = copied / declaration["model"] / "metadata.json"
            member.write_text("{}")
            with self.assertRaisesRegex(ValueError, "conversation resource changed"):
                manifest.conversation_resource(copied)

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
        if data.get("voice_provider") == "openai-realtime":
            data["speech_models"] = {"unexpected-local-model": {}}
            with self.assertRaisesRegex(ValueError, "speech model declaration"):
                manifest.verify(data)
        else:
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
