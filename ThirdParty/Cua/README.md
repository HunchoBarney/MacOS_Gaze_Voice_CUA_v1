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
  files, executable-file inventory, and the patch. The working tree is sparse; absent upstream paths are not
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

The current source snapshot, pinned Driver and perception bundle are also shared
as private release assets. See [collaborator handoff](../../docs/HANDOFF.md).

The source patch preserves local artifact tooling/lock metadata. Large downloaded
model/runtime assets, export environments and sealed perception bundles remain in
`development/JevVoice/`, where present. They are not part of this Git repository.
Use the hash-verifying upstream tooling and recorded evidence to reconstruct them;
do not claim a fresh source checkout is a fully configured runtime.

The existing source still lives at `development/JevVoice/cua-source`; its `.git`
points to a missing worktree database. Nothing in this cleanup rewrites that pointer
or deletes its builds. Run the verifier above against it to compare the preserved
snapshot. See [storage and recovery](../../docs/LOCAL-DEVELOPMENT-STORAGE.md).


## Unaccepted execution-simplification candidate

`launch-watchdog-candidate.patch` is a separate, narrowly reviewed delta **after**
the preserved `local-integration.patch` snapshot. It is not part of the installed
runtime or baseline source manifest. It makes an explicit foreground request retire
only that PID's detached background-launch watchdog, with synchronization against
queued/in-flight restoration. Existing ordinary guards remain active.

The workspace-local candidate passed 31 focused Rust tests, locked release build,
strict binary signature verification, and forward/reverse patch recovery. Its
executable SHA-256 is
`b8be58db2df46c27486e66d2861a5ccd12fd06b350fbdc583057212320c7a6de`.
Its own isolated `mcp --direct --embedded` permission probe reported Accessibility
and Screen Recording unavailable under host attribution. Live repair acceptance
is therefore outstanding; do not install it or change the production pin on the
strength of these build/tests. Plain `mcp` would proxy to the installed broker and
would not prove the candidate code.

To reconstruct for review, first reconstruct and verify the baseline above, then
run `git apply --check` followed by `git apply` with this candidate patch in the
new checkout. Reverse only this delta with `git apply -R` after checking it applies.
The baseline verifier intentionally reports these three changed files after the
candidate patch. See [the scoped record](../../docs/EXECUTION-SIMPLIFICATION-REPLACEMENTS.md)
for remaining acceptance requirements. No dependency versions were changed.
