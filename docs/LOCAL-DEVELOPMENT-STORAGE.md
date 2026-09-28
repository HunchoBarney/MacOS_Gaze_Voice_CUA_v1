# Local development storage

On 2026-09-20, the supporting directory previously stored at
`/Users/karanvirkang/Library/Caches/JevVoice` was moved into this repository's
`development/JevVoice/` directory at the user's request. Source, tests, and
plans remain in their existing locations. The preserved 898-file Cua source tree
under `development/JevVoice/cua-source/` is tracked by Git. Other
`development/` assets, including large builds and local verification artifacts,
remain ignored and require separate preservation.

The old cache path is a symbolic link to the new directory, preserving existing
script, environment, and app paths. This was a same-filesystem rename, not a
copy or rebuild. All 70,143 entries were checked before and after for identical
device/inode, mode, size, modification time, and symbolic-link targets.

Contents include the Cua source/build directory, perception models and packaging
environments, staged apps, verification evidence, and rollback copies. Installed
apps, system-managed preferences, Keychain credentials, and Cua runtime data
outside this directory remain in their existing OS locations.

## Existing Cua Git metadata issue

Before relocation, `cua-source/.git` already pointed to the missing directory
`/private/tmp/jarvis-cua-upstream-20260919/.git/worktrees/cua-source`.
The working files are preserved, but Cua Git history/status cannot currently be
read through that pointer. No Git history reconstruction was attempted during
this storage move. The main Jarvis Git repository remains functional.

## SSD migration and recovery

This consolidation does not move the project to the external SSD. A future SSD
move must update the compatibility link and repair the main repository's
Conductor worktree relationship. Do not delete the original before verification.

To reverse this consolidation with all builds/apps stopped: verify the old cache
path is still the symlink described above, remove only that symlink, and move
`development/JevVoice` back to `/Users/karanvirkang/Library/Caches/JevVoice`.
Do not recursively delete either directory.

## Source recovery added during cleanup

The original broken Cua worktree metadata is unchanged. Its local modifications
are now preserved independently as a patch and 898-file manifest under
[ThirdParty/Cua](../ThirdParty/Cua/README.md). Large generated outputs and model
assets remain here; this does not make `development/` disposable.

## Parallel workspaces

Local Conductor setup runs `scripts/setup-workspace-development.py`. On current
branches, Git checks out the 898 preserved Cua source files into each workspace;
setup keeps those files and prepares local output paths and shared references. On
older branches without tracked source, setup copies the manifest-listed files from
the repository root after checking their historical hashes. The source is a sparse
snapshot, not a complete reconstructed upstream checkout. Setup does not copy the
broken `.git` pointer, existing builds, or dependency environments. Follow
ThirdParty/Cua/README.md if a full checkout is needed for a build.

Each workspace has its own source, build, staging, probe, verification and export
paths. Setup preserves existing source edits on reruns. The original repository's
assets are not modified. Models, sealed bundles, historical evidence and recovery
copies are exposed under `development/JevVoice/reference/` as shared links.
These are read-only by agent policy, not enforced filesystem permissions: all
agents run under the same macOS user. Never direct outputs there; copy an input
locally before changing it. Local quality config points model inputs at reference
bundles; newly generated outputs belong outside `reference/`.

The setup creates a local, ignored `development/AGENTS.md` with these rules.
Changes to the tracked Cua source now appear in `git status` and need review before
commit. Builds, evidence, models, recovery copies and reference links remain
ignored; Git does not back them up. Do not use the legacy cache compatibility link
for workspace outputs. Runtime installation and desktop use remain shared and
require the existing coordination rules.

For manual setup, run from the desired workspace:

```sh
python3 scripts/setup-workspace-development.py --source /absolute/path/to/main-checkout/development/JevVoice
```

When the preserved assets are outside `CONDUCTOR_ROOT_PATH`, configure their
absolute path only in the machine-local repository override:

```toml
[environment_variables.local]
JARVIS_DEVELOPMENT_SOURCE = "/absolute/path/to/development/JevVoice"
```

Local setup fails if that configured/default source is missing, rather than
silently creating a workspace without its required isolated source. Cloud setup
without a local asset root still skips this seeding. Future workspaces need the
shared setup change merged and the repository-local override installed on each
Mac whose preserved assets live elsewhere. Existing workspaces are seeded
independently; setup does not overwrite their source changes.
