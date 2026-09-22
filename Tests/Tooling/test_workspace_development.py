import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('workspace_setup', Path(__file__).resolve().parents[2] / 'scripts/setup-workspace-development.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class WorkspaceDevelopmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'main/development/JevVoice'
        (self.source / 'cua-source').mkdir(parents=True)
        (self.source / 'cua-source/source.txt').write_text('original')
        (self.source / 'perception-inputs').mkdir()
        (self.source / 'perception-inputs/model').write_text('model')
        (self.source / 'perception-quality-config.json').write_text('{}')
        self.workspace = self.root / 'workspace'
        manifest = self.workspace / 'ThirdParty/Cua/source-manifest.json'
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'files': {'source.txt': hashlib.sha256(b'original').hexdigest()}}))

    def test_isolation_and_rerun_preserves_edits(self):
        (self.workspace / 'development').symlink_to(self.source.parent)
        module.setup(self.workspace, self.source)
        local = self.workspace / 'development/JevVoice'
        self.assertFalse((self.workspace / 'development').is_symlink())
        (local / 'cua-source/source.txt').write_text('local edit')
        (local / 'build/result').write_text('local result')
        module.setup(self.workspace, self.source)
        self.assertEqual((local / 'cua-source/source.txt').read_text(), 'local edit')
        self.assertEqual((self.source / 'cua-source/source.txt').read_text(), 'original')
        self.assertFalse((self.source / 'build/result').exists())
        self.assertEqual((local / 'reference/perception-inputs').resolve(), (self.source / 'perception-inputs').resolve())

    def test_changed_seed_does_not_remove_link(self):
        link = self.workspace / 'development'
        link.symlink_to(self.source.parent)
        (self.source / 'cua-source/source.txt').write_text('changed seed')
        with self.assertRaises(RuntimeError):
            module.setup(self.workspace, self.source)
        self.assertTrue(link.is_symlink())

    def test_root_assets_are_untouched(self):
        module.setup(self.source.parent.parent, self.source)
        self.assertFalse((self.source / 'reference').exists())

    def test_source_link_is_rejected(self):
        local = self.workspace / 'development/JevVoice'
        local.mkdir(parents=True)
        (local / 'cua-source').symlink_to(self.source / 'cua-source')
        with self.assertRaises(RuntimeError):
            module.setup(self.workspace, self.source)
