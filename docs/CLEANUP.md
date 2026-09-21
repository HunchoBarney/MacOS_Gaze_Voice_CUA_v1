# Repository cleanup — 2026-09-20

Scope: organization, documentation, development workflow and source recovery.
No product features, dependency upgrades, installed-app replacements, global
settings changes or SSD relocation are included.

## Baseline and decisions

Baseline commit: `381ab8e6656e100305fa39f28c89cb3e1d89fbf1`; the initial working tree
was clean. Recovery material is under
`development/JevVoice/rollback/cleanup-20260920/`: a Git bundle, Cua source archive
and hashes, baseline test output, and source/test move map. Existing apps, models,
credentials and preferences were left in place.

- Grouped Swift source/tests by responsibility without new targets or dependencies.
  Extracted existing shared capture/error declarations out of legacy implementation
  files, without changing declarations or runtime decisions.
- Retained legacy implementation and its regression tests: injected comparison
  seams and conditional fixtures still use it. No capability was removed.
- Replaced the obsolete README pipeline with current wiring and explicit incomplete
  acceptance. Split active plan/spec from build evidence and historical material;
  preserved original evidence and requirements instead of deleting them.
- Added architecture/development entry points and concise agent instructions.
- Added local Conductor test/package commands and a cooperating cross-worktree
  desktop-test lock. Build outputs remain checkout-local. No cache-copy setup.
- Preserved 30 local Cua source changes as an approximately 114 KiB patch against
  the pinned perception PR, plus hashes for 898 local source files. Missing paths
  in the sparse checkout are not represented as deletions. The broken original
  Cua `.git` pointer and large generated directories remain untouched.

There is no blanket dead-code deletion: references and incomplete migration
replacement evidence do not justify it. The inherited Homebrew/release workflow
remains explicitly identified as upstream distribution, not retargeted or published.

## Verification

- Baseline: 248 Swift tests, 18 opt-in skips, zero failures (13.685 s).
- After reorganization/type extraction: 248 Swift tests, same 18 skips,
  zero failures (11.272 s). These are suite durations, not product latency metrics.
- Tooling: two tests prove command exit-code forwarding and serialization of
  cooperating commands launched from different working directories.
- Cua patch: applied to an independent upstream-source worktree; all 898 source
  hashes match the preserved local source. This does not prove binary reproducibility
  or runtime acceptance.
- The release build/signing command succeeds, but later strict verification in
  the original synced checkout fails: the file provider restores FinderInfo on
  the generated bundle. Verification outside that directory is recorded below.

Existing migration gaps remain in [PLAN.md](voice-ui/PLAN.md) and
[EVIDENCE.md](voice-ui/EVIDENCE.md), including speech readiness/quick-release,
complete normal-voice application workflows, dictation and concurrency acceptance.
No new physical Fn/microphone, provider or live desktop result is claimed here.

## Recovery

Local cleanup commits can be reverted in reverse order on a separate branch after
checking for later work. Alternatively inspect the baseline without touching this
checkout:

```sh
git worktree add --detach /path/to/new-recovery-checkout 381ab8e6656e100305fa39f28c89cb3e1d89fbf1
```

If the repository database is lost, clone the saved `jarvis.bundle` into a new
folder. It contains the committed baseline, not ignored models or installed apps.
The Cua source archive is a separate preserved source snapshot; the tracked patch
and manifest provide the documented reconstruction route. Do not reset/clean over
new work or delete `development/`. No installed app needs rollback for this cleanup.
