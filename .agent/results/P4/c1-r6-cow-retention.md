# C1 storage continuation: preserve bytes with APFS sharing

G2 PASS5569d238 before helper implementation. User directs autonomous GB
reclamation and C1 completion.

Archive amendment G2 PASS5569d238 was implemented narrowly. R4 archival
completed:5613entries,707034196B ZIP, SHA57f3547e586a8ddf066766be6afaeb7a97347dd4112697ddce1710ccae13c12d;
all bytes/modes/links/signatures verified, original removed, f6/29b4/R5 intact.
Free bytes at that operation1867067392->2288807936. Other filesystem growth
continued. Savedc292 archive hit emergency guard75; partial ZIP removed,
original untouched. Preserve its failed receipt/manifest; do not overwrite.
Do not retry that archive now or claim GB freed from the allocation listing.

Read-only inventory found32GiB listed in older generated vision-stage app pairs.
These already share some APFS storage:16 identical193596595B gaze-model files
have only two distinct first extents. Do not claim16physical copies.
Code artifacts differ chiefly in their existing signing trailers. Example
native-d121 before/after Codex binaries:240152160B each, same CDHash
75c545e5e3df4f51a416bbcc911e438b329a75e9, zero shared physical bytes, differing
only in the final28256B block. Full hashes a1796c8… /f860c85… differ.

The isolated temporary-file prototype c1-cow-probe.json PASSED without replacing
either original: native clonefile of source, system rsync --checksum --inplace
--no-whole-file to reproduce exact destination, copyfile COPYFILE_METADATA(7)
from original, original times restored, full destination SHA/metadata equality
and strict standalone signature. Four prefix samples remain physically shared.
Temporary file deleted; original inode/bytes/metadata unchanged. Existing
storage guard1.5GiB-start/1GiB-stop used. Installed SDK headers supplied flags.
System rsync is openrsync protocol29 and accepted/ran these options.

## Exact proposed scope

Own new P12/c1-share-stage-resources.py and generated evidence only.
Canonical sources are READ-ONLY resources in current signed R5 from
P12/c1-final-r5-stage.json. Dailyf6, baseline29b4 and entireR5 remain untouched.
All source files retain their hashes and signature; no app is re-signed.

Targets are only these generated old app paths:

- completion-research-20261110/native-d114..native-d121-candidate-stage,
  before.app and after.app.
- Same root: jev-vision-ab-d14-admission/after.app,
  jev-vision-ab-d15-trace-baseline/{before,after}.app,
  jev-vision-ab-d16-baseline/{before,after}.app.
- development/JevVoice/recovery-20261110/signed-baselines/{before,after}.app.
- Savedc292 at exact app in P12/c1-delivery-receipt.json (kept ready, not archived).

Root is the already identified workspace-local vision-driver/development/JevVoice.
No arbitrary root arguments, glob deletion, model removal, cache removal, source
or evidence removal. The current R6 source214file snapshot is unchanged.
All old app names and paths stay available, with their original signed bytes.

Only SIX fixed relative resource paths may be replaced:
CodexRuntime/codex; CodexRuntime/bin/codex; CodexRuntime/bin/codex-code-mode-host;
EyeTracker/bin/node; EyeTracker/dist/models/gaze_1x3x160x160.onnx; the
Electron Framework binary under the existing electron@42.4.1/.pnpm path.
All are under Contents/Resources. Both Codex copies may share R5's root Codex.
Current R5 sizes/CDHashes match the inspected legacy binaries.
Main executables, Cua drivers, manifests, sign envelopes, settings and all
other files are excluded.

## Transaction and proof

Freeze per-file full SHA, exact metadata (mode/uid/gid/flags/mtime/xattrs/ACL),
inode/device and byte size before writes. Reject symlinks/escaping parents,
non-regular files, multiple hardlinks, foreign owner, different devices, open
handles or unexpected existing temporary paths. Require matching size and
CodeDirectory hash for signed components, exact hash for the ONNX model;
skip differing versions rather than swapping them.

Use native clonefile with NO full-copy fallback, system rsync only into a NEW
owned temporary clone if necessary, and native copyfile metadata from the
original. Verify the complete original destination hash and metadata on the
temporary result before replacement. No changed logical bytes are acceptable.
Keep hash reads uncached via the installed F_NOCACHE48 to avoid page-cache churn.

Use native atomic file exchange (renamex_np RENAME_SWAP, validate installed
header) with a temporary path outside app bundles on the same volume. It
preserves the original as a backup until full validation. Reject unsupported
exchange; no non-atomic fallback. Verify same target bytes/metadata and
standalone signature before deleting the backup; swap back on failure.
Record each transaction before exchange and after commit, so interruption
leaves recoverable unchanged bytes. No temp extra file inside a sealed app.

Record complete-app strict signature status before/after touched legacy apps;
do not repair pre-existing legacy failure or claim it ready if it was invalid.
Signature status must not regress. Daily/baseline/R5 strict verification must
still pass and identities remain unchanged. The storage representation/inodes
may change on eligible old resources; bytes, modes, ACL/xattrs, paths, signing
identity and runtime behavior do not.

Use the existing1.5/1 storage guard, one file at a time. No new archive expansion.
Compare source/destination physical extents and actual free space; stop at
4.5GiB free or exhausted eligible targets. Preserve current failures.
If the bounded native sharing produces no meaningful savings, reassess without
touching unrelated user data or the active CLI session database. That database
was inspected read-only (no free pages); no maintenance/write was performed.

Compile3GiB, stage2.75GiB/stop1GiB, model gates and all C1 correctness constraints
remain unchanged. After storage is available, execute frozen R6 affected checks,
standard release/sign/current controls/freshG4/real scroll, then continue the
authorized natural-conversation and50ms-target work. This is storage retention,
not a claimed product speed improvement or a substitute for R6 verification.
