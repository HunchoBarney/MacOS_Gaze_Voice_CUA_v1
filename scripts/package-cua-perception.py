#!/usr/bin/env python3
"""Convert a sealed PR #3943 worker bundle into Driver's local extension layout.

No downloads, unsigned-publisher claims, or integrity bypasses. The Driver must
still inspect/install the resulting archive using its explicit local mode.
"""
import argparse
import hashlib
import json
import shutil
import tarfile
from pathlib import Path


def digest(path):
    with path.open('rb') as stream:
        value = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def package(source, destination):
    source = source.resolve()
    archive = Path(str(destination) + '.tar.gz')
    if destination.exists() or archive.exists():
        raise ValueError('Refusing to overwrite an existing package')
    manifest = json.loads((source / 'artifact-manifest.json').read_text())
    # Verify every supplied artifact before changing packaging metadata.
    for item in manifest['artifacts']:
        path = source / item['path']
        if path.is_symlink() or not path.is_file() or source not in path.resolve().parents:
            raise ValueError('Artifact escapes the source bundle')
        if path.stat().st_size != item['size'] or digest(path) != item['sha256']:
            raise ValueError('Source artifact hash/size mismatch: ' + item['path'])
    for path in source.rglob('*'):
        if path.is_symlink():
            raise ValueError('Bundle must not contain symlinks')
    shutil.copytree(source, destination)
    worker = next(a for a in manifest['artifacts'] if a['kind'] == 'worker')
    runtime = next(a for a in manifest['artifacts'] if a['kind'] == 'runtime')
    (destination / 'runtime').mkdir()
    shutil.move(str(destination / runtime['path']), str(destination / 'runtime' / runtime['name']))
    # These describe the unchanged input layout; retain them as provenance,
    # without leaving a misleading current-layout SHA256SUMS at the root.
    (destination / 'metadata').mkdir()
    for name in ('artifact-manifest.json', 'SHA256SUMS'):
        shutil.move(str(destination / name), str(destination / 'metadata' / ('input-' + name)))
    models = [a for a in manifest['artifacts'] if a['kind'] == 'model']
    dictionary = next(a for a in manifest['artifacts'] if a['kind'] == 'dictionary')
    binding = lambda a: {'name': a['name'], 'sha256': a['sha256']}
    write(destination / 'metadata/runtime-contract.json', {
        'schemaVersion': 1, 'target': manifest['target']['triple'], 'protocolVersion': 1,
        'worker': binding(worker), 'runtime': binding(runtime),
        'modelManifest': {'name': 'model-manifest.json', 'sha256': digest(destination / 'model-manifest.json')},
        'models': [dict(binding(a), role=a['role']) for a in models],
        'dictionary': dict(binding(dictionary), role='ocr-dictionary'), 'rejectMismatch': True,
    })
    ledger = json.loads((destination / 'model-ledger.json').read_text())['models']
    inventory = json.loads((destination / 'source-inventory.json').read_text())
    notice = {'path': 'THIRD_PARTY_NOTICES.md', 'sha256': digest(destination / 'THIRD_PARTY_NOTICES.md')}
    files = [{'path': str(p.relative_to(destination)), 'sha256': digest(p),
              'executable': str(p.relative_to(destination)) == worker['path']}
             for p in sorted(destination.rglob('*')) if p.is_file()]
    version = manifest['version']
    extension = {
        'schema_version': 1, 'id': 'cua-perception', 'version': version,
        'driver_version': '=0.28.2', 'protocol_version': 1, 'target': manifest['target']['triple'],
        'entrypoint': worker['path'], 'files': files,
        'models': [{'path': 'models/' + m['artifact'], 'revision': m['revision'],
                    'original_sha256': m.get('sourceArtifact', {}).get('sha256', m['artifactSha256']),
                    'conversion_sha256': m['artifactSha256'], 'license_file': notice} for m in ledger],
        'components': [{'name': 'cua-perception', 'version': version, 'license': 'MIT',
                        'notice': 'Bundled source and third-party model/runtime notices retained.',
                        'source_uri': inventory['repository'], 'source_revision': inventory['revision'],
                        'notice_file': notice}],
        'corresponding_source_file': {'path': inventory['archive']['path'], 'sha256': inventory['archive']['sha256']},
        'license': 'MIT; AGPL-3.0-only detector; Apache-2.0 OCR',
        'source': inventory['repository'], 'corresponding_source_uri': inventory['repository'],
        'corresponding_source_revision': inventory['revision'],
        'provenance': 'Local source build; input artifact manifest retained under metadata; no publisher signature.',
        'health_args': ['--health', '--extension-id', 'cua-perception', '--extension-version', version],
        'self_test_args': ['--self-test', '--extension-id', 'cua-perception', '--extension-version', version],
    }
    write(destination / 'extension.json', extension)
    # Driver rejects extended-header pseudo-paths; all bundle paths fit USTAR.
    with tarfile.open(archive, 'w:gz', format=tarfile.USTAR_FORMAT) as stream:
        for path in sorted(destination.rglob('*')):
            if path.is_file():
                info = stream.gettarinfo(str(path), arcname=str(path.relative_to(destination)))
                info.uid = info.gid = 0
                info.uname = info.gname = ''
                info.mtime = 0
                with path.open('rb') as data:
                    stream.addfile(info, data)
    return archive


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(package(args.source, args.destination))
