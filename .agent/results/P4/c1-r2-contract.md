# C1 R2: continuous voice with current-action context

G1 is the user's explicit request for always-on fluent conversation, including
“scroll down a little”, “keep scrolling” and “stop”, while C1 repair continues.
G2 prospective PASS from independent reviewer ecb273c5 on amended contract.
Original bytes: c1-r2-before-1c630877/manifest.json. One implementation owner.
No commit, push, merge, daily-app replacement or distribution.
R1 A/B/C source passed249 consumers. D has separate approved G2 and is being
repaired; R2 does not replace those gates or grant C1 acceptance.

## Product behavior

A persistent Hands-free setting and visible Listening/Pause/Resume controls
own an explicit listening session. Demonstrate enabled mode in the candidate
through its normal UI. Preserve Fn, Fn+Ctrl dictation and the microphone test.
Honor microphone permission and the user's paused/muted state. Do not silently
enable a hidden microphone mode on installation. A selected mode may resume on
later launch with its indicator visible.

Speech is segmented locally and the accurate existing Ultra model supplies
each final transcript. Every automatic utterance is recorded as microphone
input, never typed input or physical Fn. New utterances can arrive while the
last command or final decode runs. No partial transcript dispatches an action,
including cancellation. Silence, model/transport errors, overflow and stale
callbacks never authorize commands.

Follow-ups use this conversation's current authorized action, not the debug
task selection or a globally recent unrelated task. Relative scroll amounts
and directions are typed judgments over the actual utterance and current
context. “Keep scrolling” continues the current scroll until stop, a new
computer instruction, an edge, changed scope, failure or uncertainty. Each
increment uses fresh target checks and independent readback; no blind retry.
Spoken stop cancels current conversation work and queued automatic commands,
while listening remains available. Pause/mute also stops continuous scrolling
so the user is not left with an action that cannot hear cancellation.

General computer instructions such as “add seven plus six” can reach the
existing Jev/Cua task loop with their original text and captured target.
Jev remains primary; no app-specific enablement, Terra integration or model
replacement. Questions/quoted commands/negation must not become computer use.
Existing denials, confirmation and sensitive-action controls remain mandatory.

## Reuse and architecture

Use pinned FluidAudio0.17.5 `VadManager.processStreamingChunk`,
`VadStreamState` and sample-index events, Apple AVAudioEngine voice processing,
and existing MicrophoneInput, ConvertedAudioFeed, LocalSpeechSession,
LocalTranscriber, RealtimeVoiceLane and task ownership machinery.
No FluidAudio/EyeTracking/Cua source or version change, no synthetic audio,
dummy models, amplitude-only endpointer or separate general LLM cleanup.

1. A conversation capture owner keeps one microphone feed open across turns.
   It resamples with existing audio conversion and feeds complete supported
   VAD chunks, retaining remainder frames. SDK events delimit actual PCM.
   Retain pre-roll for speech onset, clamp it after the prior sealed segment,
   and retain frames after each endpoint for the next utterance. Idle storage
   is bounded; unconsumed speech is not trimmed to manufacture success.
2. Capture target/context at speech onset. Queue complete utterances in order
   independently of final ASR and task execution. The existing provider and
   LocalSpeechSession gate perform real frame consumption, finalization and
   admission. Do not call submitTyped or turn a partial into a final. If needed,
   add an explicit final-only provider entry preserving the same Ultra decode
   and cancellation checks rather than unnecessarily queuing EOU previews.
3. Every capture/session/segment has an owner epoch. Late callbacks, old
   decodes and paused/overridden sessions cannot submit. A bounded backlog or
   existing single-utterance audio safety limit fails visibly and cancels
   unadmitted work; it never cuts an instruction and executes the fragment.
   Use SDK sample indices, not callback-arrival wall time, for audio boundaries.
4. Keep current UI capture ownership separate from buffered utterances. The
   next utterance must not invalidate a prior authorized final merely because
   its audio started sooner than ASR completed. Process admissions in order;
   retain R1's old-outcome/current-capture isolation.
5. Fn temporarily overrides automatic input, revokes queued automatic work and
   pauses continuous scrolling. Resume automatic capture at manual release,
   buffering fresh audio while manual finalization completes; do not repeatedly
   close/reopen the mic between ordinary automatic turns. Dictation remains
   literal apart from its explicit mode-exit control; it cannot be routed as
   general computer commands.
   Preserve localSpeechWindow's manual-command-only bracket: open exactly once
   for that manual capture and close on its finish/cancel/failure. Automatic
   input never opens it, and an old close cannot close a newer manual bracket.
   Do not send automatic PCM into the legacy localSpeechSink tee or dictation.
6. Route all Jev-generated playback (RealtimePlayer, LocalVoice/PocketTTS and
   SpeechOutput) through the same voice-processed AVAudioEngine output while
   listening, using a small Sendable playback route over the existing serial
   audio owner. Preserve playback generations, completion/interrupt accounting,
   device selection and manual-mode behavior. Apple voice processing must be
   enabled with the engine stopped. Unsupported/unhealthy duplex capture makes
   hands-free unavailable rather than falling back to unsafe raw automatic
   command input. Barge-in and spoken stop remain available during playback.
   Do not substitute a text-echo guess or pause all listening during speech.
   Production readiness is explicit: while the engine is stopped enable voice
   processing on its I/O; connect the shared playback/mixer to that engine's
   output; verify both I/O nodes report voice processing, expected live device
   identity and usable formats. After start require fresh input frames and
   advancing output render time from the same engine generation. Only that
   duplex-ready receipt plus ready VAD/ASR permits automatic admission.
   A route/configuration change invalidates the receipt before further input.
   Startup failure/timeout or a speaker that cannot use the route leaves
   Hands-free unavailable in VoiceController and the UI, with manual fallback
   available by explicit Fn. These checks establish route availability, not
   acoustic echo quality; the real playback/barge-in gate proves the latter.
7. Extend the existing semantic router with typed computer/scroll/continuation/
   stop/pause outcomes and independent validity/target judgments. Keep observed
   app-focus admission intact, and preserve original transcript/literals.
   Typed scroll direction/amount/continuation uses structured parameters.
   Context is observed action/target/outcome data, never new authority.
   Automatic input is explicitly labelled hands-free conversation rather than
   pretending it was a dedicated physical command. Do not reuse implicit
   bare-app-name focus shortcuts as automatic authority. Before automatic
   mutation, a batched Jev judgment must establish a complete addressed
   instruction and its operation/scope at the existing confidence bar.
   Incomplete fragments stay uncommitted and retain their negation/context
   for the following utterance; a later fragment cannot silently lose them.
   Final exact stop/pause controls remain locally available without a network
   dependency. They cancel/pause owned activity, never execute a partial.
8. Keep the current scroll anchor as internal, non-model provenance:
   PID/window/native region/document and last verified viewport. A fresh
   follow-up must match its captured current scope. Automatic continuation
   stops on changed subject, position interference, cancellation or uncertainty.
   An explicit later request may authorize a fresh action after new binding;
   it cannot retroactively turn an unknown earlier outcome into success.
9. Continuing work has one task/cancellation owner and waits between verified
   increments. It does not monopolize the input/semantic lane or run a burst
   of unchecked RPCs. New computer instructions supersede the repeat loop;
   unrelated background work is not cancelled.

## Model/resource binding

Silero VAD is an existing SDK facility, not an ASR promotion. Inspect its
installed shape and current upstream license before use. Bind the real VAD
model revision, files, hashes, license and package location alongside existing
speech resources. Prefer an existing verified local model. Load a verified
packaged model explicitly; no runtime silent model downloads or cache/checkout
dependency. Preserve existing speech model/driver identities. Record this
resource addition in the candidate manifest and required-resource controls.

Live references consulted: docs.fluidinference.com/vad/streaming and
/asr/streaming; installed VadManager+Streaming.swift and VadTypes.swift;
Apple WWDC2019/510 and WWDC2023/10235 (AVAudioEngine voice processing).
Native duplex output provides the echo reference; separate playback engines
are route-dependent and not adequate evidence of self-echo protection.

## Owned paths and consumers

Source (only as needed):

- Sources/JevVoice/Voice/ConversationCapture.swift (new)
- Sources/JevVoice/Voice/ConversationContext.swift (new only if needed)
- Sources/JevVoice/Voice/MicrophoneInput.swift
- Sources/JevVoice/Voice/RealtimeAudioEngine.swift
- Sources/JevVoice/Voice/RealtimeVoiceLane.swift
- Sources/JevVoice/Voice/LocalSpeechSession.swift
- Sources/JevVoice/Voice/VoiceSemanticRouter.swift
- Sources/JevVoice/Voice/SpeechCapturing.swift
- Sources/JevVoice/Voice/SpeechOutput.swift
- Sources/JevVoice/Voice/VoiceController.swift
- Sources/JevVoice/Intelligence/LocalTranscriber.swift
- Sources/JevVoice/Intelligence/LocalVoice.swift
- Sources/JevVoice/Settings/Config.swift
- Sources/JevVoice/UI/SettingsView.swift
- Sources/JevVoice/UI/ContentView.swift
- Sources/JevVoice/UI/VoiceStyle.swift
- Sources/JevVoice/UI/VoiceWindows.swift
- Sources/JevVoice/Drive/VoiceTaskCoordinator.swift
- Sources/JevVoice/Drive/DriveLoop.swift
- Sources/JevVoice/Drive/FastLaneExecutor.swift
- Sources/JevVoice/Drive/NativeWindowObservation.swift
- Sources/JevVoice/Contracts/JevContracts.swift
- Sources/JevVoiceCore/Speech/VoiceTurn.swift
- Sources/JevVoice/Support/VoiceTurnEvidence.swift
- Sources/JevVoice/main.swift (startup/settings/playback composition only)
- Sources/JevVoice/Voice/FnInput.swift (FnInputMonitor/manual override wiring only)

Existing LocalSpeechTests, RealtimeVoiceLaneTests, VoiceLaneAuditTests,
VoiceSemanticTests/LiveTests, VoiceTurnTests/EvidenceTests, FastLaneExecutorTests
and Config/settings tests are the test homes. Prefer these over new test files.
Explicit integration test homes are:

- Tests/JevVoiceAppTests/MicrophoneInputTests.swift: duplex preparation,
  unhealthy route, generation invalidation and device/permission transitions.
- Tests/JevVoiceAppTests/RealtimeVoiceLaneTests.swift: playback route/interrupt/
  completion accounting, capture queue and Fn/automatic handoff.
- Tests/JevVoiceAppTests/VoiceLaneAuditTests.swift: VoiceController, its existing
  FakeSpeaker seam, truthful UI/cancellation and localSpeechWindow ownership.
- Tests/JevVoiceAppTests/LocalSpeechTests.swift: provider finalization and the
  existing LocalVoice/LocalVoiceEngine speech playback consumers.
- Tests/JevVoiceAppTests/VoiceOneBrainTests.swift and VoiceToolResultTests.swift:
  no duplicate speech/actions and old-response/current-input isolation.
- Tests/JevVoiceAppTests/FnInputStateTests.swift, FnInputMonitorReleaseTests.swift,
  UXConfigDefaultsTests.swift and UXOnboardingTests.swift: manual override,
  persisted listening controls and permission behavior.

SpeechSynthesizing is defined in the already-owned
Sources/JevVoice/Contracts/JevContracts.swift:287. Production implementations
are SpeechOutput and LocalVoice; the existing test implementation is
VoiceLaneAuditTests.FakeSpeaker. VoiceTestingSupport.swift does not exist in
this tree (the first G2 review's proposed location was incorrect).
Keep this public seam compatible where possible; any added playback-routing
capability must be checked by readiness and all real implementations.

Existing scripts/verification-lane.sh, C1/P3/P4/P12 capture, manifest, staging,
report and verification files may receive scoped changes; new generated
evidence/model resources stay in approved ignored/private locations.
Exact resource/staging ownership:

- .agent/results/P4/jev-stage-candidate.py and jev-clone-stage.py
- .agent/results/P12/c1_manifest.py and test_c1_manifest.py
- .agent/results/P12/component-manifest.json and speech-attribution.md
- .agent/results/P12/c1-r2-vad-resource.json (new pinned resource receipt)
- scripts/sign-app.sh (resource inclusion/verification only; no trust change)
- Package.swift only if SwiftPM resource inclusion actually requires it.

The existing candidate stager copies resources before signing and the existing
manifest's REQUIRED/MODEL_MEMBERS controls assert package contents. Add VAD
through those paths, with its license and immutable revision/hash receipt.
Resolve packaged VAD explicitly in the owned model/capture source, independently
of the incumbent ASR Application Support location. No speculative Package.swift
change or unlisted staging script is authorized. Lost/tampered/missing VAD must
fail the resource check and leave automatic listening unavailable.
Update .agent/CONTRACTS.md Decision Log, plans/progress and handoffs.

Consumers: manual and automatic microphone input, local/semantic/remote
admission, immutable VoiceAdmission/turn identity, asks, literal dictation,
background work, all three playback paths, settings/pill/card, input evidence,
native scroll, both DriveLoop factories and signed resource preparation.
No new external publishing, secret handling, subscriptions or provider caps.
Any additional production paths or new cross-phase interface need amendment.

## Failure cases and verification

Before implementation, record originals and write necessary ownership/boundary
controls in existing tests. Reproduce current absence of automatic segmentation,
follow-up routing and self-echo protection. Pure state controls do not substitute
for real model/microphone proof.

- Consecutive utterances across a slow final/semantic result: no lost,
  duplicated or reordered speech; stale/paused callbacks rejected.
- Exact final words, negation/correction, literals and same-utterance scope.
  Boundary splits cannot turn an incomplete/negated fragment into an action.
- Quiet room/idle, non-speech, long utterance and full queue: bounded resources,
  no invented final, visible failure instead of partial execution.
- Microphone/device change, permission loss, sleep/wake, Fn override and
   dictation transition: ownership/cancellation preserved, no pending replay.
- Jev playback while listening: self-echo cannot create commands; real user
  speech, including stop, remains receivable. Preserve playback accounting.
- “Scroll down a little” -> “keep scrolling” -> “stop”, reversed direction,
  other conversation/diagnostic task, changed window/document/region, edge,
  unknown effect and stop during an in-flight dispatch.
- New computer command supersedes repeat; generic Calculator request uses
  existing native/Jev control; unsafe/quoted/ambiguous utterances do not.
- UI Listening/Pause/Resume and outcomes are truthful and accessible.

Use actual recorded speech with real local models for replay/boundary evidence;
no synthetic audio/model stand-ins. Run affected consumers during development,
then one full frozen lane and packaged controlled desktop checks under lock.
Record continuous speech-end/endpoint/final/admission/effect clocks separately
from physical Fn. Reuse C1 baseline/harness and retain all failures/regressions.
Measure idle/active resource use, queueing and stop delay without inventing
p95/reliability from small samples. Existing Fn accuracy/speed requirements
are not replaced by automatic-mode measurements.

Final candidate gets independent G4 and one short grouped human try through
Fn/pill plus conversation. Frozen candidate/source/resources/report must agree.
No C1 acceptance claim until its actual remaining evidence gates are reconciled.

## G2 review history

ecb273c5 attempt1: FAIL. Required explicit playback seam/consumer ownership,
native duplex readiness/failure wiring, exact resource paths, integration test
homes and the manual localSpeechWindow bracket. The amendment above addresses
those requirements. The cited VoiceTestingSupport.swift was disproven against
the actual tree; the real protocol and implementations are identified instead.
ecb273c5 attempt2: PASS. The reviewer confirmed all five mandatory corrections
against actual source. R2 implementation is authorized under this contract.
