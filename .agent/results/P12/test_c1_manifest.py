import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("c1_manifest", HERE / "c1_manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class RetainedBaseTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("candidate_stage", HERE.parent / "P4/jev-stage-candidate.py")
        self.candidate = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.candidate)
        self.stage = manifest.staging()

    def testQuietCandidateDoesNotSubstituteTheDiagnosticFreeze(self):
        quiet = "final-first-minute-quiet-1"
        self.assertEqual(self.candidate.choose_base(self.stage, quiet, True)[0], self.candidate.RETAINED_BASE_APP)
        with self.assertRaises(RuntimeError):
            self.candidate.choose_base(self.stage, quiet + "-2", True)
        with self.assertRaises(RuntimeError):
            self.candidate.verify_retest_release({"label": "final-spaces-diagnostic-1", "built_unsigned_main_sha256": "a" * 64}, "a" * 64, quiet)
        with self.assertRaises(RuntimeError):
            self.candidate.choose_base(self.stage, quiet, False)

    def testDiagnosticLabelRequiresItsOwnFreezeAndDestination(self):
        label = "final-spaces-diagnostic-1"
        self.assertEqual(self.candidate.choose_base(self.stage, label, True)[0], self.candidate.RETAINED_BASE_APP)
        with self.assertRaises(RuntimeError):
            self.candidate.choose_base(self.stage, label, False)
        with self.assertRaises(RuntimeError):
            self.candidate.choose_base(self.stage, "final-spaces-diagnostic-2", True)
        snap = {"label": label, "built_unsigned_main_sha256": "b" * 64}
        self.candidate.verify_retest_release(snap, "b" * 64, label)
        for called, frozen, digest in [(label, "final-first-minute-1", "b"),
                                       ("final-first-minute-1", label, "b"), (label, label, "a")]:
            with self.assertRaises(RuntimeError):
                self.candidate.verify_retest_release({**snap, "label": frozen}, digest * 64, called)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            receipt, component = root / "receipt", root / "component"
            for path in (receipt, component):
                path.write_text("keep")
                with self.assertRaises(FileExistsError):
                    self.candidate.reserve_retest(root, receipt, component, label)
                self.assertEqual(path.read_text(), "keep")
                path.unlink()
            parent = self.candidate.reserve_retest(root, receipt, component, label)
            self.assertEqual(parent.name, "jev-c1-" + label)
            with self.assertRaises(FileExistsError):
                self.candidate.reserve_retest(root, receipt, component, label)

    def testFirstMinuteLabelOnlyAdmitsThePinnedRetainedBase(self):
        label = "final-first-minute-1"
        app, sha, metadata = self.candidate.choose_base(self.stage, label, True)
        self.assertEqual((app, sha), (self.candidate.RETAINED_BASE_APP, self.candidate.RETAINED_BASE_SHA))
        self.assertEqual(metadata, self.candidate.retained_base_metadata())
        with self.assertRaises(RuntimeError):
            self.candidate.choose_base(self.stage, label, False)
        with self.assertRaises(RuntimeError):
            self.candidate.choose_base(self.stage, "final-first-minute-2", True)
        with mock.patch.object(self.candidate, "RETAINED_BASE_SHA", "0" * 64):
            with self.assertRaisesRegex(RuntimeError, "binary identity"):
                self.candidate.choose_base(self.stage, label, True)

    def testFirstMinuteDestinationAndEvidenceAreExclusive(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            receipt = root / "receipt.json"
            component = root / "component.json"
            for path in [receipt, component]:
                path.symlink_to(root / "dangling")
                with self.assertRaises(FileExistsError):
                    self.candidate.reserve_retest(root, receipt, component)
                self.assertTrue(path.is_symlink())
                path.unlink()
                path.write_text("keep")
                with self.assertRaises(FileExistsError):
                    self.candidate.reserve_retest(root, receipt, component)
                self.assertEqual(path.read_text(), "keep")
                path.unlink()
            parent = self.candidate.reserve_retest(root, receipt, component)
            self.assertEqual(parent.stat().st_mode & 0o777, 0o700)
            with self.assertRaises(FileExistsError):
                self.candidate.reserve_retest(root, receipt, component)

    def testFirstMinuteReleaseMustMatchItsNamedFreeze(self):
        snapshot = {"label": "final-first-minute-1", "built_unsigned_main_sha256": "a" * 64}
        self.candidate.verify_retest_release(snapshot, "a" * 64)
        for change in [{"label": "final-r10"}, {"built_unsigned_main_sha256": "b" * 64}]:
            with self.assertRaises(RuntimeError):
                self.candidate.verify_retest_release({**snapshot, **change}, "a" * 64)

    def testActualRetainedBaseMatchesEveryRecordedIdentity(self):
        app, sha, fields = self.candidate.choose_base(self.stage, "final-r10", True)
        self.assertEqual(app, self.candidate.RETAINED_BASE_APP)
        self.assertEqual(sha, self.candidate.RETAINED_BASE_SHA)
        self.assertEqual(fields["rollback_role"], "last_verified_candidate")
        self.assertEqual(fields["historical_daily"]["status"], "missing")
        self.assertFalse(fields["historical_daily"].get("restored", False))

    def testRetainedFlagCannotSelectAnotherLabel(self):
        with self.assertRaisesRegex(RuntimeError, "only final-r10"):
            self.candidate.choose_base(self.stage, "final-r8", True)

    def testPresentPartialAndDanglingDailyAreRejected(self):
        with tempfile.TemporaryDirectory(prefix="jev-c1-base-guard-") as temp:
            daily = Path(temp) / "Jev Voice.app"
            with mock.patch.object(self.candidate, "DAILY_APP", daily, create=True):
                daily.mkdir()
                with self.assertRaisesRegex(RuntimeError, "daily path must be absent"):
                    self.candidate.choose_base(self.stage, "final-r10", True)
                (daily / "Contents").mkdir()
                with self.assertRaisesRegex(RuntimeError, "daily path must be absent"):
                    self.candidate.choose_base(self.stage, "final-r10", True)
                shutil.rmtree(daily)
                daily.symlink_to(Path(temp) / "missing-app")
                with self.assertRaisesRegex(RuntimeError, "daily path must be absent"):
                    self.candidate.choose_base(self.stage, "final-r10", True)

    def testChangedReceiptAndWrongAppAreRejected(self):
        receipt = self.candidate.RETAINED_BASE_RECEIPT
        original = json.loads(receipt.read_text())
        with tempfile.TemporaryDirectory(prefix="jev-c1-base-receipt-") as temp:
            altered = Path(temp) / "receipt.json"
            altered.write_text("{}")
            with mock.patch.object(self.candidate, "RETAINED_BASE_RECEIPT", altered):
                with self.assertRaisesRegex(RuntimeError, "retained receipt identity"):
                    self.candidate.choose_base(self.stage, "final-r10", True)
                original["app"] = str(Path(temp) / "different.app")
                altered.write_text(json.dumps(original))
                with mock.patch.object(self.candidate, "RETAINED_BASE_RECEIPT_SHA", self.stage.digest(altered)):
                    with self.assertRaisesRegex(RuntimeError, "retained app identity"):
                        self.candidate.choose_base(self.stage, "final-r10", True)

    def testRealCloneRejectsCorruptedBinaryAndSignatureWithoutChangingBase(self):
        source = self.candidate.RETAINED_BASE_APP
        original_receipt = json.loads(self.candidate.RETAINED_BASE_RECEIPT.read_text())
        original_resources = self.stage.resources(source)
        with tempfile.TemporaryDirectory(prefix="jev-c1-base-control-", dir=source.parent.parent) as temp:
            clone = Path(temp) / "Jev Voice.app"
            shutil.copytree(source, clone, symlinks=True, copy_function=manifest.clone_file)
            altered = Path(temp) / "receipt.json"
            original_receipt["app"] = str(clone)
            altered.write_text(json.dumps(original_receipt))
            with mock.patch.multiple(self.candidate,
                                     RETAINED_BASE_APP=clone,
                                     RETAINED_BASE_RECEIPT=altered,
                                     RETAINED_BASE_RECEIPT_SHA=self.stage.digest(altered)):
                binary = clone / "Contents/MacOS/JevVoice"
                with binary.open("r+b") as stream:
                    stream.write(b"broken")
                with self.assertRaisesRegex(RuntimeError, "retained binary identity"):
                    self.candidate.choose_base(self.stage, "final-r10", True)
                shutil.copyfile(source / "Contents/MacOS/JevVoice", binary)
                (clone / "Contents/_CodeSignature/CodeResources").write_text("{}")
                with self.assertRaises(subprocess.CalledProcessError):
                    self.candidate.choose_base(self.stage, "final-r10", True)
        self.assertEqual(self.stage.digest(source / "Contents/MacOS/JevVoice"), self.candidate.RETAINED_BASE_SHA)
        self.assertEqual(self.stage.resources(source), original_resources)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(source)], check=True)

    def testMissingOrChangedRetainedProvenanceIsRejected(self):
        fields = self.candidate.retained_base_metadata()
        for key in fields:
            for omit in (True, False):
                altered = copy.deepcopy(fields)
                if omit:
                    altered.pop(key)
                else:
                    altered[key] = "wrong"
                with self.subTest(key=key, omit=omit):
                    with self.assertRaisesRegex(RuntimeError, "retained base provenance"):
                        self.candidate.verify_retained_base(self.stage, "final-r10", altered)
        for key in ("app", "binary_sha256", "status"):
            altered = copy.deepcopy(fields)
            altered["historical_daily"][key] = "wrong"
            with self.subTest(historical=key):
                with self.assertRaisesRegex(RuntimeError, "retained base provenance"):
                    self.candidate.verify_retained_base(self.stage, "final-r10", altered)


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

    def testStagedRollbackProvenanceCannotBeOmittedOrChanged(self):
        if self.data.get("rollback_role") != "last_verified_candidate":
            self.skipTest("This earlier candidate used the original daily app.")
        for field in ("rollback_role", "base_receipt", "base_receipt_sha256", "historical_daily"):
            for omit in (True, False):
                data = copy.deepcopy(self.data)
                if omit:
                    data.pop(field)
                else:
                    data[field] = "wrong"
                with self.subTest(field=field, omit=omit):
                    with self.assertRaisesRegex(ValueError, "rollback provenance"):
                        manifest.verify(data)


if __name__ == "__main__":
    unittest.main()
