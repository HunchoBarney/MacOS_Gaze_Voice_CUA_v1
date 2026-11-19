#!/usr/bin/env python3
"""Prepare workspace-local development directories in a worktree.

The repo is self-contained: cua-source is tracked, everything else under
development/Jarvis is local generated output. This script verifies the
tracked source is complete, creates the local output directories, and
writes the workspace asset note.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess

LOCAL_DIRS = ('build', 'staging', 'probe', 'verification', 'perception-export-env',
              'perception-bundles', 'perception-downloads', 'perception-inputs',
              'perception-quality-results.artifacts')


def tracked_source_files(workspace):
    result = subprocess.run(
        ['git', '-C', str(workspace), 'ls-files', '-z', '--',
         'development/Jarvis/cua-source/'],
        capture_output=True, check=False,
    )
    if result.returncode:
        return set()
    prefix = 'development/Jarvis/cua-source/'
    return {name.decode()[len(prefix):] for name in result.stdout.split(b'\0')
            if name}


def setup(workspace):
    workspace = workspace.resolve()
    development = workspace / 'development'
    manifest = json.loads((workspace / 'ThirdParty/Cua/source-manifest.json').read_text())
    for name in manifest['files']:
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Unsafe source manifest path: ' + name)
    tracked = tracked_source_files(workspace)
    if tracked and not set(manifest['files']).issubset(tracked):
        raise RuntimeError('Workspace tracks only part of the preserved Cua source')
    if not tracked:
        raise RuntimeError(
            'development/Jarvis/cua-source is not tracked on this branch; '
            'worktrees need a branch where it is')
    if development.is_symlink():
        development.unlink()  # Only the link, never its target.
    local = development / 'Jarvis'
    local.mkdir(parents=True, exist_ok=True)
    if local.is_symlink() or (local / 'cua-source').is_symlink():
        raise RuntimeError('Local source/output directories must not be symlinks')
    for name in manifest['files']:
        target = local / 'cua-source' / name
        if any(parent.is_symlink() for parent in target.parents if parent != workspace):
            raise RuntimeError('Source path traverses a symlink: ' + str(target))
        if target.is_symlink():
            raise RuntimeError('Workspace source file must not be a symlink: ' + str(target))
        if not target.is_file():
            raise RuntimeError('Tracked workspace source is missing: ' + str(target))
    for name in LOCAL_DIRS:
        target = local / name
        if target.is_symlink():
            raise RuntimeError('Output directory must be local: ' + str(target))
        target.mkdir(exist_ok=True)
    (development / 'AGENTS.md').write_text('''# Workspace development assets

`Jarvis/` is workspace-local. Git tracks `cua-source/` and small text
files; everything else here is generated output and stays ignored.
Keep all new build/test/export output inside this workspace.
''')
    print('Workspace development ready: ' + str(local))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path.cwd())
    args = parser.parse_args()
    setup(args.workspace)


if __name__ == '__main__':
    main()
