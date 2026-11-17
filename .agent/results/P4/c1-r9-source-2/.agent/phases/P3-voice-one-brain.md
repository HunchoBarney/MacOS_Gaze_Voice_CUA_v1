# P3 - Accuracy-First Voice One-Brain ExecPlan

> Status: in progress — core implemented, G5/G6 blocked
> Track: agent+voice; depends on P2d; branch: `ship/v1-p3`
> Acceptance: `.agent/acceptance/P3.json`
> Contracts: realtime tool schemas, voice ingress; existing actuation/consent unchanged

## Shipping update — 2026-11-15

C1 R9 continuation,2026-11-16: authorized G2 PASS752c261c on
`results/P4/c1-r9-audio-startup-contract.md`. This owns the narrow VPIO
input/output-device repair and mandatory duplex preflight; its owned list
and evidence criteria extend this phase. R8's signed GUI failed AVFAudio
-10875: Core Audio proves its microphone ID was assigned to the output
bus. Keep cold ASR loading962545.488250ms as a separate unresolved finding.
Implementation is in progress; G3/G4/signed/live/human gates remain open.
The user forbids commits and daily-app replacement; no acceptance flags flip.

Read `.agent/SHIP-PLAN.md` C1 and `.agent/PROGRAM.md` speed goals before
resuming. Documentation updates are authorized; this added source scope
still needs G1/G2. Historical G1/G2 and source results below keep their
original scope. The Context's original defects are a baseline, not a claim
that all of them still exist.

C1 measures normal production timing, improves incremental speech/final
drain and the existing exact native insertion path, and reproduces the
signed ASR timeout. Target S-DICTATION is <=50ms p50/<=150ms p95 from Fn
release to complete insertion; S-NATIVE is <=100ms/<=250ms to verified
effect. They are unproven goals. Record speech-end timing and readback
separately; preserve full final text, names, corrections, negation and
exact literals. No partial dispatch, competing transcript, post-mutation
fallback or focus stealing.

Keep source, replay, signed CLI, physical Fn/pill and remote evidence
separate. Preserve the historical unsigned 35/35 versus signed 34/35 and
typing regression; neither has been erased by this planning update.
Reuse recordings and schedule the required physical population on the
final frozen artifact. Do not repeat known-good qualification per patch.

### C1 checks and evidence

- `scripts/verification-lane.sh p3-focused-native` and
  `scripts/verification-lane.sh p3-typing-repair` guard captured native
  insertion, literal/selection behavior and refusal before fallback.
- `scripts/verification-lane.sh p3-normal-closeout` is the existing
  candidate regression/build path. Expected: nonempty required suites
  pass, no duplicate/wrong input, no unchanged decoy modified.
- Use the existing P3 signed replay/normal qualification harness and
  native witnesses named in the later handoff; pin source, signed binary,
  population and harness before a before/after comparison.
- Store the new evidence under `.agent/results/P3/` and link it from the
  C1 handoff. The original eight acceptance criteria stay unchanged.

## Reuse decision

Keep FluidAudio 0.17.5 and current AVFoundation capture, platform AX
insertion, voice replay and LatencyLedger. Inspect current upstream
streaming/finalization APIs before considering an upgrade or custom audio
engine. `.agent/REUSE.md` records the SDK/version/license shortlist.
The P2d accuracy result remains binding; a newer/faster engine needs
prospective accuracy and combined speech/eyes resource evidence.

## Competitive dictation amendment — 2026-11-15

Follow `.agent/COMPETITIVE.md` for the mandatory matched Wispr Flow
comparison. Preserve the existing eight acceptance criteria and physical
population; new comparative requirements live in P13-8/P13-9.
The 35 retained recordings are regression data, not held-out proof.

The 24-clip pilot measures raw ASR, permitted formatting, actual final
insertion/readback, critical names/numbers/code/negation/tail errors and
necessary editing. After changes stabilize, use the separate >=120-clip
frozen qualification and honest uncertainty intervals. Do not compare
Flow's speech-end clock with only our Fn-release clock.

Source already runs the whole-hold Ultra final independently of pending
EOU partials. Trace final compute/drain/decoder/insertion before proposing
another wait removal. EOU output is provisional and cannot be promoted
to the final just to meet 50ms. FluidAudio's vocabulary booster is
batch-only; streaming personalized accuracy is unproven.

Use existing permitted vocabulary/correction facilities first. Any new
ASR context bias, normalization or personalization requires the P3
authority/accuracy consumer review and owned-path amendment at G2; no
silent per-app alias or literal rewrite. Neutral/personalized evaluations
are separate, with false-correction cases and user-controlled local data.
No ordinary dictation requires a Jev or Terra call.

The active checkout lacks the P3 results helpers used by the lane;
bind the sibling closeout assets in C1 before executing those commands.
New comparison tooling extends that harness and reuses validated scoring
or jiwer; it is not a new framework or another manual recording campaign.

## Purpose

Make the actual Fn voice path use one turn-tagged local transcript and
one dispatch decision. Correctness precedes speed: no speculative action
from partial words, no competing remote interpretation, and no silent
substitution of names or targets. Show live local partials in the app.

## Context

Read PROGRAM.md, PLANS.md, CONTRACTS.md, and P2d Handoff first.
The binding G1/G2 appendix is `.agent/results/P3/implementation-contract.md`;
its concrete lifecycle, authority, schema, evidence and population rules
resolve any general wording below. The frozen labeled case manifest is
`Tests/Fixtures/P3/manifest.json`.

- P2d is accepted as measured evidence, not an ASR promotion. Apple
  fast-results finalized at 84.4ms p50 versus Parakeet 150.0ms, but
  GitHub->GateHub blocks choosing Apple as the production default.
  All engines missed the 300ms first-partial target. Preserve these facts.
- Existing LocalTranscriber is Parakeet EOU+Ultra (one provider, two
  models), and LocalCommandRouter speculates from partials. main.swift
  routes local partials only to that router, not the visible transcript.
- RealtimeVoiceLane currently streams/commits audio and requests a
  response without a local final admission decision. It sends screenshots
  and uses a second cloud transcript. VoiceTaskCoordinator attempts
  text-based dedupe with a 4s localClaims ledger.
- IntentClassifier.swift also contains LocalChooserEngine; DriveLoop has
  a local-chooser fallback. These are superseded, not a second voice brain.
- Existing FastAction, IntentRouter, AppResolver, task consent/verification,
  agent asks, dictation, barge-in and microphone tests must keep working.

### Workspace And Inherited State

Work in `/Users/karanvirkang/Documents/code/jarvis-v1-agent`, not the
original shared checkout. The worktree starts at 4b263b3 with the original
uncommitted refactor overlaid locally (276 status entries). This baseline
is NOT new P3 work and must not be discarded or wholesale committed.
`.agent/results/P3/inherited-baseline.json` records dirty file hashes;
`inherited-baseline.diff` records tracked hunks before P3 source edits.
Original checkout is a read-only source of P2d recordings.

Worktree development assets were prepared with setup-workspace-development.
Downloaded Swift dependencies/artifacts were cloned locally, not fetched.
The relocated compiled-product cache failed PCH path checks; only the
worktree's copied products were moved aside for a fresh baseline build.
No original build cache or source was removed. Record baseline build
failures separately from P3 regressions.

## Owned paths

```text
.agent/phases/P3-voice-one-brain.md
.agent/acceptance/P3.json
.agent/results/P3/**
.agent/PROGRESS.md
.agent/PROGRAM.md
.agent/CONTRACTS.md
.gitignore
scripts/verification-lane.sh
scripts/sign-app.sh
scripts/bundle-tracker.sh
ThirdParty/Cua/source-manifest.json
ThirdParty/Cua/fetch-embedded-binaries.sh
ThirdParty/Cua/README.md
ThirdParty/Cua/THIRD_PARTY_NOTICES.md
Makefile
Sources/JevVoice/ComputerControl/CuaDependency.swift
Tests/JevVoiceAppTests/CuaDependencyPinTests.swift
Sources/JevVoice/Driver/CuaConnection.swift
Sources/JevVoice/Drive/AppResolver.swift
Tests/JevVoiceAppTests/AppResolverTests.swift
Tests/JevVoiceAppTests/DriverConnectionTests.swift
Sources/JevVoice/Gaze/GazeCandidateFeed.swift
Sources/JevVoice/ComputerControl/FocusedTextTarget.swift
Sources/JevVoice/Support/LatencyLedger.swift
Tests/JevVoiceAppTests/LedgerLatencyTests.swift
Tests/JevVoiceAppTests/GazeCandidateFeedTests.swift
Tests/JevVoiceAppTests/GazeLaneTests.swift
Tests/JevVoiceAppTests/GazeStreamTests.swift
Tests/JevVoiceAppTests/LiveWorkflowTests.swift
Tests/JevVoiceAppTests/FocusedTextTargetTests.swift
bench/reset/textedit.sh
bench/tasks/textedit.type.json
bench/report.py
bench/selftest.py
bench/README.md
scripts/verify-p3.py
scripts/verify-real-use.py
Sources/JevVoiceCore/Speech/VoiceTurn.swift
Sources/JevVoice/Voice/LocalSpeechSession.swift
Sources/JevVoice/Voice/VoiceSemanticRouter.swift
Sources/JevVoice/Voice/VoiceUserAudit.swift
Sources/JevVoice/Support/SemanticRequestBudget.swift
Sources/JevVoice/Support/VoiceCommandTrace.swift
Sources/JevVoice/Support/VoiceTurnEvidence.swift
Sources/JevVoice/Support/VoiceNormalQualification.swift
Sources/JevVoice/Support/VoiceTrialReport.swift
Sources/JevVoice/Voice/VoiceLiveTrial.swift
Sources/JevVoice/Voice/MicrophoneInput.swift
Sources/JevVoice/Voice/VoiceReplay.swift
Sources/JevVoice/Voice/RealtimeVoiceLane.swift
Sources/JevVoice/Voice/RealtimeVoiceClient.swift
Sources/JevVoice/Voice/RealtimeAudioEngine.swift
Sources/JevVoice/Voice/SpeechCapturing.swift
Sources/JevVoice/Voice/VoiceController.swift
Sources/JevVoice/Voice/FnInput.swift
Sources/JevVoice/Intelligence/LocalTranscriber.swift
Sources/JevVoice/Intelligence/LocalCommandRouter.swift
Sources/JevVoice/Intelligence/IntentClassifier.swift
Sources/JevVoice/Intelligence/CommandSpotter.swift
Sources/JevVoice/Support/CallbackCells.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Drive/DriveLoop.swift
Sources/JevVoice/Drive/FastLaneExecutor.swift
Sources/JevVoice/Drive/FastLane.swift
Sources/JevVoice/Drive/JevChooser.swift
Sources/JevVoiceCore/Models/JevClient.swift
Sources/JevVoiceCore/Models/JevModels.swift
Sources/JevVoice/Settings/Config.swift
Sources/JevVoice/Settings/APIKeyStore.swift
Sources/JevVoice/UI/SettingsView.swift
Sources/JevVoice/UI/ContentView.swift
Sources/JevVoice/main.swift
Sources/JevVoice/Voice/VoiceRemoteTrial.swift
Sources/JevVoice/Voice/VoiceRemoteLiveWire.swift
Tests/JevVoiceTests/VoiceTurnTests.swift
Tests/JevVoiceAppTests/VoiceOneBrainTests.swift
Tests/JevVoiceAppTests/VoiceRemoteTrialTests.swift
Tests/JevVoiceAppTests/VoiceSemanticTests.swift
Tests/JevVoiceAppTests/VoiceSemanticLiveTests.swift
Tests/JevVoiceAppTests/SemanticRequestBudgetTests.swift
Tests/JevVoiceAppTests/VoiceCommandTraceTests.swift
Tests/JevVoiceAppTests/VoiceTurnEvidenceTests.swift
Tests/JevVoiceAppTests/VoiceNormalQualificationTests.swift
Tests/JevVoiceAppTests/FnInputMonitorReleaseTests.swift
Tests/JevVoiceAppTests/NativeSpeechTailReplayTests.swift
Tests/JevVoiceAppTests/NativeWindowWitnessTests.swift
Tests/JevVoiceAppTests/VoiceTrialReportTests.swift
Tests/JevVoiceAppTests/VoiceAccuracyTests.swift
Tests/JevVoiceAppTests/RealtimeVoiceLaneTests.swift
Tests/JevVoiceAppTests/LocalSpeechTests.swift
Tests/JevVoiceAppTests/MicrophoneInputTests.swift
Tests/JevVoiceAppTests/FastLaneExecutorTests.swift
Tests/JevVoiceAppTests/VoiceLaneAuditTests.swift
Tests/JevVoiceAppTests/VoiceTaskContractTests.swift
Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift
Tests/JevVoiceAppTests/IntelligenceCommandRouterTests.swift
Tests/JevVoiceAppTests/IntelligenceCommandSpotterTests.swift
Tests/JevVoiceAppTests/IntelligenceChooserTests.swift
Tests/JevVoiceAppTests/DriveLoopTests.swift
Tests/JevVoiceAppTests/FastLaneTests.swift
Tests/JevVoiceAppTests/UXConfigDefaultsTests.swift
Tests/Fixtures/P3/**
```

No other production edits without a logged scope amendment and review.
Never stage inherited non-owned files to make a clean checkout appear proven.

## Non-goals

Do not train an ASR, promise perfect recognition, force expected answers,
blindly normalize confusable names, or claim text fixtures prove acoustics.
Do not implement P4 TaskLoop, P5 SolDecider, P6 scripts or P7 browser
drivers here. Do not remove consent, verification, or unrelated TTS.
No real messages, bookings, purchases, deletions or account changes.
No new dependencies or vendor/model switches. No public API/network calls
or paid-model live tests without user authorization.

## Milestones

### M1 - Frozen Accuracy Contract And Turn Admission

**Change:** Add a pure typed turn state machine keyed by UUID, capture
mode and generation. Partial events update display only. One final may
choose local, remote miss, clarify/refuse, dictation or cancel; identity
is checked again after every suspension. Duplicate/stale events cannot
dispatch or close the next turn. A late tool call cannot acquire authority
merely by using a new call ID.

Add a fixed text corpus before implementation: >=50 clear paraphrases
plus critical near-misses/negation, app-name ambiguity, numbers, rapid
repeat, cancellation, stale final and ask ownership cases. Expected
intent/critical slots and expected clarify/refuse cases are hand-labeled.
Keep parser output, transcript text and action authority separate.
Case/punctuation-only duplicates do not count toward 50 paraphrases.

Critical fields must be preserved/grounded, not re-invented by remote
reasoning. Unsupported/ambiguous targets must clarify or refuse.
Exact known valid targets can proceed; do not ask for every command.
Unknown/absent ASR confidence is not a fabricated high-confidence score.

**Check:** serialized `p3` scope runs VoiceTurnTests, VoiceAccuracyTests
and VoiceOneBrainTests: zero wrong dispatches, zero partial dispatch,
zero stale/duplicate admission; all 50 clear paraphrases make exactly
one intended decision. Known ambiguous cases create zero actuation.

**ASR hold:** Keep the existing provider unless prospective real-audio
evidence justifies a replacement. Optional vocabulary experiments must
use general context (including legitimate confusable alternatives),
not reference text or per-clip expected-answer injection. Existing 15
recordings are regression data, NOT unseen validation. Freeze additional
real spoken confusables before a corrective experiment. If unavailable,
record the acoustic acceptance gate as blocked, not passed by text tests.

### M2 - Local Transcript Through The Real Capture Path

**Change:** Use one local provider per turn, including dictation. Introduce
a bounded session-scoped PCM bridge so model preparation cannot silently
drop the start of speech. Prewarm while idle/holding. Bound frames, time,
load/finalize and stop; overflow, model absence, timeout or cancellation
fail closed and show a remedy. Never execute a partial tail after loss.
Bounds: <=60s mono 24kHz Int16 (2.88MB) per remote PCM buffer; <=55s
capture per existing UX limit; <=180s shared cold prewarm with visible
readiness; release-anchored safety watchdog
`min(8, max(2, 1.2 + 0.3 * sealedCapturedSeconds))` seconds covering
drain/refinement/gate (G2 delta dd1c1b5a APPROVE). The 200ms warm-final
aspiration and P3-7 dispatch/effect acceptance targets are unchanged.
A failed/late turn cannot
reuse its transcript or frames for the next turn.

Bind local partials/final to the matching VoiceController session.
Move shared callback cells out of the retired router; use proper actor
or locked Sendable state, not new unchecked Sendable boxes.
Rapid Fn down/up/down, typing, microphone-test and dictation must not
cross-wire callbacks. Dictation inserts literal text and never commands.

**Check:** same G3 scope verifies buffering/drain/cancel/source ownership,
no callback race, no action before Fn-up, and local display events while
holding. Replay actual P2d/library audio through the production provider
adapter; do not synthesize test speech. Report cold readiness separately.

### M3 - One Local-First Remote Gate And Typed Tools

**Change:** Microphone/local ASR must work without waiting for a remote
socket/key. A warm connection may prepare during hold, but cannot create
a reasoning response, send a screenshot or independently dispatch.
On local hit: execute once through the existing admission/consent spine,
clear/discard buffered remote audio, no input commit or response.create.
On local miss: bind the finalized transcript as authoritative context,
commit the matching buffered audio once and request one response.
On local failure/ambiguity/cancel: no remote fallback that bypasses it.

Disable the second cloud transcription (no gpt-4o-transcribe) and never
use remote transcript events to replace local final/display. Preserve
barge-in and task-outcome speech, but they cannot arm reasoning for a
held, cancelled or locally handled turn. Tool side effects are scoped to
the owning remote decision and cannot be replayed by duplicate IDs or
new IDs in the same turn.

Implement CONTRACTS.md section 3 catalog, validating argument shapes,
critical fields and response envelopes. Tools whose P5/P6/P7 executor
does not exist must fail closed with a named capability error, never
pretend success or execute arbitrary argv/URLs. Review the future
consumer schemas in the contract, and preserve existing agents/ask
semantics. Any answered task must be selected by stable task UUID,
not whichever task is newest.

No pixel capture/send from spoken OR typed realtime turns. Remove
gpt-4o/-mini helper paths; do not substitute an unverified API call.
Existing reasoning primitives stay with the locked model/vendor policy.
Align the model-facing gaze hint with PROGRAM's resolved-target identity,
not raw coordinates, with a contract version/consumer review note.

Remove claim-ledger admission and competing LocalCommandRouter,
CommandSpotter, IntentClassifier/LocalChooser paths. Preserve only
shared utility types in their new owner. Migrate obsolete tests to
assert the new invariant rather than silently deleting coverage.

**Check:** control remote transport and hardware/executor boundaries, not
the voice state machine. Unit integration may replace those boundaries; never
replace the production parser, admission, lifecycle or provider adapter
and claim that helper-only tests cover the real path. No model doubles
or generated audio count as acoustic/physical proof.
Capture outbound frames. Assert local hit/ambiguity/dictation emit zero
response.create, miss emits exactly one, no images/transcription config,
typed tools reject malformed/unknown/cross-turn requests, and no old
classifier/ledger/model source path remains.

### M4 - Integrated Verification And Human Try

**Check:** verification lane `swift` then `all`, baseline-aware scope,
negative controls, redacted span report, fresh G4 judge, G5/G6.
Use scripts/with-desktop-lock.py for all actual microphone/GUI trials.
Live transport calls require separate authorization; no secret values
or user speech/audio committed. P3 test artifacts go only in owned
results paths; raw recordings remain ignored.

Report: per-case expected/actual intent, critical slots, provider, route,
dispatch count, clarification/refusal rate, frame IDs, outcome verifier,
timing and environment. No model claim of success is a verifier.
Trace records are content-free by default; explicitly approved fixture
text can be retained, not incidental app/clipboard/recipient contents.

Target warm final <=200ms, first partial <=300ms (report misses honestly),
T0 admission/dispatch <=300ms, whole one-shot effect p50 <500ms.
Do not replace actual effect latency with an ack. >=50 paraphrases with
zero double dispatch; zero known wrong critical-slot actions.
Use independent end state for disposable Calculator/TextEdit only.

Human G6: hold Fn, see local text during speech, release once, see one
correct safe action; rapid repeat, cancel, short tap, dictation, and an
ambiguous name must behave honestly. Need real unseen/confusable audio
before any ASR promotion. Do not mark live/human gates green from replay.

## Acceptance mapping

| Criterion | Milestone | Layer |
|---|---|---|
| P3-1 baseline/scope | all | baseline and source checks |
| P3-2 accuracy/admission | M1 | unit + integration fixtures |
| P3-3 local PCM/display | M2 | production adapter + recorded audio |
| P3-4 remote gate | M3 | transport frames + lifecycle integration |
| P3-5 schema/retirement | M3 | contract + source scan + consumers |
| P3-6 verification | all | serialized full regression suites |
| P3-7 real UX/budgets | M4 | live independent end-state + G6 |
| P3-8 handoff/judge | M4 | fresh reviewer + gate evidence |

## Gates

- User requested plan, independent review, then implementation. Treat
  that as authorization to implement the reviewed contract, not to
  bypass the review, promote an ASR, send messages, or commit/push.
- G1/G2: one bounded fresh-context judge reviews this plan + executable
  acceptance against actual interfaces before production edits. Fix
  consolidated findings; no repeated stuck foreground judge loop.
- G3: all builds/tests through verification-lane.sh; desktop lock also
  serializes live commands across worktrees. Cached dependencies only;
  missing dependencies/assets are blockers, not permission to fetch.
- G4: fresh-context judge checks actual acceptance; only its verdict
  may flip passes with evidence.
- G5/G6 cannot be replaced by unit fixtures. If authorization, hardware
  interaction, key availability or held-out voice is missing, mark
  blocked/needs_human and preserve a resumable implementation.
- G7: user-authorized named-path commits only. The inherited uncommitted
  baseline is not a clean-checkout claim or permission to commit it.

## Progress

### Typing Refusal Repair (2026-11-03)

Current supplement: `.agent/results/P3/typing-repair/CONTRACT.md`, G2
review f13bddc8 PASS. This supersedes the earlier speculative nil-window
relaxation and first-editable AX focus attempt, which did not fix the bug.
The actual reproduced defects are canonical bundle qualifiers failing
resolution and admitted speech payloads differing from execution goals.
`e1` is a candidate ID, not an error code. Preserve captured window
authority; nil capture must block, never select the current field instead.
Remove first-field focusing; production voice-direct typing requires
native current focus before any token/model path. Normal-controller
disposable document proof must not set auditDocumentBinding.

Fail-before logs contain 21 initial assertion failures plus two exact
selection/readback failures; focused after-run passes 27 tests (one
explicit desktop probe skipped). Full regression and signed live proof
remain pending at this entry. No P4 or acceptance flips.

Latest outcome: `.agent/results/P3/typing-repair/RESULTS.md`.
The final signed release J passes normal-controller exact typing, matching
native/captured window, one mutation, one Work done, zero model rounds,
decoy unchanged and no audit binding override. Full suite955Swift6skip,
19Python,234tracker pass; delta review PASS. Identical signed executable
installed and backed up. Normal startup currently waits for user Keychain
authorization; mic readiness, physical Fn behavior and timing acceptance
are NOT verified. J controller-settle5917.984ms is not instant/T0 proof.
Do not rebuild or request another full trial. P3 stays open.

Follow-up: Keychain cleared on the same process; microphone prewarm and
driver handshake verified. User reports "ok it worked this time" after the
requested physical Fn typing check. User-attested typing success only;
cursor/delay were not separately reported, formal population/timing remain
open. Preserve the working build and do not request another repeat.

### User Authorizes Continued Jev Testing; No P4

User explicitly authorizes needed Jev/TypeSafe spend and web research to fix
and close P3, but forbids starting P4. New continuation contract is
results/P3/closeout-next-contract.md. First add observable turn/task stages
and diagnose installed first-case failure, then a minimal root fix/regression.
Do not reset old paid ledger/heldout or infer completed physical/server gates.

User now identifies unwanted confirm/deny INSIDE pill. G1 policy amendment:
instruction-consent-contract.md replaces mandatory semantic app-focus
confirmation ONLY for a measured clear joint observed-app focus proposal.
Uncertainty clarifies target; sensitive/external scopes unchanged. Fresh
calibration and zero-approval production dispatch evidence required before
install. Existing failed42requests and all failed desktop attempts preserved.

### Real-User Closeout Pass

User approves bounded TypeSafe live text tests (max50), varied installed-user
checks, benchmark research and instruction-as-consent for ordinary app focus.
Binding run contract: results/P3/user-path-contract.md. Real self-messaging
is allowed only to uniquely verified self contact, with exact-send approval.
No real email/login available. P1 accepted; P3 physical acceptance still
unproven. Unsafe old TextEdit reset must never run on this account.
G2 approval before code; keep missing gates explicit instead of claiming P4
readiness from unit counts. No model promotion, other vendor spend or VM
download inferred; no commits/push.
### User-Requested Default Enablement

User explicitly requests semantic assist enabled automatically as a core
feature, including their local app. Change only the unset preference default
to true, preserve explicit false opt-out, update disclosure, and set this
user's preference true on reviewed installation. Human confirmation, target/
nonce/cancel guards and no-live-calibration boundary stay unchanged.
G2 contract review before production edits; all paths already owned.
G2 e7bfc37c approved. New236-case before run failed only the new default
assertion;236 focused and16 boundary checks pass after the change.
G4 CODE_DELTA_PASS default policy only. Router/confirmation/freshness/typed
execution/Core files remain byte-identical to prior reviewed source.
Final release/full/replay and new exact signed binding required.

### User-Approved Semantic Assist Amendment

User approved bounded TypeSafe semantics. Decision3 is amended only by
results/P3/semantic-contract.md: opt-in, confirmation-first app-focus
proposals using observed targets and the existing client. No paid calibration
or automatic model-driven execution authorized. G2 review before code.
Two Core model/client files newly owned for checked Sendable conformance
only;248 other protected baseline paths/FastLane bytes preserved. This is not a
P4 decider rewrite or a claim that task-settle timing measures visible focus.
G2 e7bfc37c approved this contract. Initial compile errors were corrected
(typed executor moved beside its private resolver; wire fixture factory is
nonthrowing). Negative bridge control compiled229 tests and failed three
checks when semantic interception was disabled. Restored implementation,
added no-match single-owner wire coverage and strengthened cancel/disable
generation + deadline envelope through freshness. G4 caught and corrected
the disable/re-enable-after-inference gap; full-turn tokens protect cleanup.
Real confirmation-to-production-typed-executor regression added. Positive
focused234 tests and16 evidence checks pass. No live TypeSafe calls.

### 2026-10-24 — named-app vocabulary mismatch

User confirms Calculator worked, but Google/focus vocabulary inadequate.
Admission's exact display-name comparison is stricter than the existing
executor resolver; live rosters also contain non-user Chrome helpers.
Bounded vocabulary contract is results/P3/vocabulary-contract.md: reuse
existing grammar/grounded resolver, whole-token names and common wrappers,
same canonical text for admission/execution, original transcript retained.
FastLane.swift frozen; no new TypeSafe integration under Decision3.
The logged late Chrome completion (~17s) and session restart are separate
unresolved transport responsiveness evidence, not explained by vocabulary.
G2 review required before production changes; acceptance remains false.

G2 reviewer def5cfd5 approved the bounded contract and finite authority
corrections. New tests reproduced27 failures before implementation
(including basic requests incorrectly taking the missing-OpenAI-key path).
After corrections216 focused tests and14 evidence checks pass.
G4 found/fixed three gaps before final freeze: work-scope show/focus callers
must honor captured app identity; resolver nicknames cannot collapse two
candidate IDs; exact command-shaped choice labels are replies, not typing.
The real coordinator now shares unchanged pure spec construction with its
guard regression. Reviewer CODE_DELTA_PASS applies to this delta only;
final release/full checks, replay and signed installation still required.

### 2026-10-23 — real GUI finalization failure; do not resume formal trial

- User screenshot and native app logs reproduce deadline failures on
  ordinary 3.4s/2.0s captures. Fn/security input is not the blocker.
  The title is provisional text, not proof of an authoritative final.
  The installed diagnostic candidate is not demonstrated reliable.
- Stop asking for repeated/formal human holds. Bound provisional EOU calls
  to1280 samples (80ms@16k) so a large native tap cannot run multiple
  model chunks without another finishing check. Bank the whole-hold
  audio unchanged; preserve turn/tail ownership. Deadline unchanged.
- Add content-free generation/timing logs for elapsed-before-drain,
  drain, EOU join, Ultra decode, and GUI release-context refresh.
  These are necessary because the precise GUI bottleneck is unproven.
- New diagnostic uses the first2.8s of confirmed h15, paced with320 and
  4096-frame packets. It PASSED before the batching correction too:
  this is coverage, NOT proof the GUI timeout is fixed. It does not
  replace frozen35-clip or physical tests. Partition regression fails
  with old whole-buffer ranges; restored implementation passes.
- P3 focused209 tests +14 evidence checks pass on unchanged rerun.
  Initial after-run xctest crashed with signal11 in an unrelated fast-lane
  test; original log retained. Current installed receipt is stale for
  edited source; new build/review/install required for stage diagnostics.
  Reviewer def5cfd5 CODE_DELTA_PASS for this bounded-work delta, with
  explicit runtime-not-fixed limitation.

### 2026-10-22 — reviewed close-out contract and latency investigation

- User authorized contract reconciliation, local latency fixes/tests, a
  fresh independent review, and installation for physical testing.
  Remote/paid validation remains unapproved; no commit/push authorized.
- G2 reviewer dd1c1b5a APPROVED the finite scaled safety watchdog but
  correctly left full-phase acceptance FAIL. Updated acceptance, binding
  implementation contract and M2 together; latency targets unchanged.
- Review exposed conflated remote/physical flags and missing current
  package binding. Physical `live` and server `remote` now have distinct
  predicates. Install receipt requires a current code review, source and
  executable bindings, matching build UUID and strict bundle signature.
- Baseline timed driver spans show `list_apps` costs 2-4.8s. Exact,
  AppResolver-proved bundle IDs with a deterministic open/raise parse
  now skip that global scan; other verbs/ambiguous names retain it.
  The first typed sample improved effect p50 from 2586ms to 253ms.
  This is not a speech/physical latency claim; measure recorded audio
  separately. See RESEARCH-CLOSEOUT.md and latency-*.json receipts.
- Uncertain raise fallback now needs a positively visible exact window,
  the frontmost PID and frontmost ordinary window ID. Other windows of
  the same app and unknown visibility cannot masquerade as proof.
- Final source freeze, full checks, independent G4 code review and
  signed installation still follow; no physical or remote PASS inferred.
- Fresh G4 reviewer def5cfd5 found four harness gaps. Fixes bind a complete
  per-run attempt ledger (a scored failure cannot be retried into PASS),
  preserve/reject early Fn release during preparation, invoke actual
  source/review/signature/UUID preflight before holds, and record one
  complete cold turn plus two verified warmups. The formal physical
  count is 27, not the previously stated 26. Negative controls are in
  release-boundary-before.log and attempt-population-before.log.
- The now-real cold turn exposed a background launch reporting done
  without a foreground effect. Explicit foreground opens now activate
  the requested app before window discovery and cannot settle done on
  mere process existence; generic open-scope and fast-lane paths both
  require foreground/window verification. Existing open-scope test
  fixtures now supply and assert that proof rather than an acknowledgement.
  The release lane runs release tests then explicitly builds the final
  production CLI before binding, preventing stale standalone artifacts.
  A one-graph experiment was
  discarded: this toolchain's release `--build-tests` did not enable the
  `@testable` imports. Keep the normal release build/test commands.

### 2026-10-22 — repair the physical harness before another user run

**Historical pre-hidden-raise checkpoint:** release `5f0acf9a7172`; automated desktop run
`CBD80565-BAFC-4A35-AF7E-730565750F3B` passed two verified warmups and
9/9 scored checks (five opens, withdrawal, Esc, dictation, confusable).
196 release tests passed; full lane ran 808 Swift tests (1 skipped,
0 failures), EyeTracking typecheck and 234 tests passed. Production
acoustic replay is 35/35, zero wrong actions, on the same artifact.
Scope preserves all 250 inherited non-owned paths. Detailed receipts:
`.agent/results/P3/{self-test.json,harness-self-test.log,harness-repair-release.log,harness-repair-all.log,harness-repair-replay.log}`.
The desktop lock is released; no trial remains armed.

**Still open:** physical microphone/installed-app UX, the three unrecorded
spoken paraphrases, remote validation/authorization, and fresh review.
Automated dispatch p50 was 311ms and effect p50 2667ms; these exceed the
300ms/<500ms targets and are not physical acceptance measurements.
No acceptance flags were flipped and no commit/push was made.

- M1–M3 are implemented; the earlier automated evidence and delta reviews
  do not validate subsequent harness edits. P3 remains open.
- Confirmed harness defects: cancellation of its timer still called abort;
  warmups neither timed out nor awaited actual app effects/task completion;
  setup launched Calculator before speech and could race the next task.
- Repair those paths in VoiceLiveTrial.swift, with permanent regression
  checks in LocalSpeechTests.swift. Retain the real CFRunLoop entry point.
- Run `--p3-live --self-test` under the desktop lock using confirmed local
  recordings, scripted holds, real Parakeet and real Cua/app effects.
  Separate self-test artifacts explicitly exclude physical microphone,
  human attestation, remote validation and unrecorded spoken paraphrases.
- Only after that passes ask for another human run. The frozen 24-row
  physical matrix and latency targets remain unchanged; no evidence is
  relabeled to close G5/G6. Current code still needs fresh review.
- Automated run 1 verified both warmups and five opens, then exposed
  cancellation being misreported as capture loss. Run 2 exposed live
  driver proxies being discarded on daemon refusals. Fix cancellation
  ownership and preserve healthy primary/read proxies in the already-owned
  VoiceTaskCoordinator.swift; repeat the same desktop check.
- Transport tracing then isolated the remaining restart: two proxies
  reused `voice-direct`, and the pinned driver returned
  `session is not available to this transport`. Route session-bound reads
  on their command owner's transport; parallel reads now require no session.
  A routing regression demonstrably fails with the former behavior.
- The historical `~/.devin/plans/plan-5f89b1db0d4517e0.md` is superseded;
  PROGRAM.md plus this phase plan are the active plan.

- [x] Isolated worktree + inherited baseline captured.
- [x] G1/G2 plan/contract review (4cde77ea APPROVE; finite fixture condition applied).
- [x] M1 accuracy and turn admission implemented (phase acceptance still open).
- [x] M2 production local capture/display implemented (physical UX still open).
- [x] M3 remote gate, typed tools, legacy retirement implemented (remote live unproven).
- [ ] G3 full regression, G4 final review.
- [ ] G5/G6 real physical/held-out proof.
- [ ] G7 authorized handoff/commit.

### 2026-10-22 — hidden Calculator found in physical c2

- The user's latest real Fn run (`live-attempts.jsonl` run
  `27DBCE84-EE85-461B-AB7C-BCA118E0BC65`) passed five scored `open`
  rows. `live-c2` rep 1 failed three times with "Calculator has no
  observable window to bring forward"; no wrong dispatch occurred.
- The fixture hides Calculator intentionally. `runOpenVerb` enumerated
  windows without first unhiding the already-running app for raise verbs.
  A hidden window is not an observable on-screen row. This is a
  product-path failure exposed by the fixture, not an ASR failure.
- Scope amendment: own only the narrow hidden-app restoration in
  `Sources/JevVoice/Drive/FastLaneExecutor.swift` (previously inherited).
  `DriveLoop.swift` and `FastLaneTests.swift` were already owned. Add a
  failing-before test and preserve the inherited content outside this
  change. Fresh review of this amendment is pending.
- Do not retry the physical trial until a current binary passes an
  automated `show`/`bring` hidden-app check. Keep the frozen matrix and
  real-user attestation unchanged.

### 2026-10-22 — hidden raise correction verified; human gate still open

- Source-bound release `eee51413e0b610856c5b3c497c2b99f8fb4cdebc79d8a52d3fb696dc5073303a`.
  Two verified warmups + 9/9 scored recorded-audio/scripted-hold checks
  passed (run `E442D60F-C473-49B7-BD70-62A9D2655F7E`). Targeted
  *typed*, not spoken/Fn, checks of `show`, `bring ... to front` and
  `switch` each had five verified real app effects on the same release.
- Red/green guards: `hidden-raise-before.log` fails the hidden-restore
  test before the fix; `hidden-raise-uncertain-before.log` fails the
  independent-verification test when the driver sends an uncertain result.
  `hidden-raise-release.log` runs 201 focused release tests, zero failures.
  Final full lane: 813 Swift tests (1 skipped, 0 failures), EyeTracking
  typecheck and 234 tests, all green. Acoustic replay 35/35, 0 wrong.
  `verify-p3.py` scope/accuracy/contracts/hygiene/frontdoor PASS;
  249 inherited non-owned paths preserved after the documented scope
  amendment; `FastLane.swift` remains byte-identical to baseline.
- macOS probe found `NSRunningApplication.unhide()` can return `false`
  *even when the app unhides*: restoration now waits for observed
  hidden-state change, activates the explicitly requested app's windows,
  and still requires independently verified PID + exact window.
  `bring_to_front` uncertain outcomes are never retried as mutations;
  they settle done only on independent matching foreground/window proof,
  otherwise block. A driver-failure during a later full automated run
  and one synthetic-Fn false-release motivated a separate, scripted-hold
  automated check. Only the user's physical mode exercises Fn/mic.
- Human `live.json` absent (last real run aborted at c2, on older source).
  Release→dispatch automated p50 339ms, release→effect p50 2393ms;
  both exceed the 300ms/<500ms targets. Full G5/G6 and fresh G4 review
  remain open. No acceptance changes, milestone commit, push, deployment,
  or remote-live calls.

## Surprises & Discoveries

- The shared checkout contains uncommitted foundational source files
  required by P3. Overlay reproduced 116 untracked source/test files as
  inherited state; fingerprints capture 276 entries. Original remains
  untouched. Future review must compare against that baseline.
- Compiled PCH caches embed absolute module-cache paths and cannot be
  reused merely by cloning .build into another worktree. Retained
  downloaded artifacts/checkouts, moved only our copied products aside.
- Existing frozen voice schemas contain a raw-coordinate gaze hint,
  contradicting PROGRAM's newer resolved-target privacy directive.
  A narrowly versioned schema amendment and consumer review is required.
- Fresh inherited Swift baseline compiled and ran 789 tests (3 skipped),
  with two failing assertions in FastLaneTests.testColdLaunchWaitsForWindow.
  The fake loop uses a default AppResolver that sees the real running
  Notes PID 44290 instead of the fake launch PID 99. Scope includes a
  narrow test-isolation correction using the existing injectable resolver;
  do not weaken the cold-launch effect/window assertions.
- G1/G2 reviewer 4cde77ea returned REVISE with six finite contract gaps.
  The binding implementation-contract.md plus frozen case manifest now
  specify autonomous/abstention denominators; typed critical-field and
  exact ask-nonce authority; whole-hold EOU/drain/deadline ordering;
  connection/response/input provenance and one-admission permits; exact
  nine-tool capabilities/async results; evidence formats, commands and
  physical populations. This is pre-implementation correction, not
  a claim unwritten code has passed.

## Decision Log

### C1 candidate handoff, 2026-11-16

C1 implementation and scoped independent G4 passed. The separate c292
candidate, rollback, matched clocks, source delta and remaining gates are
in [c1-handoff](../results/P4/c1-handoff.md). Scripted typing median improved
35.63%; speech replay median regressed 24.22% with unchanged transcript
hashes and critical-action correctness. Physical Fn/pill, full
speech-to-field/readback clocks and warm goals remain unproven.
No P3 acceptance flag was changed. Run one brief physical check on the
frozen copy; do not repeat completed populations or replace the daily app.

2026-11-05 microphone-readiness repair: real physical run
B69E5095-9383-4894-9903-09C511AE1790 held Fn for 1.871 seconds but
delivered zero PCM. The input configuration log records a stopped engine
after startup. G2 judge 2c4dd5a5 approves first-real-frame readiness,
one bounded same-device/same-format recovery before ready, unchanged
post-ready interruption policy, and sticky trial input failures. Tests
precede implementation. A non-actuating microphone preflight must prove
flow before another human hold. No ASR, SDK, deadline, acceptance or P4
change is authorized by this repair.
The owned-path list now explicitly includes `MicrophoneInput.swift`,
previously part of the preserved inherited overlay. Its existing changes
are retained; only the approved readiness repair is applied. The inherited
baseline is not rewritten.

| # | Date | Decision | Why |
|---|---|---|---|
| Focus-inflection-20261105 | 2026-11-05 | Allow a bounded grammatical inflection only in explicit app-focus frames | User requests continued P3 repair; strict G2 plan review 84eee5d7 PASS. The AC7 physical failure remains failed. Mirror only the executor's exact observed-name trailing-s concept, not its substring/bundle tiers. Original finals stay immutable; exact/whole-token ambiguity wins; no bare, quoted, literal, negative, multi-target or captured-ask expansion. Tests must fail before the implementation and guard unique observed identity, exact plural precedence, stale/ambiguous context and frozen confusables. No ASR/model hints, alias table, provider change, acceptance relaxation or P4. Full newly bound signed and physical evidence remains required. |
| Receipt-cycle-20261105 | 2026-11-05 | Bind P3 acceptance semantics, not mutable judge verdict bytes, in the code-review receipt | Old review_matches reproduced a cycle: changing only passes/evidence invalidated code review; regenerating review invalidated install and physical receipts for an unchanged binary. G2 review 29f5cbf4 PASS conditional on failing-before proof, now recorded. Version p3-contract-v1 hashes every acceptance field except criterion-level passes/evidence; all other reviewed files retain raw SHA. Tests first require verdict stability, contract/code mutation rejection, and explicit version. This changes no substantive gate, Swift source, installed app, or P4 interface. |
| Remote-live-20261104 | 2026-11-04 | Implement the separately authorized, capped text-only real-server qualifier | User explicitly authorized four cases and at most eight model responses. G2 plan remote-live-plan.md received strict PASS from 29f5cbf4 after safety corrections. Add only the three named new paths plus existing main CLI dispatch, lane target and verifier paths. Persistent reservations precede sends; actual URLSession WebSocket, unchanged production decoder/authority, no desktop backends or media input, exact captured-live stale replay, explicit source/signed execution binding. Authorization alone never closes the gate; physical qualification remains separate. |
| Resolver-20261104 | 2026-11-04 | Exact running bundle lookup before all-app metadata in AppResolver | Signed ov1-before resolves took 137-944ms, including an unnecessary full process/name scan for a canonical bundle ID. G2 plan review 29f5cbf4 PASS; own only AppResolver.swift and AppResolverTests.swift. Preserve injected inventories, all exact matches, ambiguity, the existing fallback/cache, and every actuation/effect check. No SDK overlay exemption. |
| Scope-20261104 | 2026-11-04 | Name eight already authorized P3 repair/evidence paths explicitly in ownership | Scope audit found seven added/modified repair files omitted from the list, plus the documented Nov03 dangling-symlink packaging repair in bundle-tracker.sh. Add only those exact paths, keep the original inherited baseline unchanged, and continue checking every other non-owned byte. No source rollback or broad directory exemption. |
| 1 | 2026-10-19 | Work in isolated agent worktree with a preserved local overlay baseline | Avoid editing the original user's large uncommitted refactor or silently testing obsolete HEAD sources |
| 2 | 2026-10-19 | No automatic Apple ASR promotion | P2d measured a speed win, not acceptable critical-entity recognition; only real corrective/held-out evidence can change that |
| 3 | 2026-10-19 | Historical TypeSafe freeze; narrowly superseded by Decision21 | Initial P3 kept TypeSafe unchanged to avoid uncalibrated semantic auto-correction. User later explicitly approved confirmation-first semantic assist under semantic-contract.md; no automatic policy or paid calibration is authorized. |
| 4 | 2026-10-19 | CONTRACTS section 3 v1 draft replaces raw gaze coordinates and specifies async results/task+ask identity | P5/P6/P7/P11 are future consumers; source audit finds no implemented consumer of the old nine-tool catalog, only legacy voice names. They must adopt v1 target IDs, exact args and accepted-versus-completed semantics, not claim P3 unavailable stubs are implemented executors. G1 reviewer approves amendment before production code |
| 5 | 2026-10-19 | G1/G2 APPROVE, apply one finite context/population clarification without another review loop | Reviewer confirmed all six contract corrections. Manifest now defines all named contexts, current/replaced ask nonce and owned task, per-acoustic population/route/count, a single h01 remote expectation and h12 clarification. Missing real recordings block acoustic closure, not implementation |
| 6 | 2026-10-20 | Do not ignore optional resolved-target arguments | Existing generic coordinator has no v1 opaque-target resolver binding; return named unavailable:resolved_target until P11, rather than pretending a generic goal honors the target. Schema/consumer shape unchanged; G4 reviews this capability narrowing |
| 7 | 2026-10-20 | Remove raw gaze sample from existing Jev state, retain resolved candidate hint | D8 applies to the existing downstream decider too. Local geometry can annotate a candidate as under the user's eyes; the model never receives raw gaze x/y. The regression fails before the change; existing candidate-count/identity checks remain |
| 8 | 2026-10-20 | Separate real acoustic replay admission from physical effects | New headless production-adapter CLI uses real local models/PCM, no model doubles, no mic/GUI/network. Gold stays outside inference. Release artifacts/source/asset hashes and failed/missing populations are explicit; replay cannot complete G5/G6 alone |
| 9 | 2026-10-20 | Bind ask selection into immutable admission, not just tool-time nonce membership | G4 found a model could choose between two unselected current asks. VoiceAskBinding plus pre-model ambiguity refusal now preserve the unique/capture-selected pair. Short-gesture mode/cancellation guards and quoted/unquoted withdrawal guards were tightened in the same reviewed safety correction |
| 10 | 2026-10-20 | Generic search date modifiers cannot become app targets; ungrounded label clicks clarify before models | Real replay found two route errors with zero ASR edits. Keep frozen labels, preserve the whole source goal, route unsupported generic search through browser_request and forbid generic computer fallback. Both corrections have failing-before guards and independent delta approval |
| 11 | 2026-10-22 | Automate harness validation before asking for more physical holds | User reports repeated hangs and premature Calculator opens. Exercise recorded PCM through the microphone gate/converter and synthetic Fn through the actual event tap, then verify real task completion and frontmost PID. Keep self-test.json distinct from live.json and retain failed warmups/attempts. No acceptance relaxation or remote authorization is implied. |
| 12 | 2026-10-22 | Preserve healthy coordinator transports on daemon refusals | Automated repeated opens exposed a session-restart failure. Both call funnels discarded proxies on every error, including valid daemon replies and cancellation. Consult connection liveness and only evict the failing connection if still current; never replay a mutation. This narrow correction is within the existing coordinator ownership and still requires fresh review. |
| 13 | 2026-10-22 | Session-bound reads use the command transport | Exact pinned-driver trace shows bring_to_front/start_session refused after list_windows minted the same label on the other proxy, then the reverse refusal after rotation. Keep sessionless reads parallel; do not share session-bound snapshots/tokens across transports. This trades the invalid concurrency assumption for correct driver ownership and needs fresh review. |
| 14 | 2026-10-22 | Restore a hidden app only after a permitted explicit raise request | The human c2 trace shows a hidden, running Calculator had no observable window and was blocked three times. A voice `show` must be able to unhide its explicitly named app, then still require independent window/frontmost verification. Own a narrow change to FastLaneExecutor; pinned or unverified windows still fail closed. No automatic acceptance or milestone completion. |
| 15 | 2026-10-22 | Verify hidden-app restoration by state, not AppKit return; never replay uncertain raises | A local AppKit probe showed hide()/unhide() return false while state does change. Explicit raises now wait for observed unhide, activate that app's windows, then verify exact target. If Cua reports an uncertain bring_to_front, do not retry the mutation; require independent frontmost PID plus exact on-screen window. Synthetic Fn events made the automated probe spuriously report a missed physical release, so it now scripts holds, clearly distinct from human Fn/mic evidence. Recorded/audio and typed targeted cases remain separate populations. |
| 16 | 2026-10-22 | G2-approved safety timeout correction; independent physical/server evidence | Reviewer dd1c1b5a approves scaled release-anchored watchdog without relaxing latency targets. Physical proof now binds current source, review and signed installed executable; remote authorization alone cannot satisfy separate server evidence. All acceptance flags stay false. |
| 17 | 2026-10-22 | Remove measured global inventory from exact app-open critical path | Five typed baseline raises spent 2-4.8s in list_apps. A canonical bundle identity already proved by AppResolver plus the existing deterministic open/raise parser can supply the same target row locally. Ambiguities, non-open verbs, consent, target validation, real actuation and effect verification remain unchanged. Keep content-free per-stage timing; do not hedge/replay mutations. |
| 18 | 2026-10-22 | A foreground open requires an observed foreground window, including the cold launch | The first complete cold trial found a background launch could settle done with no visible app. Activate the explicitly requested app and retain positive exact-window/PID verification in fast and generic open paths. Background/windowless requests without foreground intent retain prior semantics. Preserve the failed cold ledger; no scored retries or acceptance relaxation. |
| 19 | 2026-10-22 | Use the public OS reopen action for an unconstrained foreground app request | WindowServer showed Calculator frontmost but all its windows off-screen; normal OS reopen produced a visible window. NSRunningApplication.activate is not an application reopen event. NSWorkspace.openApplication with activation and no new process instance restores the app's normal window, followed by existing exact proof. Never use this to replace a missing pinned window. |
| 20 | 2026-10-24 | Align named-app admission and local execution without a new classifier | Exact-display-name admission rejected Chrome/Google while execution could resolve them. Use unique observed full/contiguous-token names, bounded shared surface normalization and canonical captured identity. Preserve transcript/literals, exact-choice/nonce authority, ambiguity, unavailable routing and frozen FastLane bytes. TypeSafe semantic integration remains a separate approved-plan/calibration decision; the17s transport delay is not solved by this change. |
| 21 | 2026-10-24 | User-approved TypeSafe semantic assist is opt-in and confirmation-first | Live docs support one batched action/target Choice request. Model may propose only an observed app-focus target; code owns current-turn/freshness/nonce/deny/exact-effect gates and a typed executor. Human confirmation always required; default off, no paid calibration or automatic mode. User reports visible focus is instant; the former17s visible-delay claim is retracted. |
| 22 | 2026-10-24 | User requests TypeSafe enabled by default as core functionality | Supersedes the activation default in Decision21, not its confirmation boundary. Unset preference enables; explicit false persists as opt-out. Enable this user's local preference as explicitly requested. Retain disclosure; no automatic app execution or paid calibration authorized. |
| 23 | 2026-10-25 | Evaluate CPU final decoding and declare bounded latency-critical voice activity | Recurring physical timeouts persist after optional EOU joins were removed. Requested placement/native-arrival timing favors CPU decoder with unchanged encoder/weights; 35 real recordings and full checks required. A turn-owned ProcessInfo activity prevents undeclared background throttling, not a proven App Nap root-cause claim. G2/G4 reviewer134632f3; physical acceptance remains required. |
| 24 | 2026-10-25 | Avoid redundant installed-app inventory for exact bound literals and frontmost window chords | Actual installed literal trace stalls in listApps after canonical target resolution. Use singleton canonical row only with exact authoritative literal, or identical parsed window-hotkey keys and actual canonical frontmost; qualified/deictic/identity/risk mismatches keep broader resolution. All permissions, target and effect gates unchanged; failing-before guards required. |
| 25 | 2026-10-25 | Narrow frozen FastLane exception: preserve fully quoted literal bytes | G2 reviewer134632f3 approves only the fully quoted type-payload extraction correction. Unwrapping then trimming/second-unquoting violated the existing verbatim guarantee and corrupted audit payloads. Own FastLane.swift for this minimal change only; preserve baseline and all unrelated parser/risk/qualification/hotkey behavior. Supersedes prior byte-freeze statements solely for this exception; frozen labeled corpus unchanged. |
| 26 | 2026-10-25 | User explicitly requests Cua Driver upgrade during P3 closeout | Evaluate and intentionally pin official component0.38.0, preserve0.34rollback, verify release digests, host embedding/liveness/standard permission and tool contracts before install. Canonical installer currently defaults0.37; GitHub prerelease flag is monorepo release-pointer bookkeeping. No silent update, vendor-source candidate adoption, P4 or unverified typing-success claim. |
| 27 | 2026-10-26 | Adapt explicit structured snapshot requests to Cua0.38's Markdown default | Real installed output proves no default elements; preserve the legacy metadata contract in CuaConnection unless callers specify a format, and request elements-only in the two fast-type observations. Consumer review includes DriveLoop, FastLaneExecutor, coordinator halo and GazeCandidateFeed. No targeting/permissions/retries/session refactor or frozen output-schema change. |
| 28 | 2026-10-26 | Native AX frame units are global top-left points, not screenshot pixels | Signed0.38 driver frame matches independent OS AXPosition/AXSize exactly. Correct feed, halo, description, overlay and gaze annotation consumers to use those points directly; preserve distinct DOM/OCR/pixel transforms. No new gaze capability, policy change or coordinate guess; tests use real observed frame contract rather than the invalid old pixel fixture assumption. |
| 29 | 2026-10-26 | Natural app shortcuts must reach bounded semantic interpretation | User reports full-title-only behavior across apps. Unique unquoted whole app-name descriptors normalize locally through the existing observed-name token lookup, with question/greeting/ask/permission guards. Other ungrounded app-focus/bare-command clarifications may use bounded semantic judgment with observed identities/roles, no per-brand alias patch or lower confidence. Semantic-owned narration must not append the old generic clarification. Fresh live language and signed effects required; frozen corpus, turn ownership and P4 boundaries unchanged. |
| 30 | 2026-10-26 | Preserve captured local windows and use proven focused input, never editable-row guesses | Owned Chrome probe exposes three editable controls and exact native focus; the old unique-only selector cannot use it. Normal local caller also dropped its captured window ID. Forward guarded current local capture windows; use retained native AX field/window identity with Cua's existing exact-window foreground typing rung for focused input. No pixel/row focus inference, partial/unknown replay or unverified Done. Instrument startup stages before diagnosing load latency. No P4/DOM planner/new permission/model change; separately judged contract in closeout03. |
| 31 | 2026-10-26 | Foreground observation and executor settlement must agree without requiring window titles | Physical cold attempt observed Calculator foreground but executor found no selectable window. Reproduce offscreen/untitled protocol rows; use native focused/main AX window CGID only when present in the driver's scoped rows, retaining exact raise verification and missing pinned/named-window refusals. Preserve failure and report observed foreground separately; never accept failed Work merely because the app appeared. No retry/latency relaxation/P4. |
| 32 | 2026-10-26 | Verify a completed native foreground request before issuing a redundant driver raise | New physical run passed five turns, then driver reported a live Calculator PID nonexistent. When this unqualified foreground-open path already issued native activation, allow success only after independent matching PID, native CG/AX window identity and a fresh on-screen driver row. Hold the existing lease, retain all policy/cancellation/unknown-outcome guards, and leave pinned/named/background behavior unchanged. Do not mask arbitrary driver refusals or relabel the failed physical run. |
| 33 | 2026-10-28 | Distinguish local acoustic acceptance from normal typed routing and save failed-run diagnostics | Keep the physical local gate and all thresholds intact. Persist a privacy-safe versioned diagnostic sidecar on failure and clearly print the heard final/failed stage in the user's console. Add separate normal-controller four-local/one-semantic typed coverage and a nonphysical verifier; never relabel semantic fallback or scripted input as local physical PASS. No source-level ASR guess without the missing recognized text. |
| 34 | 2026-11-03 | Repair canonical app and literal handoff before native focused typing | G2 typing-repair contract approved. Exact observed bundle qualifiers must resolve without display-name normalization; local admitted literal drives both goal and payload. Production voice-direct typing retains mandatory captured window authority, uses already-focused native input before snapshot/model, and verifies exact selected-range insertion. Remove speculative first-editable focus and nil-window relaxation. Agent token work remains distinct. No physical acceptance, automatic document creation, driver-policy bypass or P4. |
| 35 | 2026-11-03 | Preserve exact native literals and consume canonical Cua action receipts | Signed candidate A changed requested lowercase text under synthesized foreground typing. Use existing exact-window semantic AX delivery for native nonbrowser fields; browsers keep foreground events. Runs B-D prove exact insertion but false blocked status because canonical MCP output omits legacy verified. Accept its confirmed/accessibility/background/value_readback receipt only for direct native work with independent exact selected-range proof; explicit false/partial/refused/unknown/unverifiable remain blocked. G2 and delta reviews pass; no retry, clipboard, settings or driver changes. |
| 36 | 2026-11-03 | Capture actual focused window identity, never CG ordering | Signed release I records CG first row 33042 versus native focused window 33047. Task/exact insertion use 33047, checker incorrectly expects 33042. Production admission shared the ordering assumption. Use frontmost-PID-guarded AXFocusedWindow for admission and typing audit; preserve AXMain fallback only for unrelated existing foreground effect verification. G2 f13bddc8 and delta4f0f09da approve; final signed evidence remains required. |

## Outcomes & Retrospective

Earlier implementation snapshot (superseded by dated progress and HANDOFF):
Core M1-M3 are implemented. That lane passed799 Swift tests
(3 skipped), EyeTracking typecheck +234 tests, release186 tests.
Source/run-bound scope/accuracy/contracts/hygiene predicates pass.
Independent G4 code-delta PASS/APPROVE follows fixed findings, not full
phase acceptance. Original three safety findings plus two real-audio
admission errors have regression guards; no frozen labels were retuned.

All20 held-out utterances recorded and confirmed (native mic CLI).
Full production-adapter replay:35/35 recorded cases meet frozen
admission expectations,0wrong critical actions,9/9 clear,0 extra
clarifications. The first full run surfaced3 real defects—two deadline
failures where provisional EOU streaming was awaited inside the1s
Fn-up budget (fixed by banking PCM synchronously and draining EOU on
an ordered skippable tail) and one literal payload leaking ASR's
utterance-final period (unquoted payloads now drop terminal sentence
punctuation; quoted stays verbatim). Fixes have replay/diagnostic
evidence; recorder resume bug also found and fixed. First partial
callback p50~1.79s still misses300ms; finalization p50~178ms is not an
end-to-end action budget. No Apple promotion, no perfect-ASR claim.
No physical action was performed by replay; callback counters are not
successful real app effects. G5 physical Fn trials, G6 human UX and
remote-live validation remain open and acceptance stays fail-closed.

## Handoff

See `.agent/results/P3/HANDOFF.md` and source-audit.json. All20 holdouts
are recorded; do not ask the user to record them again. Next steps are
current-source latency evidence, fresh code/contract review, reviewed
signed installation, then human Fn/microphone testing of that installed
artifact. Physical and authorized remote validation are separate gates.
Remote calls require separate explicit authorization. Original source
checkout remains read-only; branch requires the preserved inherited
refactor overlay. No files staged, committed, pushed or deployed in P3.
Do not flip acceptance from a code-only review or these regression clips.

### Normal-App Qualification Correction (2026-11-06)

User-approved G1 and independent G2 PASS `1cd10ec1` change the physical
front door, not resolver behavior or the release bars. Follow the
self-contained `.agent/results/P3/normal-voice-qualification/PLAN.md`
and implementation-contract amendment. Old failures remain diagnostic
failures. The normal app retains its pill, Fn monitor, capture, semantic
interpretation and executor. No user trial until signed observer proof
and fresh G4 PASS. P3 is still open; P4 has not started.

Focused command: `scripts/verification-lane.sh p3-normal-qualification`
must pass Swift recorder/profile and Python corruption/population checks.
Final regression/build: `scripts/verification-lane.sh p3-normal-closeout`
must pass full Swift, tracker, verifier, protocol and release/frontdoor
checks. Typed A/B and observer diagnostics stay explicitly nonphysical.
`python3 scripts/verify-p3.py live` accepts the new bound normal-app
physical report only, and still needs real human input/confirmation.
