# Cua integration provenance and recovery

The app verifies `/Applications/CuaDriverLocal.app/Contents/MacOS/cua-driver-local`
against SHA-256 `699d330bd1cd4e2255f0c99e889f1358952de246254fac7e4417b08dd6578d2a`.
The authoritative runtime constants are in
[`CuaDependency.swift`](../../Sources/JevVoice/ComputerControl/CuaDependency.swift).
Do not update the pin just to accept a different build.

## Preserved source

- Upstream: https://github.com/trycua/cua
- Base: perception PR #3943, `b703a8d17fb513c6288f247f710d30643abd068d`.
- Last recorded local integration revision: `662e9ddb2e2fd6ded048635713e199b3476926a6`.
  Its Git object database is unavailable; this is historical identity, not a
  claim that a reconstructed checkout will have that commit ID.
- `local-integration.patch`: the 30 changed/added files relative to that base,
  recovered by byte comparison with the pinned upstream archive.
- `source-manifest.json`: hashes of all 898 preserved local source/config/fixture
  files and the patch. The working tree is sparse; absent upstream paths are not
  treated as deletions. Generated builds, dependencies and models are excluded.
- `LICENSE.md`: upstream license. Preserve upstream notices in reconstructed builds.

The patch includes the local perception artifact tooling and native control/schema
repairs. The detailed adoption/test history remains in
[the migration evidence](../../docs/voice-ui/EVIDENCE.md). It is recovery material,
not a newly reviewed or accepted upstream release.

## Reconstruct into a new directory

Do not run these commands inside the existing broken Cua checkout. Set the first
path to a new, empty destination; the other path is your current Jarvis checkout.
The clone downloads upstream source and needs network/storage; it is not automatic
Conductor setup.

```sh
git clone --no-checkout https://github.com/trycua/cua.git /path/to/new-cua-source
git -C /path/to/new-cua-source checkout --detach b703a8d17fb513c6288f247f710d30643abd068d
git -C /path/to/new-cua-source apply --check /path/to/Jarvis/ThirdParty/Cua/local-integration.patch
git -C /path/to/new-cua-source apply /path/to/Jarvis/ThirdParty/Cua/local-integration.patch
python3 /path/to/Jarvis/scripts/verify-cua-source.py /path/to/new-cua-source
```

This verifies source content, not binary reproducibility. Build from the restored
Driver's Rust directory using its pinned toolchain and lockfile, following its
own instructions. The recorded build command is
`cargo build --release --locked -p cua-driver -p cua-perception`.
Do not replace the installed Driver during cleanup. Rebuilding/signing may change
binary identity and macOS permission requirements; installing a new dependency
requires separate integration validation and an intentional pin update.

## Models and local state

The source patch preserves local artifact tooling/lock metadata. Large downloaded
model/runtime assets, export environments and sealed perception bundles remain in
`development/JevVoice/`, where present. They are not part of this Git repository.
Use the hash-verifying upstream tooling and recorded evidence to reconstruct them;
do not claim a fresh source checkout is a fully configured runtime.

The existing source still lives at `development/JevVoice/cua-source`; its `.git`
points to a missing worktree database. Nothing in this cleanup rewrites that pointer
or deletes its builds. Run the verifier above against it to compare the preserved
snapshot. See [storage and recovery](../../docs/LOCAL-DEVELOPMENT-STORAGE.md).
