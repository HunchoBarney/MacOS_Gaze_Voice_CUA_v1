#!/usr/bin/env python3
"""Seed isolated workspace source; expose shared assets only as reference material."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil

REFERENCE_DIRS = ('perception-bundles', 'perception-downloads', 'perception-inputs',
                  'handoff', 'rollback', 'verification', 'upstream-pr-audit',
                  'perception-quality-results.artifacts')
LOCAL_DIRS = ('build', 'staging', 'probe', 'verification', 'perception-export-env',
              'perception-bundles', 'perception-downloads', 'perception-inputs',
              'perception-quality-results.artifacts')


def setup(workspace, source):
    workspace = workspace.resolve()
    source = source.resolve()
    development = workspace / 'development'
    if workspace == source.parent.parent:
        print('Repository root owns the original development assets; leaving them untouched.')
        return
    manifest = json.loads((workspace / 'ThirdParty/Cua/source-manifest.json').read_text())
    # Check all seed files before replacing the old whole-folder link.
    for name, expected in manifest['files'].items():
        relative = Path(name)
        if relative.is_absolute() or '..' in relative.parts:
            raise RuntimeError('Unsafe source manifest path: ' + name)
        origin = source / 'cua-source' / relative
        if origin.is_symlink() or hashlib.sha256(origin.read_bytes()).hexdigest() != expected:
            raise RuntimeError('Source differs from preserved manifest: ' + name)
    if development.is_symlink():
        if development.resolve() != source.parent:
            raise RuntimeError('Refusing to replace an unexpected development link')
        development.unlink()  # Only the link, never its target.
    local = development / 'JevVoice'
    local.mkdir(parents=True, exist_ok=True)
    if local.is_symlink() or (local / 'cua-source').is_symlink():
        raise RuntimeError('Local source/output directories must not be symlinks')
    for name in manifest['files']:
        target = local / 'cua-source' / name
        if any(parent.is_symlink() for parent in target.parents if parent != workspace):
            raise RuntimeError('Source path traverses a symlink: ' + str(target))
        if target.is_symlink():
            raise RuntimeError('Workspace source file must not be a symlink: ' + str(target))
        if target.exists():
            continue  # Preserve edits on repeated setup.
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / 'cua-source' / name, target)
    for name in LOCAL_DIRS:
        target = local / name
        if target.is_symlink():
            raise RuntimeError('Output directory must be local: ' + str(target))
        target.mkdir(exist_ok=True)
    config = local / 'perception-quality-config.json'
    if not config.exists():
        data = json.loads((source / config.name).read_text())
        for artifact in data.get('bindings', {}).get('artifacts', []):
            if artifact.get('path', '').startswith('perception-bundles/'):
                artifact['path'] = 'reference/' + artifact['path']
        config.write_text(json.dumps(data, indent=2) + '\n')
    reference = local / 'reference'
    if reference.is_symlink():
        raise RuntimeError('Reference container must be local')
    reference.mkdir(exist_ok=True)
    names = REFERENCE_DIRS + ('perception-quality-report.json', 'perception-quality-results.json')
    for name in names:
        target = reference / name
        origin = source / name
        if not origin.exists():
            continue
        if target.is_symlink() and target.resolve() == origin.resolve():
            continue
        if target.exists() or target.is_symlink():
            raise RuntimeError('Refusing to replace reference: ' + str(target))
        target.symlink_to(origin, target_is_directory=origin.is_dir())
    (development / 'AGENTS.md').write_text('''# Workspace development assets

`JevVoice/cua-source/` is a workspace-local copy of the preserved source manifest.
Its historical broken Git metadata, dependencies and generated builds are not copied.
Keep source edits and all new build/test/export output inside this workspace.
Do not use the original repository development folder or the legacy
~/Library/Caches/JevVoice compatibility link as an output location.

`JevVoice/reference/` contains shared symbolic links. Treat every target as READ-ONLY:
never modify, delete, chmod, rebuild, install into, or write results there.
Copy any input requiring modification to a local directory first. Pass explicit
workspace-local output paths to tools; inspect copied configs for absolute paths.
The links are not a filesystem security boundary. Dependencies/environments must
be created locally using the existing pins. Do not auto-upgrade or install Driver.

This entire directory is Git-ignored. Preserve source changes as a reviewed patch
in the parent repository when they need to be shared; do not assume Git saves them.
''')
    print('Workspace development ready: ' + str(local))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=Path.cwd())
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    source = args.source
    if source is None:
        configured = os.environ.get('JARVIS_DEVELOPMENT_SOURCE')
        if configured:
            source = Path(configured)
    if source is None:
        root = os.environ.get('CONDUCTOR_ROOT_PATH')
        if not root or os.environ.get('CONDUCTOR_IS_LOCAL') == '0':
            print('No local Conductor asset root; skipping development assets.')
            return
        source = Path(root) / 'development/JevVoice'
    if not source.is_dir():
        raise RuntimeError('No local development assets at ' + str(source))
    setup(args.workspace, source)


if __name__ == '__main__':
    main()
