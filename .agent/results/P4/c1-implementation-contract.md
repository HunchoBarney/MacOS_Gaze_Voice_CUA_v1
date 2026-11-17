# C1 implementation contract — 2026-11-16

Status: G1 explicitly approved by the user; G2 PASS (`1ccd62bc`). One implementation
owner in `jarvis-v1-agent`, branch `ship/v1-p3`. Independent read-only
G2/G4 reviewers are explicitly authorized, one at a time. No commit,
push, merge or replacement of the daily app. This contract maps C1 work
to existing phases; it does not introduce another acceptance system.

## Subject and scope

Read AGENTS, PROGRAM, PLANS, SHIP-PLAN C1, COMPETITIVE and CONTRACTS.
The inherited dirty tree is the baseline, not HEAD. Record source hashes
before edits and compare the C1 delta to those bytes. Preserve unrelated
tracked/untracked/deleted files and all historical results.

Daily rollback: `~/jarvis-local/Jev Voice.app`, executable SHA256
`f6abbe98113d7f9362ab98bc48a32e1fa94df6ddb3b376ab27dc56939fa4adf1`.
At discovery no Jev/Cua or build process was running. Canonical driver
manifest still pins 0.38.0; staged 0.45.4 artifacts and receipts exist
under the vision-driver workspace. Resolve source/SDK/runtime identities
before selecting a coherent candidate. Do not silently swap or downgrade.

Only C1: baseline/rollback binding; D120/D121 repairs; latency attribution
and justified native/speech improvements; P11-M0 dwell safety; P12 early
manifest/staging; focused/integrated checks, independent review and a
separate signed candidate. Terra integration and C2/C3 features stay out.
Jev is unlimited under the user's setup: no artificial Jev dollar/request
cap. Keep existing controls for other billed providers, cancellation,
timeouts and no-progress recovery. Historical fixture-only grants remain
historical; new C1 runs record the current authorization.

## Owned paths

The following are the maximum C1 editing surface, narrowed by evidence.
Ownership is mapped to the relevant existing phase; any additional source
path or changed authority interface requires a documented G2 amendment.

```text
Sources/JevVoice/Drive/VisualGoalProof.swift
Sources/JevVoice/Drive/JevVisualDecision.swift
Sources/JevVoice/Drive/TaskLoop.swift
Sources/JevVoice/Drive/DriveLoop.swift
Sources/JevVoice/Drive/FastLaneExecutor.swift
Sources/JevVoice/Drive/NativeWindowObservation.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/ComputerControl/FocusedTextTarget.swift
Sources/JevVoice/Support/LatencyLedger.swift
Sources/JevVoice/Intelligence/LocalTranscriber.swift
Sources/JevVoice/Voice/LocalSpeechSession.swift
Sources/JevVoice/Voice/VoiceController.swift
Sources/JevVoice/Voice/DictationDelivery.swift
Sources/JevVoice/Settings/Permissions.swift
Sources/JevVoice/main.swift
Sources/JevVoice/Gaze/DwellClick.swift
Sources/JevVoice/Gaze/GazeService.swift
Sources/JevVoice/UI/SettingsView.swift
Tests/JevVoiceAppTests/JevVisionTests.swift
Tests/JevVoiceAppTests/TaskLoopTests.swift
Tests/JevVoiceAppTests/FastLaneTests.swift
Tests/JevVoiceAppTests/FastLaneExecutorTests.swift
Tests/JevVoiceAppTests/FocusedTextTargetTests.swift
Tests/JevVoiceAppTests/LocalSpeechTests.swift
Tests/JevVoiceAppTests/LedgerLatencyTests.swift
Tests/JevVoiceAppTests/VoiceNormalQualificationTests.swift
Tests/JevVoiceAppTests/DwellClickTests.swift
Tests/JevVoiceAppTests/GazeServiceTests.swift
Tests/JevVoiceAppTests/TrackerFlowTests.swift
Tests/JevVoiceAppTests/UXConfigDefaultsTests.swift
scripts/verification-lane.sh
scripts/verify-p3.py
.agent/results/P3/**
.agent/results/P4/**
.agent/results/P11/**
.agent/results/P12/**
.agent/phases/P3-voice-one-brain.md
.agent/phases/P4-taskloop-jevdecider.md
.agent/phases/P11-eye-polish.md
.agent/phases/P12-packaging.md
.agent/CONTRACTS.md
.agent/PROGRESS.md
```

P3 result helpers are absent here but available in the sibling semantic
closeout tree. Import only the dependencies required by existing lanes,
with a source/hash manifest, without rewriting their historical evidence.
Use the current P4 staging/real-app helpers; extend those when necessary.
Do not edit the FluidAudio checkout, regenerate models or build another
speech engine/harness. Package upgrades require a separate concrete gap
and contract review before changing pins.

## M1 — authority and dwell repairs

Confirmed source concerns, to reproduce before repairing:

- `VisualGoalProof.swift` overwrites hidden_required/exact_required from
  kind_supported and redraws borderline answers on unchanged evidence.
- `VerifiedVisualGoal` can also let native literal evidence bypass a
  hidden_required rejection for exactText. Literal presence proves text,
  not hidden persistence. Review this consumer, not only the synthesis.
- `JevVisualDecision.swift` omits scroll authorization questions and uses
  operation/referent probability as permission in multiple native/pixel
  paths. Existing region geometry does not establish caller direction,
  region and scope.
- `DwellPolicy.load` falls back to .safe; timing can fall to 0.3 seconds.
  P11-M0 requires off for fresh/invalid profiles and >=1s after opt-in.

Proposed repair: retain independent requirement judgments, refuse
contradictory/missing proof, remove unchanged-evidence goal redraws, and
separate code-proven subject/literal facts from raw model scores.
Restore an independent, scoped authorization question for scroll in the
existing request batches in every lane, including `openLaneCleared`,
one-call open-native settlement and referent-bound selection. A plurality
or holistic candidate pick must not replace independent match/authorization
gates or promote a below-threshold referent into an admitted target.
Preservable code facts are actual native element existence, source-bound
identity/geometry, captured scope, fresh bytes and literal readback.
These facts cannot prove a semantic action was requested. Native clicks
also retain independent goal/authorization support; a native token alone
is not authorization. Do not introduce the removed entailment elsewhere,
add an extra serial model request or weaken any numeric threshold.

Tests in existing suites must cover hidden persistence behind a visible
status, exact versus non-exact proof, contradictory kind support, native
literal presence with hidden requirements, high scroll confidence but
wrong/absent authorization, wrong region/direction and changed subject.
Positive native/visual completion keepers must still pass.
Directly construct/verify `VerifiedVisualGoal` with native literal facts
but high hidden_required or low completion evidence: it must refuse.
Passing the model-request helper alone does not satisfy this test.

Dwell preference matrix: absent, malformed, and legacy unmarked `.safe`
are off; explicit `.off` stays off. Legacy `.all` may remain only after
the writer audit confirms it could not be automatically seeded. New
`.safe`/`.all` choices require a versioned explicit-opt-in marker written
by the Settings picker setter, not a generic defaults-change observer or
learned-multiplier save. Otherwise they are off. Display the effective
mode in Settings. Keep learned writes from creating opt-in or reversing
off. Test malformed marker values and the actual Settings persistence
path. Update the old unsafe expectations in DwellClickTests and
TrackerFlowTests; the new assertions fail on the inherited source.
Preserve voice/ask suppression, one fire per dwell and look-away behavior.
Test the >=1s floor across multipliers.

## M2 — measured speech and native improvements

Use the existing release/native/replay paths and LatencyLedger for both
sides. Initial operations: focus a running owned app, dictate into an
owned field and scroll an owned window. Freeze audio/task membership,
build configuration, runtime, device and warm/cold conditions.

At most three active hypotheses per investigation; first diagnostic pass
bounded to 45 minutes/20 commands excluding finite builds and reviewers.
After three unsuccessful attempts on one cause, reassess from evidence.
Bounds prevent repeated speculation, not arbitrary limits on Jev use.

Record Fn release, audio drain, final decode, admission, lookup, queues,
native/driver observation, input, settle and readback under one turn/task.
Separate profiling from timing, and do not add overlapping spans.
Use real output/decoy/target witnesses. No small p95 sample presented as
strong tail evidence. Retain baseline failures and every timed attempt.

Current source already starts Ultra without awaiting EOU partials.
The accurate final still decodes the whole hold after release. Investigate
actual decode/setup/drain/insertion costs, using the pinned SDK's real
capabilities. Streaming preview is never admitted as final. Preserve all
audio, literal/Unicode/selection semantics, target ownership and late
cancellation. Retry fallback only if unsupported before mutation.
Keep foreground monitoring independent of blocking window inventory.

Reproduce the signed-ASR failure with the existing captured input and
preserve its 34/35 history. Do not re-run the full old physical population
after each edit. Any necessary new ASR semantics must receive an explicit
G2 consumer amendment and fresh accuracy/resource evidence.

Warm goals remain 30/50ms feedback, 50/150ms dictation, 100/250ms native
verified effect, and 500/1000ms affected visual actions (p50/p95).
Also measure speech-end and verified readback. Goals are not achieved by
moving the clock, dropping words, extending holds or faster refusal.

Use COMPETITIVE's 24-clip pilot on an existing authorized Wispr installation
if available; missing installation/account is a coverage blocker, not
permission to purchase or claim parity. Full held-out P13 comparison stays
separate unless an ASR promotion itself requires new held-out proof.
Missing Wispr access blocks competitive claims, not preparation of the
C1 source fixes and candidate. Report that outstanding comparison plainly.

### M2 amendment: nonblocking permission status polling (G2 PASS)

Independent read-only reviewer `8b04b662` returned PASS after the
status-only API boundary and grant/wake test requirements below were
made explicit. The prior FAIL and both corrections are retained in the
review transcript. No production speed edit preceded that PASS.

The signed baseline is bound in P12 `c1-before-stage.json`, and its three
normal-controller TextEdit runs passed exact insertion/unchanged decoy,
at 2265.1988335419446, 2386.8579999543726 and 7428.993625100702ms.
Insertion was only 3.6–19.4ms. The separate diagnostic
`P4/c1profile-fb393cb5/app-sample.txt` identifies the one-second permission
timer in main.swift and VoiceController.refreshPermissions performing
repeated synchronous TCC calls on the UI thread. Those waits can delay
resumption of both gaze and resolver awaits. AppResolver already has an
exact-bundle fast path; do not rewrite it based solely on the span name.

The profiler run timed out without a mutation and is retained as a
failure. It also shows AVSpeechSynthesizer lazy loading, substantially
perturbed by dyld profiler notification waits. Do not call that a normal
speech-output duration or replace the speech engine based on that trace.

Add only `Sources/JevVoice/Settings/Permissions.swift` and
`Sources/JevVoice/main.swift` to the existing C1 scope (P3 orchestration/
P12 native permission lifecycle consumers). No new writer. Keep all
other ownership and safety limits. Implementation:

- Read the existing permission-status APIs on a background task for the
  existing periodic UI-status refresh. Use Swift concurrency, with at
  most one in-flight read; no overlapping polling tasks or busy loop.
  The injectable read seam returns only a status snapshot, using
  recordPermission/authorizationStatus/CGPreflightScreenCaptureAccess/
  AXIsProcessTrusted. It cannot request grants or open settings.
  Request, prompt and open-settings APIs remain on MainActor and are
  never invoked by the background status reader.
- Keep the explicit synchronous refresh path and actual runtime OS
  permission checks. A completed older background result cannot replace
  a newer explicit refresh. Invalidate results on shutdown. Do not make
  a cached UI status authorize capture, input or screenshots.
- Apply updates on MainActor. Revocation still suspends the microphone,
  including while preparation is pending. Grant/wake/device lifecycle
  handling remains real and unchanged in intent. The observer's sampling
  interval does not change and no safety deadline is shortened.
- Avoid duplicate periodic microphone reads by using the same collected
  status for the lifecycle callback. Do not change request/prompt APIs,
  grants, preferences, audio, voice transcript/admission or speech output.

Before production edits, put concurrency/revocation guards in the
existing LocalSpeechTests home: a blocked status read must not block a
MainActor heartbeat; overlapping refresh requests must issue one read;
an invalidated in-flight result must not apply, and a subsequent read
must still work; permission removal must preserve microphone suspension.
Also prove a denied-to-granted transition invokes the existing
wake/prepare lifecycle once using the collected status, without another
permission read; stopping/sleeping must still prevent an unwanted wake.
Use controlled status reads, not synthetic audio/model replacements.
Run focused local speech/microphone/voice consumers, then the same
signed native A/B workload. Keep the failed diagnostic outside timed
statistics. The final candidate still needs all original M2/M3 checks.

This amendment does not authorize changing a frozen public contract,
permission authority or capability scope. Any such need returns to G2.

## M3 — verification and candidate

All builds/tests use `scripts/verification-lane.sh`. Start with existing
`p4-explicit-decision-consumers`. Add a mandatory nonempty `p11` mode for
DwellPolicyTests/GazeDwellTests/GazeServiceTests/TrackerFlowTests/
UXConfigDefaultsTests, and the P12-M0 offline mode from its plan. Use
C1-focused modes for the named regressions, retaining logs that prove
tests were selected. Each new regression must fail before the repair.
Run `all` at the coherent candidate boundary, after restoring the
required P3 verifier helper. Desktop commands run through
`scripts/with-desktop-lock.py`.

Reuse P4 staging receipts and verified runtime resources. Stage/sign
outside synced Documents, verify strict signatures and content hashes,
preserve rollback and separately identify every before/after executable.
Do not invoke an install lane, make local or make run. Do not reuse a
staging helper by weakening a guard to accept unknown source/runtime.

G4 gets the contract, baseline delta, actual source and all evidence in a
fresh context. Resolve its defects before claiming source readiness.
Prepare one brief normal physical Fn/pill check against the frozen
candidate after all available machine checks. The user must perform any
physical input the tools cannot produce; replay is not that proof.

## Evidence and acceptance

Retain baseline fingerprint, command logs, raw same-method rows, signing
receipt, G2/G4 results, a JSON-backed readable comparison report and
handoff. Update owning phase decisions and PROGRESS as work proceeds.
Do not alter acceptance flags as implementer or equate C1 to P3/P4 PASS.
No acceptance bars, test population or pricing changes are authorized.
An unmet target remains explicit; pursue justified in-scope fixes or
report the exact blocking dependency with the prepared artifact.

## G2 review record

Reviewer `1ccd62bc` returned FAIL on the first draft: all native/referent
authorization consumers, native-literal bypass consumer tests, explicit
dwell migration evidence, mandatory p11 mode and Wispr blocker scope
needed clarification. The amendments above address those contract gaps.
No production source has changed while awaiting re-review.

The same independent reviewer re-reviewed the consolidated amendments and
returned terminal G2 PASS on safety, testability, sufficiency and scope.
This permits implementation; it does not establish G4/G5/G6 acceptance.
The unchanged baseline consumer lane passed 371 tests, zero failures
(`c1-baseline-consumers.log`), showing the existing suite does not expose
the identified authority/dwell counterexamples.

### Settings isolation amendment

Correct the LocalSpeechSession path above to its actual existing P3
location. Add the already-P11-owned GazeService.swift only for binding its
policy load and learned writes to one injected UserDefaults instance
(default `.standard`). The actual Settings service retains its existing
store; tests use an isolated suite with explicit opt-in rather than
depending on the user's defaults. The continuous-gaze integration guard
has stayed red after the new floor; inspect its live policy/hold state
before changing the consumer. This is not permission to weaken freshness,
shorten the one-second floor, change suppression, or modify daily prefs.
No frozen wire/protocol contract changes. Reviewer `1ccd62bc` returned
G2 amendment PASS. The diagnostic then confirmed that the target reached
a full hold, but the in-memory mode had become `.off` after a defaults
notification (`c1-dwell-state-diagnostic.log`). Use a persisted isolated
opt-in suite for that real service/stream test.
