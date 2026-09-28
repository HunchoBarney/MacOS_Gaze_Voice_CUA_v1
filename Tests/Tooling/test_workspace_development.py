import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SETUP_SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/setup-workspace-development.py'
spec = importlib.util.spec_from_file_location('workspace_setup', SETUP_SCRIPT)
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

    def test_conductor_context_is_ignored(self):
        repository = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            ['git', 'check-ignore', '--quiet', '--no-index', '.context/checkpoint-probe'],
            cwd=repository,
            check=False,
        )
        self.assertEqual(result.returncode, 0)

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

    def test_seed_file_link_is_rejected(self):
        target = self.workspace / 'development/JevVoice/cua-source/source.txt'
        target.parent.mkdir(parents=True)
        target.symlink_to(self.source / 'cua-source/source.txt')

        with self.assertRaises(RuntimeError):
            module.setup(self.workspace, self.source)

        self.assertTrue(target.is_symlink())
        self.assertEqual((self.source / 'cua-source/source.txt').read_text(), 'original')

    def test_configured_asset_root_precedes_conductor_root(self):
        environment = os.environ.copy()
        environment.update({
            'CONDUCTOR_IS_LOCAL': '1',
            'CONDUCTOR_ROOT_PATH': str(self.root / 'missing-conductor-root'),
            'JARVIS_DEVELOPMENT_SOURCE': str(self.source),
        })
        result = subprocess.run(
            [sys.executable, str(SETUP_SCRIPT), '--workspace', str(self.workspace)],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)
        copied = self.workspace / 'development/JevVoice/cua-source/source.txt'
        self.assertTrue(copied.is_file(), result.stdout)
        self.assertEqual(copied.read_text(), 'original')

    def test_missing_local_asset_root_is_an_error(self):
        environment = os.environ.copy()
        environment.pop('JARVIS_DEVELOPMENT_SOURCE', None)
        environment.update({
            'CONDUCTOR_IS_LOCAL': '1',
            'CONDUCTOR_ROOT_PATH': str(self.root / 'missing-conductor-root'),
        })
        result = subprocess.run(
            [sys.executable, str(SETUP_SCRIPT), '--workspace', str(self.workspace)],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No local development assets', result.stderr)
