# Native Field Context

G1 APPROVED: user selected Approve Role Metadata and Approve Listed
Cleanup. Independent senior plan review 51fbb72e PASS. Implementation
is complete after the approved cleanup restored the unchanged 5 GiB
build floor. Focused313 checks and fresh consumer source review pass.
The signed pilot succeeds, but the interrupted/resumed command set is
2/3 for both baseline and candidate. No reliability or speed gain is
established. P4 remains FAIL/open; no daily installation.

## Pre-Implementation Evidence And Hypothesis

The signed replacement comparison is strict 0/3 before and 1/3 after,
although all six exact native values are correct. The failed candidate
trials reach the three separate replacement-intent judgments. Target
confidence stays below the unchanged .95 gate.

Source at the time of this plan retained a field's role, label, value, rectangle, native
identity and original document association, but loses its container
relationships:

- `NativeWindowObservation.collect` traverses native AX children but
  stored only `(node, level)` in its queue. `FieldValue` had no ancestors.
- `TaskLoop.AXElement` had no parent or native ancestor context.
- `ObservedGoalProof.Fact.json` sent the field role and full-value
  provenance, but no native container roles.
- `DriveCandidates.axSnapshot` uses SDK parent indices to restrict the
  window, then converts to the flat element type. That does not preserve
  hierarchy for the model.

Consequently a native body field and a native toolbar field can lose the
relationship that distinguishes them. This is a confirmed information
loss in source, not proof that it causes the model's low confidence.
The hypothesis is that supplying the missing native role relationships
improves target judgments without relaxing safety or changing questions.
The signed A/B must test that hypothesis; no success is promised.

## Narrow Change

Retain optional `nativeAncestorRoles` on private AX elements and native
field observations. During the existing native tree walk, carry the
observed ancestor roles from the bound root to each node. Reuse the
already-read roles and children: no additional AX calls, model request,
per-action provider or app-specific setup.

This is an observed root-to-parent role chain, not a canonical-parent
claim. It contains roles only, never ancestor labels, text values,
document paths, tokens, native handles or inferred words such as "body".
Do not manufacture a document-body flag from `AXScrollArea`.

SDK or previous-observation metadata cannot acquire this provenance:
clear incoming ancestry on every merge. Publish native ancestry only
from the verified bound native root with complete, valid scope. Editable
fields also require the existing unique field/frame/native-identity
association; read-only rows must originate in that native root's own
walk, not an SDK row. Missing,
malformed, foreign, secure or unbound data yields nil, not a guess.
Secure subtrees remain excluded. Do not add an action filter.

Expose the optional role chain in the existing fact JSON as UI evidence,
not authority. Carry it into `ObservedGoalProof.Node` so a hierarchy
change after a judgment invalidates that proof on fresh readback.
Existing nil/default callers continue to work; ancestry is not a new
mandatory gate or a substitute for native identity/document binding.

## Unchanged Contract

- Keep all three independent intent judgments at finite, pinned .95.
- Keep original set_value selection at its existing .9 floor.
- Keep the actual loop-owned executed-replacement receipt.
- Keep whole native field equality to the actual caller literal.
- Keep original document and native CF field identity.
- Keep fresh complete native readback and context comparison.
- Keep conflicting broad negatives, secure/unknown/ambiguous rejection.
- Keep the existing general proof and already-satisfied paths.
- Do not move intent votes before execution or reuse old model answers.
- Do not add permissions, app recipes, flags, focus stealing or a round
  ceiling. Do not change MCP, driver, model or provider contracts.

Adding optional private observation/fact metadata required a D9
Decision Log amendment and review of all consumers. D9a and the fresh
consumer review now satisfy that requirement; the frozen evidence
interface was not changed silently.

## Owned Files

Production: `Sources/JevVoice/Drive/TaskLoop.swift`,
`Sources/JevVoice/Drive/NativeWindowObservation.swift`,
`Sources/JevVoice/Drive/ObservedGoalProof.swift`. Adjust a conversion only
if needed to retain/clear provenance correctly. Do not change the chooser
questions, replacement proof thresholds or the Cua source.

Tests: existing native observation, observed proof, chooser/decider and
TaskLoop consumer suites under `Tests/JevVoiceAppTests/`. Harness and
evidence: `.agent/results/P4/`, plus the D9 Decision Log and progress.
Tracker, settings, daily app and unrelated worktrees are not owned.

## Proof Before Implementation

After plan approval and sufficient disk space:

1. Write fail-first checks for native role-chain propagation into the
   exact production chooser state, not a copied implementation.
2. Cover foreign root/window, incomplete native walk, SDK-forged or
   carried-over ancestry, secure ancestry, unknown data and legacy nil.
3. Cover a hierarchy change on the same native field/document after
   model judgment: the old proof must fail fresh verification.
4. Confirm original receipt, literal, scope, target, document, field,
   model and threshold negative controls remain unchanged.
5. Count native AX reads in the seam to verify no new platform calls.

Run focused checks through the serialized lane. Review every consumer:
native reader/merge, AXElement/AXSnapshot conversions, goal facts and
context, chooser/decider, TaskLoop proof verification, and voice,
computer-control and read-only preview callers.

Then stage, sign and verify an isolated candidate. One owned TextEdit
pilot first. If still blocked, preserve the failure and do not blindly
repeat it. If the pilot passes, run three matched baseline/candidate
trials on the same unsigned coordinate driver payload, same owned
document, goal, literal, native oracle and timing method. Preserve all
failures. Compare strict success and native result separately. Measure
request size and command time; print regressions. One pilot is not
reliability or latency proof.

Re-run only the product evidence affected by a successful change.
Spotify playback remains off limits while local routing is unproven.
No daily installation or release follows automatically.

## Build-Space Blocker

The latest observed free space is about 1 GiB, below the unchanged 5 GiB
build floor. Do not start compilation or weaken the guard.

Before any cleanup, request approval for exact paths. Preserve current
signed 890 bundles, the required 9b resource/archive base, the shipped
driver, SDK and runtime libraries, all receipts and evidence. An obsolete
633 baseline may be archived only with exact reconstruction/signature
verification before removal. Regenerable build/package caches are not
product evidence, but still require explicit deletion approval.
Do not promise apparent directory sizes will become free APFS space.

The proposed deletion scope, not yet approved:

- `/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/build/vision-capture-045/release/build`
- `/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/build/vision-capture-045/release/deps`
- `/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/build/vision-capture-045/release/.fingerprint`
- `/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/build/cargo-045`
- `/Users/karanvirkang/Documents/code/jarvis-v1-agent/.build/arm64-apple-macosx/release/ModuleCache`
- `/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/jev-vision-ab-cq9z1o3s/before.app`

The first five paths are regenerable compiler/package caches, not
source or acceptance evidence. Locked Cargo packages may need a fresh
download for a future Rust rebuild; this Swift-only change does not
require one. Preserve top-level `release/cua-driver`,
`release/libcua_driver_sdk.dylib`, `release/libuniffi_runtime_napi.dylib`
and the other top-level release outputs. Verify preserved runtime output
hashes before and after cleanup, and ensure no process is using any
selected cache.

For the last path, archive relative to the retained verified 9b base,
reconstruct outside the synced checkout, compare every file/mode/link
and verify the original strict signature before removing the original.
Do not re-sign it. All new archives/manifests/output stay inside the
JevVoice workspace. Keep both 890 bundles and all older archive bases.
If actual free space still falls below 5 GiB, stop before compilation.
This approval would not authorize deleting anything else.

## Packaging Repair Within The Approved Pilot

The native change passes 313 checks and fresh source review 6cc7d424.
The first normal staging run exits 75 under the unchanged space guard.
Its before bundle verifies, after bundle does not; no actor ran.
The failure log, source/unsigned Main and diagnostic hashes are retained.
Only that run's newly created unused staging files may be removed.
Historical 890 candidates, 9b base and all actual command runs stay intact.

The existing stager rebuilds a full resource tree and recursively
re-signs every embedded Mach-O. This is unnecessary for a Swift-only
source comparison and risks including unrelated resource changes.
Repair the private staging harness, not the model or product contract:

- Add an optional frozen-baseline receipt mode to the existing
  `jev-vision-stage.py`. Ordinary full staging remains unchanged.
- Validate the reviewed source delta, cached native artifacts and both
  existing baseline signatures. Rebuild the same reviewed Swift source.
- APFS-clone the matching baseline variant. Replace only Main.
  Remove detritus only from that new Main, never baseline/resources.
- Use the existing signing identity; never mint one or re-sign nested
  runtimes. Sign the root app only, preserving baseline signing flags,
  entitlements, designated requirement and all Info.plist bytes.
- Compare full file/mode/link manifests before and after. Only Main
  and `Contents/_CodeSignature/CodeResources` may differ. Verify deep
  strict signature and identical driver signed/unsigned identity.
- Persist signed build apps, manifests, receipt and logs in the native
  workspace. Temporary signing/runtime copies outside the synced tree
  remain necessary for the documented macOS signing tripwire; bind them
  to the workspace apps by exact manifests.
- Write fail-first payload/source/signing-policy guards, then implement
  this mode. Review the harness change before staging. Same 5 GiB guard.
  Only then run the already-approved native pilot; do not expand trials.

No app recipes, settings, permissions, model questions, driver binary,
daily install or public MCP changes. Owned harness/test files stay in
`.agent/results/P4/`; the existing serialized lane invokes the stager.
