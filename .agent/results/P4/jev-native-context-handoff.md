# Native Context Handoff

The approved metadata amendment is implemented and source-reviewed.
P4 remains FAIL/open. It has not demonstrated a reliability or speed
gain. Nothing is installed over the daily app; no acceptance record,
release, commit or push is part of this work.

## Actual Signed Commands

| Subject | Strict successes | Exact native body | Return times, rounded up |
|---|---|---|---|
| Retained890 baseline | 2/3 | 3/3 | 2.162, 2.364, 1.794 seconds |
| Ancestor-role candidate | 2/3 | 3/3 | 2.021, 2.086, 3.260 seconds |

No false Done occurred. A separate successful pilot takes2.016 seconds
and is excluded from those scores.

The original comparison stops before its last candidate command at a
native-readback preflight refusal. One candidate-only continuation runs
without replaying the five completed commands. Before that continuation,
the harness adds failed-read diagnostics only. Its hash therefore differs.
This is an interrupted/resumed command set, not an uninterrupted
unchanged-harness qualification. All failed attempts remain in the report.

The candidate's failed command replaces the body correctly, cannot
ground the next AX step, then switches to visual verification and blocks
because independent completion evidence is insufficient. Its retained
visual trace reports selectedP0.72, targetPresence0.81, boxConfidence0.31.
These values are not a reason to lower any safety floor.

Earlier evidence remains earlier: native candidate1/3 vs baseline0/3,
visual0/6, everyday-app pilots0/5. Image/everyday behavior is not freshly
qualified on the ancestor-role source. Spotify routing/playback remains
unproven; no new Spotify action ran. The labelled Notes fixture stays.

## Source And Checks

Exactly three of104 product-source hashes differ from retained890:
TaskLoop.swift, NativeWindowObservation.swift, ObservedGoalProof.swift.
Optional native roles are cleared from SDK/stale input, populated only
by complete bound native observations, emitted as UI facts, and included
in fresh proof equality. Nil callers and all existing receipt, literal,
document/field identity, semantic and fresh-readback gates remain.
No new model request, AX API callsite, question, threshold, action filter,
permission, app recipe or driver/SDK change.

- Fail-first production seams, then313 focused checks pass.
- Emptying actual fact ancestry serialization causes three real chooser/
  capture/fact failures; restoration passes313 again.
- Fresh6cc7d424 reviews all observation/proof/voice/control/preview consumers:
  SOURCE PASS. The lossy action projection is not the fact/proof path.
- Private staging/runtime/inspection/report guards pass52 checks after
  fail-first failures. Fresh37e0a926 reviews each changed area: PASS.
- Senior51fbb72e reviews both the metadata and packaging plans: PASS.

Actual per-CF-call instrumentation, model request count and request
bytes were not retained. A capture seam proves one native observation;
source review proves no additional AX/model callsite. Do not broaden the
synthetic-only private model trace guard to collect user application data.

## Artifacts

Native output root:
`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/staging/vision-pinned-owner-20261110.artifacts`

- `p4-current-evidence/report.html` and `evidence.json`: reviewed JSON-backed report.
- `native-ancestor-frozen-stage/stage-receipt.json`: canonical signed apps/manifests.
- `native-ancestor-source-delta.json`: all104 source hashes and fail-first/mutation log hashes.
- `native-ancestor-pilot-r3`: successful pilot.
- `native-ancestor-matched-ab`: interrupted comparison, including zero-actor refusal.
- `native-ancestor-matched-resume`: one remaining candidate command, blocked with exact body.
- `native-ancestor-readonly-inspect-r4`: scoped native readback and synthetic-window screenshot.
- `native-ancestor-stage-interrupted.json`: failed full-stage diagnostics; no actor ran.

New frozen staging clones the retained variant and signs only the root
app. Only Main and CodeResources bytes differ; nested resources/driver
signed bytes, Info.plist, modes, links, entitlements, flags and designated
requirement remain identical. Both variants pass strict verification.
Canonical apps stay in the native workspace. Exact-manifest temporary
execution copies outside synced Documents close after owned processes.

Keep both890 variants and the full9b archive base. The five approved
caches and obsolete633-before are already removed under explicit user
approval. That bundle was reconstructed exactly and its original
signature verified before deletion; archive index:
`/Users/karanvirkang/Documents/code/jarvis-v1-vision-driver/development/JevVoice/staging/native-context-approved-633-archive-r2.artifacts/index.json`.
Only newly created unused staging scratch was otherwise removed.
The five-GiB build floor is unchanged.

## Remaining Gaps

Intermittent preflight readback refusals remain unexplained. Readiness
telemetry now records the existing predicates without changing the body
oracle or retrying. Healthy diagnostic and continuation reads have
matching SDK/native ownership, no truncation/degradation and exact text.
Do not claim this explains or fixes the earlier refusals.

No further blind native replay or prompt/threshold tweaking is justified
by this amendment. Safe native settlement, image grounding and everyday
qualification remain separate open problems. Physical Fn, microphone,
gaze, daily GUI, human try and release proof remain missing.
