# C1 R10: Realtime is the normal voice path

G1 is the user's explicit direction after R9: use OpenAI realtime voice
instead of making local speech the required path. Native routine controls
and Jev/Cua unfamiliar work remain. This provider decision is approved;
no further provider-choice confirmation is required. G2 PASS: reviewer
87dfafed accepted the revised concrete replacement/consumer amendment.
One implementation owner; authorized independent read-only reviewers,
one at a time. No commit, push, merge, or daily-app replacement.

## Baseline and purpose

Final-r9-2 main SHA
79e8859b32d849e2777c741cefec099123cae9e18a6d081de8bab440cabb276b,
source2 manifest c644155e74591ee1b8c59747e342f9d4b818040c5367cc9457eaf385508de98f.
Actual duplex report56EE09AF-A884-4779-B3BB-532D6F421DA0 passes input78,
output71, advancing render, three playback routes and clean teardown.
Do not re-debug or replace that audio adapter.

Normal GUI evidence c1-r9-live-9c2ce0942c: final local models took
61336.829833ms; partial models2180.256542ms. An automatic1.1s segment
returned emptyFinal and permanently stopped hands-free. Its exact AX
message and event chain are in the current handoff. Earlier962545.488250ms
model startup and other failures stay preserved. None is a matched speed
win or human conversation acceptance.

The result is a normally launched signed app that listens without Fn,
answers conversationally, performs grounded native controls, accepts
follow-ups and spoken interruption, and does not load local ASR/VAD/TTS
models to reach readiness. Fn and literal dictation remain usable.

## Reuse decision and provider contract change

Reuse RealtimeVoiceClient's URLSessionWebSocketTask, GA protocol, confirmed
session update, PCM16/24k transport, decoder, keepalive and failure
handling. Current official docs name gpt-realtime-2.1, already the client
default; retain it and marin, no model tournament or new SDK.
Sources:
- https://developers.openai.com/api/docs/guides/realtime-conversations
- https://developers.openai.com/api/docs/guides/realtime-vad
- https://developers.openai.com/api/reference/resources/realtime/server-events
- https://developers.openai.com/api/reference/resources/realtime/client-events

The existing confirmed session currently disables server turn detection
and its lane discards remote input transcripts. Merely enabling VAD would
create responses without a host-owned turn. Replace that coupling:
semantic_vad with eagerness auto, create_response false; retain explicit
client cancellation/truncation so response authority precedes generation.
Enable GA input transcription, gpt-4o-transcribe, with automatic language
detection. Capture receives server speech-start/stopped/committed/final
events keyed by connection and input item. A partial transcript never
authorizes anything. A final without its matching current committed item
never authorizes anything, regardless of event order.

The authoritative final may now be the matching Realtime input
transcription rather than only local ASR. Tool arguments, generated answer
text, and observed screen content cannot replace it. Record this decision
in PROGRAM/CONTRACTS and review every listed consumer. Reuse VoiceTurnGate,
LocalSpeechSession's provider-independent admission operations,
VoiceResponseAuthority, the nine-tool validation/result protocol and
existing native execution. Do not manufacture local PCM or decoder
evidence for a cloud transcript. Model provenance stays explicit.

Reuse ConversationContext/ConversationSession for verified scroll
references, one cancellable continuous scroll, onset target capture,
negative fragments and fresh-scope validation. Add external-final input
without starting ConversationCapture/Silero or LocalTranscriber. Clear
native actions and their verified follow-ups keep the direct path.
Unresolved dialogue goes to the existing Realtime response/tool path;
computer_task keeps the original final words and reaches existing native/
Jev execution with captured context. Questions and answers use the
Realtime conversation, rather than being forced into a desktop action.
An unrelated failed request still invalidates an older scroll reference.

## Required invariants and lifecycle

### Concrete replacement and consumer amendments

G2 reviewer87dfafed initially returned FAIL because the previous wording
did not tie the replacement to all production callers. These are mandatory
implementation/acceptance points, not optional helpers:

- RealtimeVoiceLane.prepare, currently855-861: remove speechSession.prewarm
  from the default path entirely. Realtime is the production default;
  legacy/local capture is an explicit diagnostic selection. A default
  session's admission owner has no LocalTranscriber provider, so even
  constructing it cannot instantiate/warm local speech models.
- VoiceController.prepareMicrophone/startHandsFree and
  RealtimeVoiceLane.startConversation: replace conversation.prepare and
  local start/feed wiring with native duplex preparation plus confirmed
  Realtime configuration. Default hands-free MUST NOT call
  ConversationCapture.prepare/begin/consume or recognizeNext/finishCapture.
  ConversationCapture/recognizeNext remain reachable only by explicit
  legacy/recording diagnostics. Do not run both segmentation paths.
- Reuse ConversationSession's context, final queue, process, controls,
  execution and repetition, but give its production startup an external
  event entry point. Server speech-start captures one UUID/onset context;
  commit/final correlation admits that turn into the same process path.
  It does not manufacture a VoiceUtterance/audio sample array. Any local
  acknowledgement payload is optional and present only for local capture.
- Add explicit provider-independent remote-final admission methods to
  LocalSpeechSession: beginRemoteCapture binds the gate token, mode and
  onset context WITHOUT provider.prepare/begin; finishRemoteCapture uses
  release/finalize and fresh context only for the ledger's matched final.
  Its evidence identifies Realtime connection/item, not local ASR or
  synthetic PCM counts. Local capture/drain assertions are unchanged.
- In RealtimeVoiceLane.handleWire replace the default transcript drop at
  584-585 with that correlated path. A ledger holds connection/session/
  epoch, server item, local turn UUID/token, mode, captured context, commit
  acknowledgement and terminal transcript. Either commit or final may
  arrive first; neither alone admits. Failed, empty, duplicate, stale,
  unknown, assistant-output and superseded events cannot admit.
- Readiness waits for the session.updated confirming BOTH the selected
  turn-detection mode and input-transcription configuration. The continuous
  PCM producer starts only after that acknowledgement and native route
  health. An input item from before it cannot become an owned turn.
- Update RealtimeVoiceClient.instructions and catalog description from
  “local transcript” to host-authorized final user transcript with source
  identity. Keep verbatim critical values and the nine-tool v1 shape.
  PROGRAM/CONTRACTS/SHIP-PLAN/REUSE and source consumers must agree.
- All continuous finals, including questions, first go through the common
  process's negative-fragment, ask, epoch, captured-scope and admission
  checks. Expose/reuse ConversationContext.localDecision for a no-model
  native result. Only unresolved eligible finals can arm a Realtime
  response. A computer_task result must return to the existing desktop
  decision/execution path with the same original final, owner and captured
  context, not re-submit it as an unrelated typed turn. Resolve references
  only against captured verified context. Clear prior references when a
  new unrelated request fails. Non-actuating answers never acquire native
  action authority or a new input item.
- Realtime speech-start also revokes an earlier response authority lease,
  cancels pending response/tool output and cancels/truncates playback.
  Preserve already-accepted task ownership/results; no late response may
  execute under the new turn. Pause, device/permission/connection changes
  invalidate every pending input item and its gate.
- Update RealtimeVoiceLaneTests147-169 for the provider choice: the
  local-only rule stays true in explicit local diagnostics; the default
  remote mode accepts a matching committed remote dictation final exactly
  once. Test final-before-commit and commit-before-final, wrong item/
  connection/epoch, duplicates, transcript failure and zero response/tool
  creates for dictation. Fn uses this same remote-final method, with
  manually committed audio and confirmed manual turn-detection mode.
- VoiceController.speak/presentConversation/task feedback, currently
 318-344 and automatic-capture outcome handling, route default speech
  through existing Realtime outcome-only output with tools disabled.
  Local/system speaker selection remains explicit legacy/diagnostic only;
  no default LocalVoice warm-up or silent TTS fallback. Keep mute and AEC.
  A direct native outcome enters conversation context as an outcome,
  never as a fabricated user input/command.
- Prove the default path with a local provider that throws if ANY prepare,
  begin, consume or finish is reached, plus a no-local-model normal app
  configuration. A mere new helper test cannot satisfy this acceptance.
  Inspect startup/init, speech settings and package-required-model checks
  for the same dependency, not only startConversation.

1. Listening requires current microphone permission, healthy shared
   duplex graph, ready output routes and confirmed Realtime session.
   Send microphone PCM only while the user has enabled/resumed listening.
   No local model warm-up, download or decoder is a prerequisite.
2. Bind each server item to one session/epoch, UUID and onset context.
   Match committed/final events even when final arrives first. Dedupe
   items and calls; reject unknown, stale, reconnected or cancelled IDs.
   Keep bounded backpressure and explicit failure, not silent audio loss.
3. Use one admission per final. Preserve critical strings, negation,
   final words, current asks, target identity and exactly-once execution.
   Response creation must be armed to that turn before accepting output
   or a tool. Do not auto-replay user commands after reconnection.
4. An empty/unrecognized item has no command and no successful outcome;
   clear only that item and keep healthy listening. Auth, transport,
   audio loss, permission and echo-route faults remain fail-closed with
   a useful state. A bounded reconnect creates a fresh authority epoch.
5. User speech interrupts output promptly, cancels/truncates the owned
   response, and prevents late tools/audio from resurrecting it. Spoken
   stop/pause and Fn/Escape use the existing cancellation controls.
   Do not restart an older continuous scroll after another request.
6. Fn is an optional manual turn on the same remote transport. Reconfigure
   turn detection with a confirmed update, preserve the press-time audio
   head through existing pre-roll, and commit exactly once on release.
   Fn+Ctrl inserts only its final transcript, once, into the captured
   validated field. Dictation must never produce a tool response.
7. Realtime speech uses the existing shared playback route/AEC. Preserve
   mute, pause, device changes, sleep/lock and permission revocation.
   Do not invoke local TTS on normal Realtime replies or task feedback.
   Accepted work is not completed; outcomes cannot grant another action.
8. Keep existing separately billed-service controls and diagnostic
   opt-ins. Jev has no artificial request/spend cap. Read keys through
   existing Keychain/config; no values in logs or evidence.
9. UI states the active voice service and when audio is sent. Remove
   local-model-required and mandatory-Fn wording from the default flow.
   Missing/invalid OpenAI credentials have an actionable state. Preserve
   explicit user pause/off and spoken-reply preferences.
10. Retain local implementation only for explicit legacy/diagnostic
    selection and preserved comparisons; it is not an automatic fallback
    that silently changes accuracy, privacy or readiness. Existing local
    assets/evidence remain. Package manifests distinguish optional local
    speech assets from default-runtime requirements; preserve all other
    model, Cua0.38, license, signature and rollback checks.

## Owned files and consumer review

Sources/JevVoice/Voice/{RealtimeVoiceClient,RealtimeVoiceLane,
ConversationContext,LocalSpeechSession,VoiceController,VoiceLiveTrial,
VoiceRemoteTrial,VoiceRemoteLiveWire,VoiceReplay}.swift as needed;
Sources/JevVoiceCore/Voice* only where the authoritative-final contract
requires it; existing Settings/Config and voice settings/onboarding
copy; existing Support/VoiceTurnEvidence and normal qualification;
main.swift only where default readiness/startup requires it.
Matching existing Tests/JevVoiceAppTests and Tests/JevVoiceTests files;
scripts/verification-lane.sh; existing P4/P12 packaging/resource helpers;
.agent/{PROGRAM,CONTRACTS,SHIP-PLAN,REUSE,PROGRESS}.md;
.agent/phases/P3-voice-one-brain.md; current handoff; c1-r10-* artifacts.
No EyeTracking or unrelated inherited changes. Inspect exact consumers
before editing. Frozen source2/native audio remains the starting point.

## Checks and finish

First write guards against the existing transport boundary and admission
tests, before production changes: ready without a local provider; silence/
empty final followed by a valid turn; reordered/duplicate/stale item and
tool events; barge-in/reconnect; native follow-up and stale reference;
literal dictation with no response; denied mic/invalid auth/output loss.
Use existing fake wire only for the nondeterministic service boundary.
These are protocol guards, not human microphone proof.

Compile and run affected checks through the serialized lane, freeze one
coherent candidate, then source/artifact review. Reuse valid R9 native
and R8 viewport evidence for unchanged dependencies.
Real signed-app check must use normal LaunchServices, no required local
assets/models, confirmed live Realtime session and actual microphone/
playback. Retain observed source/binary, startup states and failures.
Then the user tries ordinary conversation, a native action and follow-up,
interruption, and literal dictation in their own words. No scripted audio
or typed request counts as physical human proof.

Time-to-listening and speech-to-effect use the same real front door and
timing boundaries on both sides; report distributions/conditions without
rounding in our favor. The prior failed baseline remains a failure.
No50ms, multilingual/category, portability or whole-C1 claim without
its required evidence. Preserve the open cold-model/legacy-local finding
as such; removing it from the default path is not fixing its internals.
