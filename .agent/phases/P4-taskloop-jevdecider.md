# P4 — taskloop-jevdecider ExecPlan

> Status: open; recorded source milestones pass, full live/latency and latest-candidate independent qualification remain incomplete
> Track: agent+voice · Depends on: P1 · Original work: `ship/v1-p3`; see SHIP-PLAN for current placement
> Acceptance: `.agent/acceptance/P4.json` · Contracts touched: CONTRACTS §1 `Decider`/`TaskLoop`, §2 `CaptureSource` (implementation of frozen v0 interfaces; amendments need Decision Log entry)

## Shipping update — 2026-11-15

`.agent/SHIP-PLAN.md` is the current delivery sequence. P4 remains 4/6;
P4-5 and P4-6 have not passed. The original implementation Context below
is historical; preserve the working refactor and review the current
delta rather than implementing it twice.

C1's P4 scope is shared evidence/observation/dispatch, not speech, the
general planner or the whole browser product. New source work requires
G1/G2 and the CONTRACTS shipping review queue:

The latest model direction keeps Jev primary and Cua/native execution.
P5 supplies Terra API recovery only when needed. Direct grounded actions
need no extra Jev/Terra gate; Jev image/Box qualification and independent
presence/identity/authority/consequence requirements remain intact.
Use COMPETITIVE's Jev-only versus hybrid reporting, never count recovered
tasks as proof that Jev alone passed its frozen P4 slice.

1. Reproduce D121's correlated exact/hidden requirement discharge and
   review D120 scroll authorization against wrong region/direction/scope.
   Preserve independent judgments or use actual authoritative facts;
   do not synthesize scores, weaken gates or retune until a fixture passes.
2. Attribute native/driver/capture/model/settle/verify/queue time using the
   existing LatencyLedger. D121 has 14.271–15.709s outside logged visual
   inference; it is not proven driver-only delay.
3. Remove measured duplicated work without dropping independent native
   evidence, generic screenshots, target freshness or cancellation.
   Reuse a capture for the same state; a fresh state after mutation is
   still required to establish an effect.
4. Produce a reviewed contract/source handoff for P5/P7 implementation.
   Keep full P4 qualification open until the frozen slice and fresh judge
   pass. Do not move failing tasks into another phase or call another
   model's result Jev qualification.

The S-VISUAL <=500ms p50/<=1s p95 goal in PROGRAM is aspirational and
strictly separate from P4's unchanged >=95%/<=4s acceptance criterion.
Keep every failed/blocked row visible. No arbitrary default round ceiling;
bounded no-progress recovery and caller budgets remain supported.

### C1 checks and evidence

`scripts/verification-lane.sh p4-explicit-decision-consumers` is the
current affected-consumer suite; `scripts/verification-lane.sh all` is
the integrated candidate gate. Expected: contradictory requirement,
wrong target, stale subject and canceled-turn cases refuse; legitimate
native/visual cases retain independent completion. Expand the existing
JevVision/TaskLoop/observation tests for a demonstrated gap, not another
duplicated suite.

Use the existing real-app harness in `.agent/results/P4/` under the
desktop lock and authorized budget, with matched candidate/oracle inputs.
The report records current source/driver hashes, all failures, request
counts, payloads, timing and remaining G5/G6. Stage one coherent candidate.

## Reuse decision

Use the existing pinned Cua driver, direct native evidence, TaskLoop and
measurement harness. Reconcile the separately staged 0.45.4 driver/SDK
before any promotion. Agent-desktop is a licensed reference/alternative
only for a demonstrated missing capability; extending Cua is the first
choice. Current sources, licenses and component versions are in REUSE.md.

## Purpose

One `TaskLoop` drives all UI automation: observe → decide → act → settle,
with the approved progress-driven budget and verified completion only.
Explicit finite caller budgets remain supported. Replaces the
hand-rolled `DriveLoop` control flow, deletes the dead perception lane,
and fixes the session-label wedge that makes repeated `--mcp-stdio`
drive_until calls hang until daemon respawn.

## Context

- `Sources/JevVoice/Drive/DriveLoop.swift` — current hand-rolled loop
  (observeForegroundWindow, observeLaunchedPID closures at :270,:294;
  session-restart refuse path ~:2023). Re-express it as a `Decider` on
  `TaskLoop`; do not rewrite its actuation semantics.
- `Sources/JevVoice/ComputerControl/CuaDriveServer.swift:205,209` —
  session label derived from `--agent` slug: identical slug → second
  client wedges on daemon session reuse. P1 bench reproduced 2×.
- `.agent/CONTRACTS.md` §1 — frozen `TaskObservation`, `DecideResult`,
  `Decider` protocol (already exists as interface; P4 implements it).
- `.agent/PROGRAM.md:121` — gate evidence: DriveLoop tests green on
  TaskLoop; Jev slice ≥95%/≤4 s; repeated same-slug `--mcp-stdio` calls
  stay live.
- P3 shipped guards to preserve: one executor permit per turn, captured
  window/literal authority, cancellation + stale-turn kill, verified
  Done only, consent ownership stays in the loop not the decider.

## Owned paths

```text
Sources/JevVoice/Drive/TaskLoop.swift
Sources/JevVoice/Support/LatencyLedger.swift
Tests/JevVoiceAppTests/LedgerLatencyTests.swift
Sources/JevVoice/Drive/NativeWindowObservation.swift
Sources/JevVoice/Drive/ObservedGoalProof.swift
Sources/JevVoice/Drive/NativeReplacementProof.swift
Sources/JevVoice/ComputerControl/FocusedTextTarget.swift
Sources/JevVoice/Drive/JevChooser.swift
Sources/JevVoice/Drive/DriveCandidates.swift
Sources/JevVoice/Drive/JevDecider.swift
Sources/JevVoice/Drive/DriveLoop.swift
Sources/JevVoice/Drive/WindowControls.swift
Sources/JevVoice/Drive/BrowserSupport.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/ComputerControl/CuaDriveServer.swift
Sources/JevVoice/Driver/CuaConnection.swift
Tests/JevVoiceAppTests/TaskLoopTests.swift
Tests/JevVoiceAppTests/JevDeciderTests.swift
Tests/JevVoiceAppTests/JevIntegrationTests.swift
Tests/JevVoiceAppTests/JevChooserTests.swift
Tests/JevVoiceAppTests/JevLiveIntegrationTests.swift
Tests/JevVoiceAppTests/CuaDriveSessionTests.swift
Tests/JevVoiceAppTests/CuaDriveServerTests.swift
Tests/JevVoiceAppTests/BrowserActuationTests.swift
Tests/JevVoiceAppTests/JevAdaptiveTests.swift
Tests/JevVoiceAppTests/JevAdaptiveLiveTests.swift
Tests/JevVoiceAppTests/JevAdaptiveFixtures.swift
Tests/JevVoiceAppTests/JevAdaptiveWorkflowTests.swift
Sources/JevVoiceCore/Models/JevSelection.swift
Sources/JevVoiceCore/Models/JevModels.swift
Sources/JevVoiceCore/Models/JevClient.swift
Sources/JevVoice/Drive/JevVisualDecision.swift
Sources/JevVoice/Drive/VisualTarget.swift
Sources/JevVoice/Drive/VisualGoalProof.swift
Tests/JevVoiceTests/JevSelectionTests.swift
Tests/JevVoiceTests/JevModelsTests.swift
Tests/JevVoiceTests/JevClientTests.swift
Tests/JevVoiceAppTests/JevVisionTests.swift
Tests/JevVoiceAppTests/JevProgressLiveTests.swift
Tests/JevVoiceAppTests/DriveLoopTests.swift
Tests/JevVoiceAppTests/DriverConnectionTests.swift
Tests/JevVoiceAppTests/FastLaneTests.swift
Tests/JevVoiceAppTests/DriveSessionCursorTests.swift
Tests/JevVoiceAppTests/JevNativeObservationTests.swift
Tests/JevVoiceAppTests/JevNativeChoiceDiagnosticTests.swift
Tests/JevVoiceAppTests/JevEditableValueTests.swift
Tests/JevVoiceAppTests/JevObservedGoalTests.swift
Tests/JevVoiceAppTests/JevExactReplacementTests.swift
Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift
scripts/verification-lane.sh
.agent/results/P4/**
.agent/acceptance/P4.json
# Decision Log only
.agent/CONTRACTS.md
.agent/PROGRAM.md
.agent/PROGRESS.md
.agent/phases/P4-taskloop-jevdecider.md
```

## Non-goals

No SolDecider/BrowserDecider (P5/P7), no new tools or tool schema, no
voice/ASR/semantic changes, no gaze changes, no P3 acceptance edits, no
revival of the deleted perception lane. The separately approved Jev
image fallback stays within TaskLoop under its scoped-image amendment.

## Milestones

### M1 Session-label wedge fix (riskiest seam, smallest diff)

Fail-first: repeated same-slug `--mcp-stdio` drive_until calls hang.
Fix label derivation so each connection gets a distinct session while
preserving resume semantics for intentional reconnects. Guard test:
two sequential same-slug sessions both complete.

### M2 TaskLoop + JevDecider

Implement frozen CONTRACTS §1: `TaskLoop` owns actuation, settle,
budgets, consent routing; `JevDecider` adapts the existing bounded
candidate pick (recall v2 semantics preserved: literal text never
rewritten by the model). `DecideResult.done` requires a preceding
successful verify_state settle — zero false Done.

### M3 DriveLoop on TaskLoop + perception lane deletion

Re-express DriveLoop's observe/dispatch flow as the Jev Decider inside
TaskLoop. Same element_token/snapshot authority, same refusal shapes
(sessionRestartedMessage etc.). Remove the unused perception lane code
path. All DriveLoopTests green against the new structure.

### M4 Slice + regression

Jev slice ≥95% success, p50 ≤4 s on the frozen existing bench local-safe
population through the real application. DriveLoop tests are regression
evidence, not a substitute for this live criterion. Full
verification-lane green, G4 judge, handoff.

## Acceptance mapping

- P4-1 wedge fix + regression → M1
- P4-2 TaskLoop/Decider contracts implemented → M2
- P4-3 DriveLoop tests green on TaskLoop → M3
- P4-4 perception lane deleted → M3
- P4-5 Jev slice ≥95%/≤4 s → M4
- P4-6 fresh-context judge PASS + clean handoff → M4

## Progress

- 2026-11-08 user approved repairing Jev according to current TypeSafe
  research, keeping planning providers separate. Related ownership above
  is extended for the shared candidate/request adapter and its checks.
  No P3 voice changes or new tool schemas. P4 stays open.
- Regression evidence: `.agent/results/P4/jev-before.log` reproduces
  state overwrite, missing read-only content, numeric target omission,
  missing small-surface coverage, secure-value exposure, core-state
  overwrite, and the 12-round production default. The follow-up
  `jev-verification-before.log` reproduces quiet-screen and production
  completion-policy verification bypasses. Current fixes are not yet
  fully verified; original tests assuming unsupported completion need
  explicit postconditions and real fixture evidence, not weakened checks.
- User explicitly approved at most 30 TypeSafe API requests through the
  question tool for old/new synthetic UI fixture comparisons. No private
  app state, screenshots, desktop actions, other providers, or retries
  beyond that cap. This grant has spent ZERO requests so far.

- 2026-11-07 plan drafted after P3 physical qualification deferred to a
  release-gate checklist item (user decision; build b853 installed,
  signed, review/install receipts bound; runner armed for later session).

## Decision Log

2026-11-17, KAR-28: a native gaze click must press the proven retained
object, not target coordinates, active focus, or a delayed token from
another observation. A gaze-selected field, window or app cannot
authorize typing, closing or hiding. Named controls, explicitly bound
foreground typing and the captured-window scroll path remain separate.

2026-11-17, KAR-25: [the exact agent-window constraint](../CONTRACTS.md#decision-log-p4-exact-agent-window-target-2026-11-09)
does not authorize the caller to share a person's input. Refuse stdio drive
and preview before decode or preparation; preserve the direct foreground
execution and native verification paths. No positive concurrency claim.

### C1 candidate handoff, 2026-11-16

Independent source/candidate G4 PASS follows the authority/identity
repairs and measured native caller changes. The evidence packet is
[c1-handoff](../results/P4/c1-handoff.md). The real 300-line owned-window MCP
scroll attempt blocked on both builds with Jev HTTP400 max_tokens_exceeded;
there was no scroll or false success. Normal-controller direct scroll
and physical use remain unproven. Preserve this failing case. Additional
request-shaping/SDK/evidence-interface edits require the contract's
amendment process; enabling less-accurate long context is not a proof.
P4 acceptance is unchanged; Terra/C2 work has not started.

### D15 Trace-Only Native Decision Diagnostics (2026-11-12)

User selected Approve Trace And Preview after senior0c77f700 PLANPASS
for results/P4/jev-native-decision-observability-plan.md. Permit only
privacy-safe refinement outcomes in JevChooser.swift and full native-read
timing/exit phases in NativeWindowObservation.swift. No state, labels,
values, IDs, images, keys or URLs in new logs. Questions, requests,
decisions, proofs, AX calls/timeouts, cancellation and all numeric gates
stay unchanged. Existing owned tests/harness paths only; one public
suggest_action through an isolated signed copy, no drive_until/input/
install/reset. No candidate/release pass. Behavior changes require their
own demonstrated cause and approval.

### D14 Native Dispatch Pacing (2026-11-11)

User selected Approve Scope on 2026-11-12 for the existing private
JevNativeChoiceDiagnosticTests.swift ownership correction. Only its
pre-model read-only fixture readiness allowance may change5s to10s,
with maximum10reads and all complete/native/window/value checks intact.
Product500ms collection, goal deadlines, thresholds, model questions,
driver, signing and app input remain unchanged. One read-only capture;
preserve the failed old attempt. No repeated goal or qualification claim.

User subsequently selected Fix Test Fixtures, permitting test-only scope
extension to FastLaneTests.swift and DriveSessionCursorTests.swift. Three
existing happy-path fixtures must supply their intended pinned app bundle
alongside pid/windowID; the pinned-app guard and negative checks stay intact.
The broader pre-fix run preserves all six assertion failures.

User explicitly selected Approve D14 for
results/P4/jev-native-dispatch-latency-plan.md after independent plan
review 4b3992f3 passed with no open material risks. Extend ownership only
to CuaConnection.swift and DriverConnectionTests.swift in addition to the
existing DriveLoop/test paths. Generic native-token TaskLoop dispatch only:
existing public glide_duration_ms=120 per owned session/generation and
post_action_wait=none only when the exact tool advertises it. Do not
configure the shared default cursor or change visibility/style/effects.
No preference in fast-lane, visual/scoped, keys, browser, media, window or
no-token paths. Scope, consent, cancellation and fresh independent completion
remain unchanged. Cache schemas once per generation, invalidate on rebind,
and preserve no mutation replay. Definite unsupported/cosmetic refusals keep
legacy behavior; uncertain transport outcomes do not authorize input.
Native diagnostics motivate the change but are not product speed evidence.
Cold first-goal and warm pilot rows stay separate; matched runs keep one
goal per fresh session. P4-5/P4-6 remain false pending actual qualification.

- 2026-11-08 retain Jev for bounded judgments, pin the drive chooser to
  1.14.0, and keep planning provider work in P5. Choice contains only
  actions; independent applicability and completion Nouls share its RTT.
  Code retains literal text, workflow, consent, and actuation ownership.
- Preserve the previous confidence-equivalent action floor alongside a
  conservative selected-probability floor; do not lower it to pass a
  failing case. Known explicit postconditions skip inference but still
  require verifyState. No quiet-screen or acknowledgement-only completion.
- ReadDistribution and internal choice metadata are additive; the P3
  semantic router's readDetailed interface is unchanged. Completion
  restoration and consumer audit are recorded in CONTRACTS' P4 entry;
  fresh independent review remains pending.

## Surprises & Discoveries

The first live request revision regressed to 2/5 because indirect
instructions and reserved statuses still competed with actions. Corrected
the request shape, not the thresholds. Literal availability is code's
question, not the model's. A 0.87 done Noul on an explicit already-present
postcondition showed that asking the model was unnecessary there.
Old positive fixtures that completed on empty screens or unverified DOM
events also needed meaningful observed goal evidence.

## Outcomes & Retrospective

Progress-driven follow-up Decision Log (user direction supersedes the old
four-round Jev ceiling): optional round count, nil means unbounded. Other
TaskLoop consumers keep finite default4; production DriveLoop defaults
nil. RoundBudget remaining is optional; nil is never terminal-round.
Time-budget expiry is distinct from finite-round exhaustion. TaskLoop owns
idle-decision protection and cancellation, not the model. Existing invalid,
stale, low-confidence, consent/deny and verified-goal checks remain.
Consumer audit: JevDecider terminal-round logic, TaskLoop iteration/counts,
DriveLoop escalation mapper, preview/production candidate builders and
all test fixtures. P5/P7/P9 decider implementations have not landed.
G2 read-only reviewer6c3591cc returns terminal PASS before implementation.

Same reviewer approves the remaining combined integration plan before
code: optional caller-owned values/success_contains/deny in the TWO MCP
tools, strict decoding and no new target pins or execution authority.
Public nine realtime tools are unchanged. System One Noul optional
criteria true/false remains wire-compatible for existing callers that
omit it; encoder and enum-switch consumer checks required.
Remove the refiner's first3 candidate omission, keeping original support
and probability thresholds. One followup batches independent judgments;
there is no blind opinion-retry or new slower planner.

Evidence to date: six old-source regressions fail9 assertions, then9 new
checks pass and229 broader checks pass. MCP old decoder loses literals,
goal evidence and denies (13 assertions fail); available button label
was incorrectly accepted as outcome (1 assertion fails). Fixed and4
checks pass. Refiner discarding fifth candidate reproduced separately.
Fresh 16-case API validation is authored data, not blind qualification.
Its first control includes an ambiguous development label "Report
generated": a click could inspect status, not necessarily generate work.
Keep that raw run, correct only this development fixture to explicit
"Generate report", re-freeze and rerun control before prompt treatment.
Do not relabel ambiguous control1 rows to claim accuracy or unsafe acts.
No acceptance bar is waived. Full revision review/proof still pending.

The Jev integration repair is implemented, fully regression-tested, and
installed with explicit approval. Full lane: 1,113 Swift tests, 15 skipped,
zero failures; tracker typecheck and 234 tests green. Exactly 30 approved
synthetic requests spent; failed trials are retained. Final model-only
sample 9/10; all ten recorded cases pass through current code after the
deterministic postcondition fix. Replay is not another live sample.
Release app is signed, running, matches release code/data sections, and
tracker readiness is HTTP 200. See results/P4/jev-integration-report.md.

## Handoff

P4 is NOT accepted. P4-5/P4-6 remain false; no acceptance flags changed.
Prior bench5 is 16/30 strict success, not the old 25/30 end-state match
count. Fresh phase review and independently verified desktop slice still
required. This task does not waive the >=95% success, p50 <=4 s, or zero
false-Done bars, nor the deferred P3 physical release checklist.
The 30-request grant is exhausted: do not reset its journal or make more
paid diagnostic requests without a new approval. No commit/push performed.

## Current Handoff: Native Value Repair And No-Go

This section supersedes the older request-budget/install notes above.
The user subsequently approved additional/unlimited Jev experiments,
progress-driven execution without a fixed round ceiling, and isolated
synthetic desktop checks. No further Fn/microphone qualification,
personal browser/document interaction, or permission reset was requested.

The editable-value bug is reproduced and fixed. Cua's display `value`
falls back to the placeholder for empty fields. Swift now clears those
untrusted editable values and reads actual AXValue from the same bound
window after secure-field exclusion. Empty is trusted empty; failed reads
are unknown. Exact unique role/label/frame matches correct only existing
SDK row values, never their tokens, indices, actions or bounds.
No public protocol, pinned resource, permission or confidence-floor change.

G3: 1191 Swift tests, 18 skipped, zero failures; 114 focused tests,
1 skipped, zero failures; 234 tracker tests and typecheck pass.
G4: fresh896e253f SOURCEPASS, PHASEFAIL. Signed clean clone receipt:
`results/P4/jev-candidate-stage-6ec2307771e34c8aaee594112231d5f5.json`.
The frozen packaged resources and signing requirement remain unchanged.

Matched real desktop reproduction with corrected identical harness:
old82 saves empty Email,0/1 strict; new6ec types the exact supplied word
Email and finishes3/3. Both use the same30s diagnostic caller deadline.
A separate test-corpus defect was fixed first: the copied placeholder
case still expected the old address despite requesting Email. Failing-first
corpus check, original artifacts and corrected before/after runs are kept.

G5 is NOT met. With original caller deadlines, the current affected slice
is6/9 strict,7/9 state matches,3 cancellations, zero false_done, clean
resources. Successful-completion median is8419.1137705ms, not <=4000ms.
Goal-only installer is0/1 strict: UI complete, resultstuck.
The diagnostic3/3 is not evidence of95% workflow reliability or4s latency.
4/6 acceptance criteria remain green; this is not an effort estimate.

The candidate is NOT installed. No commit/push, browser reset, document
access or new physical voice test was performed. Full evidence, visual
before/after and the current no-go are in `results/P4/jev-p4-current-verdict.md`.
Remaining phase work is native completion latency and reliable goal-only
outcome proof at the existing thresholds, followed by qualifying G5/G4.
Do not repeat prompt variants until one says yes, count censored calls
as success, or infer a timing cause without a paired per-stage trace.

## Historical Handoff: General Visual Fallback Research

The user rejected app-enablement workarounds as a product solution and
requested investigating Jev screenshots for missing/incomplete AX.
The approved paused-only Spotify restart was diagnostic; do not repeat
it or turn that flag into product setup. No playback/device change ran.

Read-only research and its negative control are complete:
`results/P4/vision-readonly-2250aa40282940289214708c21894287/report.html`.
Jev1.14 accepts images/Box, but TypeSafe labels this experimental.
The actual app does not wire it: wantsScreenshot=false, empty screenshot
capture, no assets/Box decoding. Three image requests recognize the owned
synthetic TextEdit window, but editability is uncertain and absent Play
targets still receive boxes. No model-selected action or location-accuracy
claim follows. The unchanged owned document was closed and retained.

`results/P4/jev-vision-plan.md` proposes the general demand-driven path,
frozen-contract/consumer amendment, owned paths, fail-first checks and
signed real-app A/B. It is NOT yet approved or implemented. G1 and an
independent G2 review were required; no helper was authorized at that point.
No app-specific flags, new capture backend, driver upgrade, default
round ceiling, slower per-action model or threshold reduction proposed.

Latest existing-source repair candidate is signed but UNINSTALLED:
`results/P4/jev-candidate-stage-53e1cfa34ff7489685ea2676cc9bdde4.json`.
192 focused tests0fail and3metadata tests0fail; scoped browser requests
cannot restart/prepare an entire profile and blocked replies retain
recent steps. Its inherited unresolved resource-aggregate caveat remains.
These source changes have not received a fresh G4 or real-app qualification.
P4-5/P4-6 remain false; historical reliability/latency failures stand.

## Decision Log: Approved Image Verification Implementation (2026-11-09)

The later user-approved image/driver amendments and G2 reviews supersede
the historical research-only handoff above. See results/P4/jev-vision-plan.md,
jev-vision-driver-amendment.md, jev-vision-cua-045-candidate.md and the newest
jev-realapps-resume.md checkpoint; no phase acceptance changes follow.

The approved internal typed-evidence extension is implemented as defaulted
ActuationRequest.visualTarget/visualVerification and
TaskObservation.visualGoal/visualAnchor, plus default-nil Loop-owned
verifyVisual callback. A visual verifyState proposes evidence only; next
round captures one fresh exact-window frame, independently verifies the
outcome, then permits Done on that SAME verified current frame. The
original visual subject anchor is retained across the run; failed/uncertain
subject continuity stops rather than silently rebinding. No additional
capture in a step, decider-owned verifier, public raw coordinates, new
permission or weakened completion threshold.

G3 whole JevVision/TaskLoop/DriveLoop/JevDecider scopes pass150 checks
after fail-first goal/subject cases. This is fake-provider/component
evidence only. Per-action continuity, semantic visual progress, native
CID-preserving dispatch and production voice/agent/preview wiring remain
pending. Fresh G4 must review all named consumers before enablement.

## Decision Log: D10 Native UI Outcome Amendment (2026-11-11)

User selected Approve And Continue for reviewed plan SHAe76c52e3.
Independent73dc42f7 PLAN PASS follows seven explicit contract repairs.
Implement the separate readonly CFString record and sealed fresh
visual UI-outcome claim exactly within that plan. Preserve caller
literal, hidden-state, native/pixel authority and all numeric gates.
Tests precede behavior; source G4 and isolated signed proof remain
required. No installation or P4 acceptance is authorized.

## Decision Log: D9a Native Ancestor Roles (2026-11-10)

User approved the role-only metadata amendment and the six exact cleanup
paths in results/P4/jev-native-context-plan.md. Senior51fbb72e PLAN PASS.
The approved cleanup is complete, including exact reconstruction and
original-signature verification before archiving obsolete633-before.
Both890 signed candidates, the9b archive base, release runtimes and all
evidence remain intact. Actual free space subsequently reaches5.527GiB;
the unchanged5GiB guard still applies before compilation.

Carry optional native ancestor roles through the existing verified
native walk/merge into fact JSON and Node/Context equality. It is UI
evidence, not canonical-parent identity or an inferred body flag. Clear
SDK/old ancestry; require complete bound native scope and existing
editable-field mapping. Preserve nil callers, all D9 intent/receipt/
literal/document/field/fresh-readback gates, questions and thresholds.
No extra AX/model call, app recipe, permission or driver/public API
change. Do not move intent judgments before execution.

Production implementation is complete in the three owned files.
Fail-first merge/chooser/proof guards, a serialization mutation check
and the restored313 checks pass. Fresh6cc7d424 reviewed every listed
consumer and returns SOURCE PASS. Private packaging/runtime/read-only
harness repairs and the JSON-backed report pass52 checks and fresh
37e0a926 source/report review.

Both signed variants retain every old resource/driver byte, Info.plist,
signing policy and designated requirement; only Main and its root seal
change. Signed pilot succeeds in2015.683750ms. The comparison stops
before the last candidate command at a native readback preflight gate.
One candidate-only continuation does not replay completed commands.
Across issued commands baseline and candidate both succeed2/3, with
exact native bodies6/6 and no false Done. The continuation adds only
failed-read diagnostics, so the harness hash differs and this is not
an uninterrupted unchanged-harness qualification. Preflight refusals
remain unexplained; no guard was loosened. No reliability or speed gain
is established. P4 stays FAIL/open; no daily install or release.

### 2026-11-12 research handoff: decision contract and speed

The user's next-step request calls for further research, not another live
qualification attempt. `.agent/results/P4/jev-decision-speed-research.md` records
current TypeSafe, Vercel, Browser Use and Anthropic findings against existing
source and retained latency evidence. Prioritize one explicitly bound
decision proposal with batched independent judgments, then reduce repeated
native observation under an explicit coverage contract. Native execution
bundles and presentation/dispatch separation are later, separately reviewed
driver work. Existing batching, warmup, pacing and settle optimizations are
listed so they are not rediscovered as prospective wins.

No production code, model call, test, build, installation or acceptance change
in this research. D15 staging and live preview remain paused. The proposed
behavior change needs its G1 ExecPlan/G2 contract; no new gate PASS is claimed.
P4 remains 4/6, with reliability and latency qualification unmet.

### 2026-11-12 D16 source closeout and failed signed pilot

User approves the researched explicit-decision change; G2 reviewer511e9c51
accepts the contract. Five production files now bind action support to the
selected candidate, batch primary goal support, and preserve operation,
literal/key and task/window/document context through visual recovery. Bound
presence belongs to the selected native/pixel target. Focused goal recovery,
native outcome proof and all numeric/authority gates remain.

Fail-first counterexamples reproduce the old defects. All346 affected checks
then pass with0skips/0failures. Fresh judge de8b6c5e returns SOURCE PASS /
PHASE FAIL. Full delta, hashes, source verdict and results are under
`.agent/results/P4/jev-explicit-decision-*`.

Both signed variants retain the existing driver/runtime payloads. One owned
visual-fixture command returnsblocked in2428.328167ms; independent counts0/0,
false Done0. Bound presence .97 passes, but pixel location .89 and authorization
.92 fail the unchanged .95 gates. No input, resources clean. This is a real
product refusal; faster refusal is not a successful task or a speedup.

The pilot's failure stops the conditional comparison. No exact pre-D16 signed
baseline is built, no D16 A/B is claimed, and P4 stays4/6. No daily install,
physical Fn proof, unrelated app test, commit or push. The source is more
explicit; live reliability and latency qualification remain unresolved.
See `jev-explicit-decision-results.md` and `.html` for the actual evidence.

## Current outcomes and handoff: whole-program review, 2026-11-15

The user requested research covering the entire P4 plan, the whole program,
competitors, model alternatives and a bounded route to a fast finished
product. The completed report is
`.agent/results/P4/jev-program-review-20261115.md`. Its delivery sequence is
a recommendation, not an approved implementation or model-policy amendment.

The current evidence index is broader than the D16 handoff above:
`jev-pixel-routing-source-review.md` reaches D121. The D121 Safari artifact
has three strict successes, zero false Done in those rows, independent
scrollbar progression0→1, and command times24.167/22.412/22.582s. Logged
visual inference totals8.458/8.141/6.982s across16/16/15calls. The remaining
14.271–15.709s is unattributed by those spans; it is not established
driver-only time. Raw artifact paths and verified hashes are in the report.
One synthetic task is not breadth, physical Fn/pill or P4 speed acceptance.

Latest-candidate review debt is explicit. D121 derives hidden/exact
requirement scores from model kind support, rather than independent native
proof; D120's scroll authorization substitution also needs semantic
equivalence review. The earlier source PASS does not cover all subsequent
self-reviewed changes. No acceptance flag changed: P4 remains4/6.

The whole-program audit found unfinished P5/P6/P7/P9 execution paths,
production eye inference still on the web runtime despite the accepted
CoreML spike, and an off-by-default dwell contract mismatch in the source.
P3's physical/current-artifact obligations remain release work; existing
recordings and valid evidence should be reused rather than restarting its
qualification loop. P5–P13 require concrete owned plans, not implicit
absorption into this phase.

Recommended next work is one coherent cross-phase amendment: consolidate
the candidate, resolve proof semantics, trace the missing wall time, finish
the native/DOM/general execution paths, run a bounded model comparison and
qualify one final installed artifact. Preserve every existing release bar,
generic screenshot capability, captured target/literal authority and
independent consequence check. Do not move failed cases between slices to
make a phase pass.

This session changed research and handoff documents only. It ran no build,
desktop action, model experiment, microphone trial, install or acceptance
promotion, and created no commit or push. Source inspection, current
primary documentation, receipt comparisons and recomputation of retained
JSON support the report; no new performance improvement is claimed.
