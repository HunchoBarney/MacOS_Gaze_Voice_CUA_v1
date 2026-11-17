# C1 R7: reuse verified native scrolling

Status: G2 PASS42753e08, fourteen criteria met, no blocking findings.
Approved before R7 production edits.
G1 is the user's continuing C1, natural continuous voice and speed authorization.
R7 preparation reviewer42753e08 recommended this approach; that preparation was
not implementation approval. One implementation owner, read-only reviewer.

## Reproduction and cause

R6 source/artifact G4 PASS42753e08 remains valid. Signed main db36d3a487c6f8cffc984c2ede8fd5ac9af92944446e3c16e2c4a8b29091fdb8,
at ~/jarvis-local/c1-candidates/jev-c1-final-r6-rbcx83ar/Jev Voice.app.
Frozen214input manifest b8593a83376211c00471cfbea5ce7a32752807d18f482873451982daa9743e09.

Unchanged live workload c1-scroll-r6-support/{comparison,results,decision-trace}.json:
viewport0->0.21046643913538113 in the owned window, body/decoy unchanged,
documents restored, task STUCK lowConfidenceTwice. One trial, then stopped.
First selection/support both0.93; later completion0.07-0.13 and weak support.
MCP response2984.927ms; independent witness5085.866ms. These are failed-task
timings, not a successful speed baseline. Accepted votes do not count inputs.

CuaDriveServer331 sets windowOnly for pinned windows. DriveLoop614 skips all
fast paths in that mode. The generic scroll branch1927-1942 accepts only a
driver-confirmed effect; Cua cannot supply the independent viewport proof.
FastLaneExecutor954-1117 already implements that proof from native AX, including
target identity, direction, freshness, region binding, stable readback and no
uncertain retry. Reuse it rather than introducing another goal-proof protocol.

Conversation interpretation already supplies direction/amount/scope. Ordinary
scrolls are then sent as original text through a grammar-based fast-path lookup;
only continuation currently has a special route. Natural wording can therefore
fall into the same generic completion gap. Preserve the original request while
passing typed parameters to the existing verified executor.

## Owned paths

Production, all in Sources/JevVoice/:

- Drive/FastLane.swift
- Drive/DriveLoop.swift
- Drive/FastLaneExecutor.swift
- Drive/VoiceTaskCoordinator.swift
- Voice/ConversationContext.swift
- Voice/VoiceSemanticRouter.swift
- Voice/VoiceController.swift

Existing tests:

- Tests/JevVoiceAppTests/DriveLoopTests.swift
- Tests/JevVoiceAppTests/FastLaneExecutorTests.swift
- Tests/JevVoiceAppTests/VoiceSemanticTests.swift
- Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift

Packaging: final-r7 label only in scripts/verification-lane.sh and
.agent/results/P4/jev-stage-candidate.py. Existing evidence/contract/handoff
documents and R7 output files may be added/updated. Frozen R6/R5 evidence stays.
No changes to public MCP/DriveTask DTO, TaskLoop, ObservedGoalProof, dependencies,
driver/model bytes, request thresholds, microphone/VAD/ASR, settings or C2/Terra.

## Implementation contract

1. Permit an exact whole-utterance primitive scroll through windowOnly.
   This exception is limited to a single bounded FastAction.scroll, no open
   verb, launch URL, display selection or deictic retargeting. Require a positive
   pinned window, work scope, no caller values, additional successContains,
   named-window conflict or preceding user context that could add an end condition.
   Full parsing must retain direction/amount. Compound/conditional/quoted/negated
   or unsupported amounts keep their original generic workflow. Do not enable
   global/system/media/open/navigation/app-control/type/key paths in windowOnly.
   The compiled whole-utterance primitive establishes this narrow goal shape;
   no model confidence is synthesized and no app allowlist is introduced.
2. Add an internal immutable WindowScrollRequest beside the existing fast action
   types. It carries original goal text, captured canonical application/window,
   direction, and the existing small/normal line amount (1/3). It conveys semantic
   intent, not a grant. Matching requires the same full goal (only existing outer
   whitespace trim), app and window, work scope, no values/additional postconditions.
   Do not convert speech to a canonical string and then reparse it.
3. Batch one independent bounded_window_scroll Noul with the current conversation
   questions. It asks whether one small/ordinary movement in the current window
   completes the ENTIRE current instruction in context. Require existing0.90
   threshold plus existing complete/addressed/scope/direction/amount/support
   judgments. No new serial model call. The question supplies its full meaning,
   not just its ID. False for region/sidebar requests, exact units/counts/pages,
   until-X/visible-item requirements, compound/hidden/persisted goals, negation,
   reported/quoted/example/status-only commands and any unrepresented condition.
   A bounded affirmative can produce WindowScrollRequest only for an observed
   pinned window. Other valid requests keep the full original generic task and
   scope; uncertainty is not an invented default amount or region.
4. ConversationDecision carries the optional typed request. VoiceController passes
   it with the unchanged command text and existing admission/epoch checks.
   VoiceTaskCoordinator stores it on Work, rejects changed text/scope/constraints
   before admission and again before execution, and invokes a typed DriveLoop
   window-scroll entry. Do not inherit/replay it through a generic repeat request.
   Existing verified continuation, spoken stop, playback isolation, ask handling,
   late cancellation and exactly-once ownership remain intact.
5. The typed entry follows the existing runAppFocus pattern: validate the bound
   task, resolve its real app/pid, then use the existing fast executor and native
   viewport reader. It never falls into a generic loop after a possibly dispatched
   request. Thread the typed1/3line amount directly to runVerifiedScroll; preserve
   its ordinary grammar behavior for old callers. Raw goal/transcript stays in
   evidence and policy context. Single typed scroll means one dispatch.
6. For the newly admitted pinned scroll paths, require an actual unique window row
   with the expected pid/window and any supplied title constraint before input.
   Empty/foreign/ambiguous rows must not pass merely because a windowID was supplied.
   Reuse existing resolver and window helpers. Preserve standing grant/per-task
   confirmation, task deny list, protected-target checks and cancellation. Do not
   launch a replacement or choose another window if the original disappears.
   Preserve native region/token binding, same-target/direction/freshness checks,
   two stable read generations>=30ms apart,40ms polling and0.75s bound. No accepting
   driver acknowledgements, model votes or feedback as viewport evidence.

## Failure controls and verification

Before production edits, add and run existing-surface regressions for pinned
scroll missing the native lane and a weak bounded-goal judgment being ignored.
Then write the new typed-API controls before implementing that API. An absent API
compile error is not called a behavioral red test. Preserve the signed R6 failure.

Required controls, in the existing test files:

- Same owned pinned window, fresh positive movement, exactly one scroll, no
  unnecessary chooser call on the deterministic native primitive.
- Empty/foreign/duplicate window rows, stale/changed app/window/document/region,
  wrong direction, missing native evidence or driver acknowledgement cannot succeed.
- Agent-authored scroll still needs standing grant/per-task confirmation; deny
  and protected-target refusals produce no input. WindowOnly still excludes all
  non-scroll fast lanes and extra postconditions/context cannot be discarded.
- Ordinary natural equivalents preserve original words and typed direction/amount.
  Weak/malformed bounded support cannot become a native request. High selection
  cannot compensate for0.89independent support.
- Sidebar, until-visible, exact pages/counts, compound action, hidden/persisted,
  quoted/status/negated and changed-goal/changed-scope cases never become a plain
  one-movement completion. Existing generic workflow retains the original request.
- Cancellation during async work invalidates admission; no replay through repeat,
  old conversation epoch, uncertain dispatch or a late result.
- Existing continuation preserves its independently witnessed region and amount;
  this change does not alter its loop/pacing/stop policy.

Use the serialized affected release consumer lane with DriveLoopTests,
FastLaneTests, FastLaneExecutorTests, VoiceSemanticTests, VoiceTaskCoordinatorLaneTests,
VoiceLaneAuditTests, RealtimeVoiceLaneTests, VoiceTurnEvidenceTests,
JevChooserTests, JevObservedGoalTests, JevExactReplacementTests, JevAdaptiveTests,
JevDeciderTests, TaskLoop, DriveSessionCursorTests, GazeLaneTests/GazeRefusalStateTests.
No unrelated full1434+234 repeat. Freeze sources before building. Standard production
release after testable checks, final-r7 separate staging, current8package controls
and manifest, fresh G4, unchanged c1-scroll.py against the exact signed receipt.
Same300-line documents, oracle and clocks, no weakening and stop at first failure.
Record movement magnitude as well as latency: R6's generic page-based behavior and
the existing native1/3line primitive differ; do not portray that as a matched pure
speed win. A completed native primitive must report verified completion.

Natural-language behavior needs evidence beyond a literal MCP phrase. Use the
production semantic request factory in an opt-in real-Jev probe in the existing
VoiceSemanticTests, retaining exact state/questions/answers/outcomes for a frozen
small paraphrase and negative-case set. Capture before and after once; no rerolls.
This is semantic integration evidence, not microphone or native-action proof.
Reuse existing real recordings where they contain suitable commands. If no
recorded natural-scroll workload exists, keep physical conversation open and
prepare one brief normal-app check on the final artifact; do not manufacture audio
or add a test-only product command path and call it normal voice.

## Resources, review and handoff

Keep R6 signed as before/rollback; daily/baseline/R5 and archives unchanged.
Compile3GiB, staging2.75GiB, emergency1GiB guards remain. Reuse cached dependencies,
one compiler job and existing staging. Do not reclaim new categories or alter
protected artifacts as part of this source contract.

Record the internal typed coordinator/driver seam in CONTRACTS and re-review all
listed consumers. No public frozen DTO change is needed. G2 approves this contract;
G4 must inspect actual source/current artifact. No acceptance flag changes here.

Enliven native adaptation reuses the existing harness, LatencyLedger and report.
TypeSafe live Noul, fan-out and function-calling guidance has been read.
Native dispatch, semantic interpretation, VAD/ASR, full speech-end-to-effect and
human input evidence remain distinct.250ms VAD and post-seal recognition are
subsequent measured performance work, not fixed by R7. No50ms claim is authorized.
