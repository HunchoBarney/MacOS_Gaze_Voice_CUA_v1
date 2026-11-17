# C1 R9: restore real hands-free audio startup

G1: continuing user authorization to finish C1 and fix the poorly working
always-on product. G2: PASS, authorized read-only reviewer752c261c.
Receipt: `c1-r9-g2-review.md`.
One implementation owner. No commit, push, merge or daily-app replacement.

## Purpose and baseline

Get the signed app listening through its real microphone and speaker path.
R8's three successful native TextEdit scrolls do not establish this.

Baseline is frozen `c1-r8-source-4/manifest.json` and signed final-r8:
`~/jarvis-local/c1-candidates/jev-c1-final-r8-emv9taxw/Jev Voice.app`,
binary SHA `60a17df6d1380953cde91700e1ba88fafceb63937a564f88b37af8e39b85c7a3`.
Evidence: `c1-r8-live-59043828e3/`. Normal LaunchServices PID68856.
GUI settings reports microphone/accessibility/screen recording and models
ready, but hands-free audio fails with AVFAudio -10875. Native plain input
previously became ready in429.663458ms with actual4800frames.

`coreaudio-startup.log` records successful VPIO setup with physical input78
and output71, followed by configuration with output78 (the microphone,
which has no output channels), failed aggregates and initialization errors.
Production `MicrophoneInput.prepare` calls `input.auAudioUnit.setDeviceID`
after enabling voice processing. The input/output nodes share their I/O
unit; that property selects its output device, not the separate VPIO
input bus. The same wrong identity assumption occurs in reuse,
configuration and duplex-health checks.

Separate retained failure: cold ASR final-model loading took962545.488250ms
and partial-model loading3873.554125ms. VAD/TTS waited on the CoreML compiler
mutex; the first sample caught ASR ANE scratch cleanup/unlinkat. Models
eventually became ready. This is not a demonstrated deadlock, and this
audio-device repair must not claim to fix cold model latency.

## Reuse and bounded change

Keep AVAudioEngine, Apple's VPIO, existing shared playback routes,
MicrophoneInput's queue/generations, microphone catalog, deadlines and
verification lane. Read the installed AudioToolbox headers and Apple's
device-selection guidance. Use the public AudioUnit current-device
property on the appropriate bus for voice processing, with status checks.
Keep the existing plain-input selection behavior. No third-party engine,
new dependency, replacement model, changed compute policy or DSP framework.

Preserve the output device while binding the selected microphone; never
change system default devices. Read input and output identities separately
for reuse/configuration/health, and fail closed on unknown or changed
identity. If VPIO requires uninitializing before device changes, use the
documented stopped-engine lifecycle, not retries or arbitrary delays.
Do not change PCM/mixer formats speculatively. A further graph failure
needs its own concrete evidence before a format change.

R9 MUST extend `VoiceLiveTrial.microphonePreflight` with an opt-in
`--duplex` mode for a permanent real-hardware regression check, written
before changing the production device-binding behavior. The existing
plain-input preflight cannot satisfy this criterion.
It must require real microphone input, advancing output render state,
all three playback routes, correct device identity, and clean teardown.
It records numeric/status evidence, no raw audio or recognized words;
never label it human Fn/ASR/conversation acceptance. Preserve existing
single-input preflight behavior and opt-in guards. Its report explicitly
identifies duplex versus plain input, contains beginning/end render samples,
the observed input/output IDs and expected selected input ID, and fails
on missing identity, stalled rendering, stale input or any unavailable
playback route. Preserve failed reports rather than replacing them.
Read-only diagnostic snapshot access may be added to MicrophoneInput for
this check; do not bypass its production preparation or health path.

## Owned extension

```
Sources/JevVoice/Voice/MicrophoneInput.swift
Sources/JevVoice/Voice/VoiceLiveTrial.swift
Tests/JevVoiceAppTests/MicrophoneInputTests.swift
Tests/JevVoiceAppTests/VoiceTrialReportTests.swift
scripts/verification-lane.sh
Makefile
.agent/results/P4/jev-stage-candidate.py
.agent/results/P12/c1_manifest.py
.agent/phases/P3-voice-one-brain.md
.agent/PROGRESS.md
.agent/results/P4/c1-current-handoff.md
.agent/results/P4/c1-r9-*
```

Packaging changes only admit a separate final-r9 label and bind the
reviewed source. Models, VAD manifest, Cua0.38, signing, permissions,
policy, targeting, provider thresholds and source4/R8 artifacts stay frozen.
No EyeTracking edits. Preserve existing changes in this working tree.

## Acceptance and evidence

- R9-1: selected physical microphone is read/bound on VPIO's input bus;
  its speaker remains an output-capable device. Unknown/read/write failures
  block preparation. No implicit device substitution.
- R9-2: every identity consumer uses the same distinction; healthy reuse
  cannot accept a changed input or output. No weakening of input-frame,
  output-render freshness, graph, generation or playback-route checks.
- R9-3: actual R8 GUI failure and Core Audio trace are retained as the
  negative case. The implemented opt-in duplex preflight (mandatory,
  not optional) observes real input and advancing render state, all three
  playback routes and device identity, has nonempty assertions, and cleans
  its engine on success/failure/cancellation. A pure getter-address test
  or the existing plain-input preflight is insufficient proof.
- R9-4: affected existing tests pass through the serialized lane.
  Test/consumer changes follow demonstrated failures, not weakened bars.
  Where a meaningful isolated guard is needed, enumerate its failure
  cases and add it before the production fix.
- R9-5: fresh-context source and artifact reviews PASS. Candidate is
  built/staged outside the synced checkout, exact source/binary hashes and
  strict codesign/resources/rollback checks preserved.
- R9-6: normal LaunchServices startup of the new signed app reaches
  listening on the selected actual microphone/speaker pair, with private
  evidence. Reuse the R8 preparation method and report cold/warm/model
  conditions honestly. No speed claim from a diagnostic profile.
- R9-7: user performs ordinary hands-free conversation only after readiness.
  No scripted HID/audio is presented as human proof; G6 remains open until
  that evidence exists. Cold-model latency, dictation, multilingual
  dialogue, broader C1 and portable qualification remain explicitly open.

Investigate at most the already-observed wrong device binding, any
remaining graph initialization failure, and readiness recovery. First
bounded pass: one reviewed audio repair and one coherent signed candidate,
with focused checks and real startup. After three failed focused attempts,
reassess rather than raising deadlines or changing models.

Storage uses the existing authorization: reclaim verified regenerable
caches or share identical owned resources, preserving source/model assets,
signed baselines, current candidate, rollback and receipts. Keep the
existing low-space build guard.

Review scope compares R9 files against the frozen source4 manifest and
pre-change hashes, not against the whole inherited working-tree diff.
Existing EyeTracking and other unrelated dirt belongs to its prior owners.

## G5 finding within this scope

Final-r9's real duplex run did obtain4800input frames with0startup
recoveries, establishing that the device-binding failure was removed.
It then failed to finish the observation/teardown. Retain
`c1-r9-duplex-attempt-1.json`, `c1-r9-duplex-native.log` and the native
sample. All578 microphone-queue samples were in the two
`outputNode.inputFormat(forBus:0)` calls, sleeping inside AUV2BridgeBus
format. Per-buffer metadata callbacks accumulated behind those reads.
No complete probe report or G5 PASS was produced; the owned process was
stopped and its absence verified.

The second coherent R9 candidate replaces that query with the equivalent
public AudioUnit StreamFormat read (input scope,output bus0,ASBD), checking
status, returned size, finite positive rate and nonzero channels. No PCM
setting changes. Coalesce metadata notifications per tap to at most one
queued/in-progress check; append every audio buffer to the existing gate
before coalescing, so speech is not dropped. Preserve current device,
graph, render-advancement, generation and stale-output checks.
The unchanged real duplex preflight remains the before/after guard;
its existing lane gains a30second owned-child timeout so a native stall
cannot hold the desktop lock indefinitely. Timeout is failure, never
readiness. Use new frozen source and `final-r9-2`; retain the first source,
binary, reviews and failed attempt. This is the observed second-failure
refinement permitted above, not a new engine, model, compute or DSP choice.
