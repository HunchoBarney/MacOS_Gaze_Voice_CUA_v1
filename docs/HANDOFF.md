# Sharing the current development snapshot

This is an as-is handoff, not a finished installer or a claim that migration
acceptance is complete. The packaged binaries target **Apple Silicon, macOS 26+**.
Your collaborator needs access to this private repository and their own API keys
and macOS permission grants. Credentials and personal application state are not shared.

[Download the development packages](https://github.com/HunchoBarney/MacOS_Gaze_Voice_CUA_v1/releases/tag/dev-handoff-2026-09-20).
The repository contains the Jarvis source, tests, docs, Cua patch and provenance.
Large dependencies are attached to that private release rather than normal Git.

| Release asset | What it contains |
| --- | --- |
| `cua-source-662e9ddb.tar.gz` | All 898 preserved customized Cua source/config/fixture files, including executable permissions; no broken `.git` metadata, Rust targets or node_modules |
| `CuaDriverLocal-662e9ddb.zip` | The exact pinned Driver app required by Jarvis; includes the cursor helper/resources |
| `driver-extension-0.1.1.tar.gz` | Installable perception worker, ONNX runtime, converted OCR/icon models, original detector weights, source/exporter archives and notices |
| `Jev-Voice-0.1.5.zip` | The cleanup-verified Jarvis app from source revision `cf1fa3e`; bundle name remains Jev Voice |
| `SHA256SUMS`, `handoff-manifest.json` | Package hashes, sizes and source/platform identities |

The perception package already contains its model/runtime inputs and source offers.
Separate repeated conversions, rejected archives and downloaded exporter copies are
not needed. Compiler output, Python virtualenvs, package caches, old app builds,
rollback snapshots, personal screenshots/transcripts and local session state are
excluded. Useful source fixtures remain in the source archives/repository.

## Get the files

Clone the repository normally. Download all release assets using the GitHub UI or:

```sh
gh release download dev-handoff-2026-09-20 \
  --repo HunchoBarney/MacOS_Gaze_Voice_CUA_v1 \
  --dir /path/to/handoff
cd /path/to/handoff
shasum -a 256 -c SHA256SUMS
```

The release is private; links require repository access. No Git LFS setup is needed.

## Use the supplied runtime

1. Extract `CuaDriverLocal-662e9ddb.zip`. Place `CuaDriverLocal.app` in `/Applications`
   without overwriting a different installation you need. Jarvis checks that exact
   executable path/hash; a stock Cua app is not interchangeable.
2. Open the Driver and handle macOS's security/Accessibility/Screen Recording
   prompts yourself. These are local developer builds, not a notarized installer.
   Permissions from the original Mac cannot be transferred.
3. From the downloaded-assets directory, inspect and install the supplied local
   perception extension with the Driver's supported developer-local mode:

   ```sh
   /Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local extension inspect cua-perception --archive "$PWD/driver-extension-0.1.1.tar.gz" --allow-unsigned-local
   /Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local extension install cua-perception --archive "$PWD/driver-extension-0.1.1.tar.gz" --allow-unsigned-local
   /Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local extension status cua-perception --self-test --json
   ```

   The package is explicitly developer-unsigned-local, not publisher-verified.
   Keep its integrity checks, notices and corresponding source intact.
4. Extract/open Jev Voice, or build it from the checkout. Configure your own Jev
   and optional text-provider keys in Settings, choose your microphone, and grant
   the required macOS permissions. Apple speech assets are prepared on that Mac.

No installation or permission changes were performed while preparing this handoff.
Runtime acceptance on a second Mac remains untested; known gaps remain in
[the migration plan](voice-ui/PLAN.md).

## Work on the source

For Jarvis, see [development commands](DEVELOPMENT.md). For the preserved Cua source,
extract `cua-source-662e9ddb.tar.gz` into a new empty directory, then run from Jarvis:

```sh
python3 scripts/verify-cua-source.py /path/to/extracted-cua-source
```

That source snapshot is sparse and has no Git history; it is enough to inspect the
exact preserved files. For an upstream Git checkout with the local changes applied,
use [Cua reconstruction](../ThirdParty/Cua/README.md). Build dependencies are installed
from its manifests/lockfiles, not copied from the original Mac's caches. Rebuilding
Driver can change its binary hash/signature and requires deliberate integration
validation before changing Jarvis's pin.
