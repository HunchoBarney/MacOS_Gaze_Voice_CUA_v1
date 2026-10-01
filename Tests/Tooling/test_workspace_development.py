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
        self.workspace = self.root / 'workspace'
        manifest = self.workspace / 'ThirdParty/Cua/source-manifest.json'
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({'files': {'source.txt': hashlib.sha256(b'original').hexdigest()}}))
        subprocess.run(['git', 'init', '--quiet', str(self.workspace)], check=True)
        tracked = self.workspace / 'development/JevVoice/cua-source/source.txt'
        tracked.parent.mkdir(parents=True)
        tracked.write_text('original')
        subprocess.run(['git', '-C', str(self.workspace), 'add',
                        'development/JevVoice/cua-source/source.txt'], check=True)

    def test_conductor_context_is_ignored(self):
        repository = Path(__file__).resolve().parents[2]
        result = subprocess.run(
            ['git', 'check-ignore', '--quiet', '--no-index', '.context/checkpoint-probe'],
            cwd=repository,
            check=False,
        )
        self.assertEqual(result.returncode, 0)

    def test_only_cua_source_is_visible_to_git(self):
        repository = Path(__file__).resolve().parents[2]
        for path, ignored in (
            ('development/JevVoice/cua-source/README.md', False),
            ('development/JevVoice/cua-source/libs/cua-driver/rust/target/debug/cua-driver', True),
            ('development/JevVoice/reference/perception-inputs', True),
            ('development/JevVoice/staging/output', True),
            ('development/AGENTS.md', True),
        ):
            result = subprocess.run(
                ['git', 'check-ignore', '--quiet', '--no-index', path],
                cwd=repository, check=False,
            )
            self.assertEqual(result.returncode == 0, ignored, path)

    def test_creates_local_dirs_and_rerun_preserves_edits(self):
        module.setup(self.workspace)
        local = self.workspace / 'development/JevVoice'
        for name in module.LOCAL_DIRS:
            self.assertTrue((local / name).is_dir(), name)
        (local / 'cua-source/source.txt').write_text('local edit')
        (local / 'build/result').write_text('local result')
        module.setup(self.workspace)
        self.assertEqual((local / 'cua-source/source.txt').read_text(), 'local edit')
        self.assertEqual((local / 'build/result').read_text(), 'local result')

    def test_development_symlink_is_replaced_with_local_dir(self):
        import shutil
        outside = self.root / 'elsewhere'
        outside.mkdir()
        (outside / 'sentinel').write_text('untouched')
        shutil.rmtree(self.workspace / 'development')
        (self.workspace / 'development').symlink_to(outside)
        with self.assertRaises(RuntimeError):  # tracked source now absent from worktree
            module.setup(self.workspace)
        self.assertFalse((self.workspace / 'development').is_symlink())
        self.assertEqual((outside / 'sentinel').read_text(), 'untouched')

    def test_missing_tracked_source_is_an_error(self):
        (self.workspace / 'development/JevVoice/cua-source/source.txt').unlink()
        with self.assertRaises(RuntimeError):
            module.setup(self.workspace)

    def test_cua_source_symlink_is_rejected(self):
        outside = self.root / 'elsewhere'
        outside.mkdir()
        import shutil
        shutil.rmtree(self.workspace / 'development/JevVoice/cua-source')
        (self.workspace / 'development/JevVoice/cua-source').symlink_to(outside)
        with self.assertRaises(RuntimeError):
            module.setup(self.workspace)

    def test_seed_file_link_is_rejected(self):
        target = self.workspace / 'development/JevVoice/cua-source/source.txt'
        outside = self.root / 'elsewhere.txt'
        outside.write_text('foreign')
        target.unlink()
        target.symlink_to(outside)
        with self.assertRaises(RuntimeError):
            module.setup(self.workspace)
        self.assertTrue(target.is_symlink())

    def test_untracked_source_is_an_error(self):
        subprocess.run(['git', '-C', str(self.workspace), 'rm', '-r', '-q', '--cached',
                        'development/JevVoice/cua-source'], check=True)
        with self.assertRaises(RuntimeError) as ctx:
            module.setup(self.workspace)
        self.assertIn('not tracked', str(ctx.exception))

    def test_main_uses_workspace_argument(self):
        result = subprocess.run(
            [sys.executable, str(SETUP_SCRIPT), '--workspace', str(self.workspace)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.workspace / 'development/JevVoice/staging').is_dir())
