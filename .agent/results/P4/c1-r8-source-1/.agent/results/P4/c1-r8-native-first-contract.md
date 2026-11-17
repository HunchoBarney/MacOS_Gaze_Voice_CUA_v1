# C1 R8 native conversation foundation

G1: continuing C1 authorization, including the user's latest explicit directions
for native routine controls, default continuous listening, natural follow-ups and
an architectural reassessment. G2: PASS b30bbce0, all 14 criteria MET, before
production edits. Receipt: `c1-r8-g2-review.md`.

## Purpose and context

Make ordinary scrolling work through code and let the continuously listening
front door use the same direct admission path as explicit input. Produce a useful
signed hands-free candidate rather than another independently green component.

The full product reassessment is
`jev-product-architecture-review-20261116.md`. This is its first concrete
implementation boundary, not the complete conversational/multilingual product
or C1 acceptance. Broader dialogue, streaming recognition, language coverage,
agent follow-ups and portable first-use provisioning remain required work.
Do not silently expand billed providers or replace the speech models here.

Baseline: signed R7
`~/jarvis-local/c1-candidates/jev-c1-final-r7-6oiq4l34/Jev Voice.app`,
SHA `6b035fac125308d0c6079cf6e1e4387c5139a14f77e5336870b1fdf1fe85b6a1`.
Frozen source: `c1-r2-candidate-source-r7-final/manifest.json`,
SHA `235d9e7055f649130c94dcc65be836abdea055a499dd277bc7415db05761f750`.
`c1-scroll-r7-native/comparison.json` proves zero viewport movement and a blocked
result in the real owned TextEdit workload. This is a failed-operation baseline,
not a successful latency measurement. Retain the semantic 29-case failure too.

## Reuse decision

Retain FastAction, WindowScrollRequest, ConversationSession/turn authority,
NativeWindowObservation, existing native field/focus operations, Cua 0.38,
consent/currentness/cancellation, the current speech provider and shared audio
renderer. The macOS SDK supplies AX scroll bar actions, button attributes and
value manipulation. Discover supported native actions; use no app-specific
scroll recipes, positional scrollbar-button indexing or new driver binary.
Reuse the existing verification lane, owned desktop harness and LatencyLedger.
No new dependency or replacement model in this boundary.

## Owned paths

One application writer; inherited changes are preserved. R8 delta only:

```
Sources/JevVoice/Drive/NativeWindowObservation.swift
Sources/JevVoice/Drive/FastLane.swift
Sources/JevVoice/Drive/FastLaneExecutor.swift
Sources/JevVoice/Drive/DriveLoop.swift
Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
Sources/JevVoice/Voice/ConversationContext.swift
Sources/JevVoice/Voice/LocalSpeechSession.swift
Sources/JevVoice/Voice/VoiceSemanticRouter.swift
Sources/JevVoice/Voice/VoiceController.swift
Sources/JevVoice/Settings/Config.swift
Sources/JevVoice/UI/OnboardingChecklist.swift
Sources/JevVoice/Support/VoiceCommandTrace.swift
Sources/JevVoice/Support/LatencyLedger.swift
Tests/JevVoiceAppTests/FastLaneExecutorTests.swift
Tests/JevVoiceAppTests/DriveLoopTests.swift
Tests/JevVoiceAppTests/NativeWindowWitnessTests.swift
Tests/JevVoiceAppTests/LocalSpeechTests.swift
Tests/JevVoiceAppTests/VoiceLaneAuditTests.swift
Tests/JevVoiceAppTests/VoiceSemanticTests.swift
Tests/JevVoiceAppTests/VoiceTaskCoordinatorLaneTests.swift
Tests/JevVoiceAppTests/UXConfigDefaultsTests.swift
Tests/JevVoiceAppTests/UXOnboardingTests.swift
Makefile
scripts/bundle-conversation-vad.py
scripts/verification-lane.sh
.agent/results/P4/jev-stage-candidate.py
.agent/results/P4/c1-scroll.py
.agent/results/P12/c1_manifest.py
.agent/CONTRACTS.md
.agent/SHIP-PLAN.md
.agent/PROGRESS.md
.agent/results/P4/c1-current-handoff.md
.agent/results/P4/c1-r8-*
```

The packaging delta is only the final-r8 label and canonical reuse of the already
pinned ConversationVAD payload/validation. Existing immutable model/source/
candidate records stay unchanged. No EyeTracking, FluidAudio checkout, public
MCP DTO, TaskLoop, provider pin, deny policy or driver source edit.

## Implementation contract

1. **Fresh native target before input.** Require a valid ScrollViewport with
   exact process/window/root/region/document identity before any scroll. Missing
   evidence or region binding sends no input. Delete targetless-arrow fallback.
   Preserve gaze targeting, original goal, pinned scope, independent consent,
   caller deny rules and the late admission/currentness checks.

2. **Native operation before driver planning.** Add an internal injectable
   ScrollControl operation alongside ScrollRead. It receives the bound viewport,
   requested direction and existing 1/3 line amount. Discover the actual axis
   scrollbar's supported AXIncrement/AXDecrement or named increment/decrement
   button action. Validate role, ancestry, PID, window and freshness immediately
   before input. Run synchronous AX calls off the UI actor; reuse existing input
   lease/cancellation ownership. Recheck cancellation between repetitions.
   No arbitrary values or default guessed positions.

3. **Distinguish unavailable from uncertain.** The native result distinguishes
   unsupported-before-input, sent, and uncertain-after-attempt. Only the first
   permits a positively bound existing Cua route. Never retry or fall through
   after a possible effect. A compatible AXTextArea token may be used only when
   its native parent/content binding and unique snapshot identity match the
   exact viewport; do not infer identity from a role/name alone. A coordinate
   route retains the existing frame/coordinate proof. No targetless dispatch.

4. **Independent consequences.** Keep native post-readback, direction, document/
   content continuity, freshness, stable observation, edge and false-completion
   checks. Input acknowledgement alone is not success. A successful bounded
   native scroll uses no semantic/planning call and needs no experimental
   image-model mode. The same executor serves explicit/MCP and voice entry.

5. **One local admission opportunity.** After complete-utterance assembly and
   existing risk policy, continuous mode tries a typed local decision before
   Jev. Initially cover exact, fully grounded bounded scrolls and the existing
   simple local app-focus/keys/media actions where their admission already
   proves the complete request. Reuse existing parsing and native executors.
   Preserve the original transcript/literals; never reparse a model-authored
   canonical goal or synthesize confidence. Unrecognized wording retains
   semantic interpretation, so the local parser is an optimization rather than
   a phrase vocabulary the user must learn.

6. **Grounded follow-ups.** Recognized single-more/continue phrases use only the
   last actually verified scroll in the same current window/document/region.
   Single movement and ongoing repetition remain distinct. A new unrelated task
   cannot inherit that anchor. Negation, quotes, reported/ambient language,
   incomplete clauses, corrections, sidebar/other-region, counts/units, compound
   and until-X goals do not enter a partial local action. No ordinary local path
   may bypass a held negative fragment or a pending question's exact identity.
   Missing/ambiguous context retains the semantic/clarification path.

7. **Relevant semantic judgments.** Repair overlapping scope definitions so
   a current window and its owning app do not compete as valid interpretations
   of the same scroll. Use mutually exclusive scope criteria and preserve
   complete/addressed/whole-goal/direction/amount/extent support meanings and
   existing numeric thresholds. Do not use a native operation's confidence as
   general authorization or reinterpret an “until” request as one movement.
   Keep the existing recorded probe population; no selective winning rerolls.

8. **Barge-in pauses movement.** Speech onset interrupts reply playback and
   cancels the active repeating foreground scroll promptly. Preserve its last
   verified anchor for the incoming utterance; do not cancel the new capture,
   lose queued audio or require “stop” to traverse a model first. Existing
   universal stop still reaches voice work and agents. Do not cancel unrelated
   background reasoning merely because the microphone detected speech.

9. **Listening is the default.** Fresh profiles enable hands-free mode after
   required permissions and real audio/model readiness. Preserve explicit off
   and pause choices across restart. Fn remains an override. Use existing
   listening/paused/unavailable presentation; update obsolete Fn-only onboarding
   copy. Do not enable dwell, force gaze, register a staged login item, change
   grants or make a missing model/permission look ready.

10. **Canonical VAD resource.** Normal staging must validate/copy the same
    pinned VAD resource as C1 staging, including notices and inventory checks.
    Packaging fails clearly on absent/corrupt inputs. This does not turn external
    ASR assets into a portable release; keep the manifest's readiness blockers.

11. **Trace useful clocks.** Reuse LatencyLedger/VoiceCommandTrace to distinguish
    local admission, semantic interpretation, native dispatch and independent
    verification. No transcript/private content or secrets in numeric traces.
    Native time is not speech-end latency. Do not claim 50 ms without actual
    speech-to-visible-effect evidence.

## Checks and milestones

Before production edits, add failure controls in the owned existing suites:
missing viewport must send zero inputs; native success must make zero chooser/
driver scroll calls; unsupported versus uncertain must control fallback; changed
target/late cancellation must prevent input; local continuous controls must
work with a semantic-provider spy that fails if called; fragmented negation/
conditions/asks must not be bypassed; follow-ups must retain native subject and
duration; barge-in must stop repetition without dropping the incoming utterance;
fresh profile/default and persisted pause/off must differ correctly.
The retained signed R7 failure is the real before reproduction.

Focused development through the existing serialized release lane:

```
scripts/verification-lane.sh c1-chooser-release-tests 'FastLaneExecutorTests|DriveLoopTests|NativeWindowWitnessTests|LocalSpeechTests|VoiceLaneAuditTests|VoiceSemanticTests|VoiceTaskCoordinatorLaneTests|UXConfigDefaultsTests|UXOnboardingTests'
scripts/verification-lane.sh c1-package-release
```

Require a nonempty intended test population, zero unexpected failures and
unchanged build/storage guards. Freeze source only after all connected changes
compile. Review the integrated delta once at G4, stage final-r8 through
`c1-package-stage`, and reuse current manifest/package controls. Bind exact
source, harness and signed candidate hashes.

Run the retained `c1-scroll.py` workload through `with-desktop-lock.py`, on the
signed candidate, with its owned target and decoy. Fix ownership/path cleanup
before reusing a diagnostic harness. Require native viewport movement in the
requested direction, unchanged document/decoy, no false completion, correct
edge/stop and restored owned windows. Three successful trials establish a
reported range/median, not broad p95 or a speed comparison with failed R7.

Then launch the real candidate for one short human hands-free session:
startup without Fn, ordinary action, varied follow-up, bounded-more, continue,
stop/pause, cancellation and recovery. Use the person's own phrasing and retain
actual timings. No scripted transcript or replay counts as live microphone proof.
The full C1 voice/accuracy/latency gates remain open until their actual evidence.

## Review criteria

R8-1: reproduction/cause and exact baseline are bound.
R8-2: native controls never use targetless input.
R8-3: native dispatch has actual platform capability and target validation.
R8-4: uncertain effects cannot retry/fall through.
R8-5: independent consequences and existing authority checks remain.
R8-6: continuous local controls bypass unnecessary semantic/planning calls.
R8-7: natural unknown language retains a real semantic route and whole goal.
R8-8: continuation/negation/asks/duration/currentness remain safe.
R8-9: barge-in cancels movement and retains incoming audio/context.
R8-10: default listening preserves explicit user choices and real readiness.
R8-11: canonical staging carries validated VAD and honest ASR blockers.
R8-12: owned scope, no provider/driver substitution, serialized gates and rollback.
R8-13: real-app/physical clocks and acceptance claims are honest.
R8-14: broader product needs stay recorded and are not declared solved by R8.

All criteria are pending until independent evidence is available. G2 judges
whether this is a concrete adequate contract; it does not award implementation,
physical or release acceptance.
