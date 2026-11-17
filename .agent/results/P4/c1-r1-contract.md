# C1 R1: close demonstrated runtime and evidence gaps

G1: the user's renewed “make sure c1 is done double check everything”
continues the authorized C1 repairs. This R1 contract requires independent
G2 before production edits. One implementation owner. No commit, push,
merge, distribution or replacement of the daily f6 app.

G2 prospective contract **PASS**, independent read-only reviewer
`831d8a6f`. The first response applied G4 implementation criteria before
implementation; after clarifying the repository's gate order, the reviewer
returned terminal prospective G2 PASS for R1 A/B/C, scope and consumers.
This does not mark source repaired or grant G4/phase acceptance.
Exact original-byte snapshot:
`c1-r1-baseline-0a8cc3bb/manifest.json` (15 existing owned files; new
JevObservationPayload.swift recorded absent).

The added hands-free conversational feature is recorded in
`c1-closeout-state.md`. Its changed audio/authorization contract needs a
concrete separate R2 G2 amendment after examining the existing capture
and endpoint APIs. R1 source work can proceed while that design is
prepared. No new speech semantics, model promotion or Terra integration
is authorized by R1.

## Current truth and reproductions

Baseline is the c292 source and signed candidate, not Git HEAD. Save
exact original bytes for every R1 owned file before editing. Retain c292
as the prior candidate and all existing reports.

1. Real Fn turn 656FA76B in `c1-physical-691cfc93d2` has a blocked scroll,
   driverFailed, no dispatched effect, but recorded voice status Finished.
   VoiceController.receive(.turnEnded) calls complete without waiting for
   its work. cuaChanged refuses to re-project .done unless an ask exists,
   and flushes evidence before projection. ContentView uses .done directly
   until idle. Reproduce that owned-work lifecycle before repairing.
2. FastLaneExecutor's scroll branch ignores the result and returns done
   after the RPC, without a before/after viewport witness. The user's next
   scroll returned done, but the live row alone is not independent proof.
3. The retained before5/final5 MCP case reaches Jev and gets HTTP400
   max_tokens_exceeded. Unified logs show identical requests:
   **state 204468 bytes, questions 144125 bytes, 28 questions**, at
   2026-11-15 19:49:03 and 19:49:28 local. JevChooser embeds full fact JSON
   in Choice criteria in addition to the state and repeats observation
   text across candidate/fact structures. No usage cap caused this.
4. Normal voice “Add seven plus six” and “Keep scrolling” produced
   semantic.no_match then the legacy remote-reasoning path. They are
   retained as current capability gaps. Do not delete them or declare
   control success. Conversational routing/continuation is addressed with
   R2, not by inventing successful work in the presentation repair.

## Owned files and consumers

Production:

- Sources/JevVoice/Voice/VoiceController.swift
- Sources/JevVoice/UI/VoiceStyle.swift
- Sources/JevVoice/Drive/FastLaneExecutor.swift
- Sources/JevVoice/Drive/NativeWindowObservation.swift
- Sources/JevVoice/Drive/DriveLoop.swift
- Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
- Sources/JevVoice/Drive/JevChooser.swift
- Sources/JevVoice/Drive/JevObservationPayload.swift (new, only if the
  lossless request adapter cannot stay small/clear in JevChooser)

Tests and existing harness:

- Tests/JevVoiceAppTests/VoiceLaneAuditTests.swift
- Tests/JevVoiceAppTests/RealtimeVoiceLaneTests.swift
- Tests/JevVoiceAppTests/FastLaneExecutorTests.swift
- Tests/JevVoiceAppTests/JevChooserTests.swift
- Tests/JevVoiceAppTests/JevObservedGoalTests.swift
- Tests/JevVoiceAppTests/JevExactReplacementTests.swift
- Tests/JevVoiceAppTests/JevNativeChoiceDiagnosticTests.swift
- scripts/verification-lane.sh
- Existing .agent/results/P3/P4/P12 C1 harness/report files and new
  scoped evidence, original-byte snapshots and receipts
- .agent/SHIP-PLAN.md, .agent/PROGRESS.md, .agent/CONTRACTS.md and owning
  P3/P4/P12 phase notes

Affected consumers: normal Fn/pill and typed command presentation,
VoiceTurnEvidence/normal qualification, both FastLane executor factories,
native/mixed drive loops, chooser goal/exact-replacement consumers,

2026-11-16 consumer-scope reconciliation for final review: the full Swift
lane reproduced eight stale assertions across five cases in the existing
DriveSessionCursorTests.swift, GazeLaneTests.swift and
GazeRefusalStateTests.swift. Include these three test homes in R1 ownership.
They retain session/window checks, require an unverified result without native
viewport evidence, and prohibit gaze dispatch without fresh window/region
binding. No transport success is manufactured into viewport proof. The edits
preceded this bookkeeping update; this is not a claim of earlier prospective
approval. The source behavior stays within already approved R1 ownership.
packaged MCP and signed candidate provenance. Read supporting files;
no other source edits without an amendment. Do not touch EyeTracking or
the FluidAudio checkout.

## A. Project actual owned-work outcomes

Turn end closes speech transport; it cannot prove the task succeeded.
Keep current owned work visibly working until settlement. A blocked,
failed, uncertain or cancelled owned attempt must not become Finished.
Pending asks stay reachable. Done/alreadyDone may complete only from the
current interaction's actual outcome. Dialogue-only replies can finish
their reply, but no empty fallback may invent a performed action.

Use the existing capture-ID ownership and state projection; do not bind
to task-list recency or the diagnostic task selection. Preserve active
capture/dictation, asynchronous reply streaming, old-turn isolation and
unrelated background work. Derive evidence's terminal presentation from
the same owned outcome, including when an older turn settles after a
new capture began. Avoid calling microphone failure/cancel merely to
show a task failure.

Failure cases, before code:

- turnEnded while owned work runs; owned work subsequently blocks;
- a blocked response before/after turnEnded; unknown/uncertain effect;
- old/unrelated work settles while a new capture or dictation runs;
- late cancellation, pending question/approval, and valid completed work.

## B. Ground scroll completion in fresh evidence

Reuse native AX facilities and existing driver observations before adding
product glue. Capture a scoped viewport witness before a scroll and read
it again after dispatch/settlement. Bind PID, window, native document when
available, region identity and direction. Prefer actual scrollbar values
or visible text ranges/viewport offsets; preserve the original values.
No mock acknowledgement may become a successful viewport witness.

The dispatch location and the witnessed region must be the same intended
region. A gaze point outside the authorized captured window cannot silently
redirect the operation. Check existing driver scope arguments and runtime
contracts before wiring a point; no new driver pin or unsupported argument.

If native evidence is unavailable, preserve the generic action capability
but report the dispatched effect as unverified/uncertain. Do not retry a
possibly performed scroll, return done from an empty reply, or substitute
changed pixels from an unrelated region. Existing visual verification
may be reused only with its independent authority and binding contracts;
otherwise this R1 cannot claim verified fallback coverage.

Failure cases: unchanged viewport, already at edge, wrong direction,
wrong region/window/document, stale target, cancellation before/after
dispatch, missing AX capability and an uncertain dispatch result.

## C. Remove redundant Jev request content without dropping evidence

Use the existing JSON/platform structures and Jev client's API. No new
SDK, compression proxy, long-context header, model or lowered threshold.
Current TypeSafe state/Choice docs support named structured state and
explicit backticked references. Full fact JSON need not be duplicated
inside its Choice description: point to the identified fact in state.

For remaining repeated long observation strings, a small lossless
request-only adapter may intern identical UTF-8 content once and replace
its occurrences with explicit structured references. Explain the reference
meaning in affected questions. Preserve every fact ID, target/relationship,
ordering, literal byte sequence, requirement and provenance. Keep original
uncompacted facts for trusted local proof and action dispatch. No truncation,
summarization, reduced candidate population or manufactured probability.
Only apply sharing when it reduces the request; unchanged small requests
should retain their ordinary shape.

Prove exact round-trip restoration and prevent collisions between user
content and reserved reference metadata. UTF-8 identity matters: Swift
String canonical equivalence is not a byte-identity test. Check composed/
decomposed Unicode, escaping/newlines, long values differing only at their
ends, repeated content in distinct document/field identities, no-match
subjects and exact/hidden-state counterexamples. Comparison must demonstrate
that shrinking the body did not erase a relevant distinction.

Run the retained 300-line owned-window workload through the real model and
packaged front door. Record before/after bytes and actual outcomes.
The before was blocked, so after success cannot support a latency percentage.
If lossless sharing is insufficient, stop that hypothesis and return with
actual request structure; do not trim the failing workload.

## Verification, reuse and candidate

Reuse current C1 release/native/MCP harnesses, existing speech recordings,
LatencyLedger, macOS AX and the pinned Jev/Cua/FluidAudio infrastructure.
The native chooser diagnostic already captures exact owned inputs; retain
its ownership/marker guards when adapting it. Request sharing is small
product representation glue, not a replacement inference framework.

Capture failing-before controls in suitable existing tests, then run
changed consumer populations through verification-lane. Real desktop
work takes the desktop lock and owns only labelled fixtures. Preserve
the active normal app/evidence; stop only the identified candidate when
idle and needed for a serialized controlled run. Never overwrite daily.

Jev usage is unlimited under this user's setup. Keep service request-size,
cancellation and no-progress controls, and existing separately billed
service controls. No new paid-model experimentation.

Bound diagnosis to three hypotheses at once and three failed attempts per
hypothesis before reassessing. Build/test runs and independent review do
not consume a speculative-command budget. Do not repeat unaffected full
lanes per patch.

At the coherent new candidate boundary run affected integrated gates and
the required full lane, stage/sign outside synced Documents with the
existing checked helpers, and get fresh G4. Retain all failed attempts.
Report raw/matched clocks, sample sizes, regressions and unproven goals.
Only the authorized fresh judge may change acceptance flags on proof.

## R1 completion checks

- Own blocked/uncertain/running work never presents a verified finish,
  and old/unrelated work never controls current capture.
- Scroll success has a fresh target-bound directional witness; otherwise
  status honestly reflects no effect/unknown effect without blind retry.
- The exact retained large-input case no longer hits max_tokens_exceeded,
  with all relevant content and independent requirement semantics preserved.
- Existing exact/hidden-state, document identity, dwell, permissions,
  cancellation and exactly-once protections still hold.
- Current source/artifact/report identities and remaining physical,
  speech, competitive and R2 gaps remain explicit.

## R1 D prospective amendment: native primitive support

G2 prospective PASS from independent read-only reviewer3241c688.
Pre-D source bytes: c1-r1-d-before-a642ec40/manifest.json. A/B/C remain authorized.
Source review found another instance of C1's D121 boundary:
JevChooser currently discards low action_support for press_key, hotkey,
scroll, invoke_menu and media key. Its comment calls the step Choice the
legitimacy evidence. JevDecider forwards the resulting request; downstream
deny/consent controls do not independently establish the requested
direction/region/operation. An existing test explicitly expects a0.74
support judgment to authorize a selected key.

Decision: operation selection cannot replace an independent step-validity
judgment for window/viewport/system operations. Keep the existing0.9
support threshold for every offered primitive. Clarify the support
question so its target may be a control, window, viewport or system state;
scroll direction and region must follow the request. No probability,
threshold, model or public DTO change.

Owned source: JevChooser.swift only, already owned by R1.
Owned tests: existing JevChooserTests.swift; adjust the old bypass test,
add direction/scope counterexamples, retain positive strong-support cases
and update the exact question-contract expectation. Existing
JevDecider/TaskLoop/native/visual consumers require G3 recheck; no source
edits outside R1 ownership without another amendment. Existing R1 bytes
plus a pre-D source snapshot and failing-before log bind rollback.

Completion: low independent support cannot produce an executable key,
scroll, menu or media pick despite high step Choice; strong valid support
still permits it; wrong direction/region is rejected without changing
untrusted observations into authority. Retained live scroll must still
work on the final candidate. G4 reviews D together with A/B/C and the
candidate. R2 continuous input remains a separate structural G2 contract.
