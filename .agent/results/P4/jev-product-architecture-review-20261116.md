# Jev: architecture review against the actual product

Status: working review and proposed direction, not implementation or release
acceptance. Prepared after the user's 2026-11-16 correction. Implementation
ownership remains the application track. No daily application replacement,
commit, provider change, model download, or new production edit in this review.

## The product to build

A resident Mac assistant that listens after setup, understands ordinary speech,
performs everyday controls immediately, answers questions, remembers the current
conversation, and gives longer work to agents. Fn is an optional override.
The user should not have to discover a list of sentences that happen to work.
Language coverage includes recognition, interpretation, replies, names, literal
text and switching languages, not just an ASR model's advertised language count.

The first useful product loop is:

    Open app → finish permissions/model setup → talk
      → immediate native control OR a conversational answer OR a longer task
      → natural follow-up → interruption/stop → keep listening

Successful completion of this loop is the delivery unit. A sequence of
independently passing component tests is insufficient.

## What the tree and real app establish

1. **Always-on is an optional addition to a Fn product.**
   `Settings/Config.swift:150` defaults `handsFreeEnabled` to false.
   `UI/OnboardingChecklist.swift` teaches holding/tapping Fn and claims automatic
   model installation, while `Intelligence/LocalTranscriber.swift` currently
   loads local assets rather than providing the advertised installer.
   `SHIP-PLAN.md` still makes Fn/pill the first-use and C1 delivery experience.
   Those assumptions disagree with the user's current direction.

2. **Continuous capture waits before starting recognition.**
   `Voice/ConversationCapture.swift:84-85` requires 250 ms of silence.
   `Voice/ConversationContext.swift:291-353` only begins a recorded speech session
   after the utterance is sealed, then feeds the retained audio and finalizes it.
   This is continuous recording with sequential utterance recognition.
   The endpoint wait alone exceeds the user's 50 ms speech-end goal.

3. **Every ordinary continuous-mode utterance currently reaches Jev.**
   `VoiceController.swift:893-899` always calls `interpretConversation`;
   `ConversationContext.swift:407-438` uses admission policy to reject unsafe
   input but does not dispatch an already-grounded local action before inference.
   The existing Fn admission path already has local operations. The two entry
   paths give the same request different routing and capabilities.

4. **The continuous route does not provide a general dialogue route.**
   `ConversationDecision.Kind` describes task, scroll, continuation, pending
   answer, stop/pause, incomplete/ignore/clarify. Its `answer` is an answer to an
   existing task question. `VoiceController.executeConversation` submits other
   requests as computer tasks. General conversation and delegation are present
   elsewhere in the Realtime voice/agent surfaces, not joined into this path.

5. **The native scroll failure is an adapter defect.**
   The signed R7 app's first TextEdit trial took 1199.924 ms MCP request-to-reply
   and moved the viewport 0→0. It reported blocked, not a false success.
   `FastLaneExecutor.scrollRegionToken` requires an AXScrollArea token.
   The actual pinned-driver snapshot exposes AXTextArea, AXWindow and scrollbar
   buttons; no actionable AXScrollArea token is supplied.
   `CuaDriveServer` only supplies `scopedCall` when experimental model images are
   enabled, making `imageObservation` unavailable in the ordinary route.
   Without a gaze point, failure to bind a region permits a targetless
   `scroll(by: line)`. The pinned Cua implementation turns that into arrow keys.
   TextEdit caret movement is not viewport scrolling.

   Evidence: `c1-r7-real-scroll.json`, `c1-scroll-r7-native/comparison.json`,
   `c1-r7-native-inspection-2/snapshot.json`.
   No fix has been proven by the attempted token diagnostic: it failed at its
   independent document lookup before issuing input.

6. **The language classifier offers overlapping scope choices.**
   The real 29-case factory/decoder run safely avoided native actions in all
   18 negative cases, but accepted only 6/11 expected positive cases. Four
   plain scrolls fail scope Choice confidence .85/.88 while the requested-
   current-window Noul is .97-.99. The current window and its owning app compete
   as choices. “Keep going” separately fails duration Choice .88.
   Lowering a threshold or rerolling does not repair the taxonomy.
   Evidence: `c1-r7-semantic-after/` and `c1-r7-semantic-after-run2.json`.

7. **Recognition and speech output are not a broad multilingual system.**
   The pinned FluidAudio 0.17.5 Ultra model supports the 25-language Parakeet v3
   family. EOU is a separate streaming model. The local PocketTTS integration
   initializes its default English pack. `SpeechOutput` does not select a voice
   from a detected conversation language. The admitted transcript is a String
   without a language contract. End-to-end language coverage is unproven.

8. **Useful agent capabilities exist but are not reachable naturally.**
   `VoiceAgentBridge` implements persistent agent delegation, follow-up,
   memory reading and interruption. `sendToAgent` and `agentMemory` explicitly
   have no production voice tool caller. `AgentRuntime` and the vendored Codex
   bridge already maintain threads, workspaces, active turns and routines.
   These are assets to connect, not reasons to create another agent framework.

9. **Public voice tools exceed implemented capability.**
   `RealtimeVoiceClient.swift:VoiceToolCatalog` marks run_script, browser_task,
   ask_about_screen, web_lookup and inbox_brief unavailable.
   `RealtimeVoiceLane.dispatchToolV1` returns unavailable for them and for a
   computer task carrying `gaze_target`. An advisory `IntentRouter` lane is
   not an executor. Some underlying browser/AX and agent functionality exists,
   but a user-visible route to it cannot be assumed from that fact.

10. **Foreground ownership needs to be explicit across the paths.**
    `CuaConnectionPool` serializes mutations on its primary connection and
    separates reads. Agent MCP hosts have their own transports. This is not by
    itself one product-wide foreground input owner. Speech barge-in currently
    interrupts playback; the controller's `onBargeIn` does not immediately stop
    a repeating scroll. A new native fast path must participate in interruption,
    freshness and task ownership rather than bypass them.

11. **The normal package is behind the experimental candidate.**
    The regular `Makefile stage` copies the executable, Cua, Codex, notices and
    optional tracker. It does not package ConversationVAD. C1's staging helper
    adds that resource; ASR resources still resolve from external local storage.
    The R7 manifest accurately says candidate_verified=true/release_ready=false.
    Enabling listening by default without fixing readiness and packaging would
    make first launch fail more consistently.

12. **Our evidence process has been rewarding the wrong progress.**
    R7 passed source/artifact review and affected checks yet failed the very
    first real scroll. The tests encoded an AXScrollArea token assumption the
    real driver does not satisfy. C1's “6/8” count is not evidence that the
    assistant experience is nearly complete. The next boundary must demonstrate
    the complete user loop, including speech and a visible effect.

## Architecture decisions proposed

### One conversation owner

Use the existing turn/epoch authority and audio infrastructure as the owner for
continuous voice, Fn overrides and typed input. It owns transcript, language,
current referents, pending questions, active tasks, replies and cancellation.
Keep audio acquisition continuous while recognition and task work proceed.
Begin speech processing while the person speaks; preserve all final words and
corrections and dispatch only the committed request.

Speech onset interrupts assistant playback and promptly pauses ongoing
foreground control. An ordinary follow-up can resume or change it. Background
reasoning can continue when it does not own the foreground interface.
Always listening is not a claim that every nearby voice is addressing Jev.
Ambient speech, playback, corrections and overlap need actual acoustic evidence;
a text-only “addressed” score cannot establish speaker identity.

### A typed native-control path

Recognized routine controls become typed operations with the original utterance,
fresh target binding and cancellation epoch. Scroll/open/focus/key/media/grounded
click/dictation execute code. They do not enter a general UI planning loop or ask
a model to approve each tick of a scroll.

Reuse `FastAction`, native observation/field binding, NSWorkspace, macOS AX and
the existing Cua adapter. Prefer documented native controls where available.
The installed SDK documents writable AXScrollBar values and increment/decrement
actions/button attributes. Introspect actual supported actions before selecting
a route; do not assume those attributes exist in every app or use positional
button enumeration as authority.

Remove targetless-arrow fallback. Missing native subject/region proof prevents
input. A fallback must have a positively bound target and must occur before
mutation. Independently observe the viewport/effect. Conditional goals such as
“until the heading appears” remain full tasks, not one successful scroll.

Native direct execution and natural understanding are different responsibilities.
Reuse the already-safe local admission path for grounded ordinary utterances.
Jev handles unfamiliar phrasing/context in a focused semantic request, then
dispatches the same typed operation. A fixed English phrase list must never be
the product's capability boundary. Arbitrary new phrases/languages cannot be
promised zero interpretation cost. No fabricated scores or weakened gates.

### One useful task and dialogue route

Conversation/questions, UI tasks and delegation must be explicitly representable.
A conversational answer does not require a window-mutation task. Screen questions
use requested, scoped observation. Agent follow-ups and findings use the existing
bridge, with named task identity preserved. Long work reports progress and can be
interrupted without making the listening interface disappear.

Keep Jev for semantic judgments and Cua/native for execution. The user-authorized
Terra planning/generation direction and existing agent authentication remain
recorded; C2 implementation and separately billed provider calls are not silently
expanded by this review. Existing Realtime/dialogue wiring must be evaluated for
reuse before introducing another client or conversation history.

### End-to-end language support

Carry language through transcript, intent, literal text and speech output. Use
macOS speech voices for the appropriate language; do not load an English TTS pack
as the universal answer path. Native operation arguments are language-neutral.

Keep current Ultra as the measured baseline. Research identifies WhisperKit's
MIT-licensed multilingual Core ML path with automatic language detection and a
streaming interface as a concrete broader-coverage candidate. Its upstream is now
the argmax-oss-swift package; use the WhisperKit product, not the whole umbrella.
Apple SpeechAnalyzer is also a native streaming option, but supported/installed
locales must be queried and its locale coverage is not equivalent to automatic
multilingual/code-switching support.

Do one bounded compatibility/accuracy/latency/resource comparison with the chosen
broad-coverage candidate before promotion. No model tournament, invented
multilingual results or blind dependency/model upgrade. Inspect actual licenses,
pin a released version and resource hashes, retain the rollback.

### Make first use match the product

After explicit microphone/control setup, listening is the default. Preserve an
explicit pause choice. Show real listening/thinking/working/speaking/paused states.
Fn remains a convenience. Gaze is optional context, not a prerequisite for voice.
Model readiness must have a real installation/repair path and truthful progress.
Canonical packaging must contain or correctly provision the runtime resources.
Do not register an experimental candidate as a login item or replace the daily
application while preparing it.

## Delivery plan to review once, then execute

1. Freeze the product correction and native/conversation contract with an
   independent G2 reviewer. Keep one application writer. Trace remaining
   integration questions against current callers, not old comments.
2. Repair the direct native primitive boundary using the captured real-driver
   failure. Reuse the existing owned TextEdit target/decoy harness. Prove the
   effect before rebuilding surrounding interpretation. No targetless input.
3. Route continuous and Fn/typed input through one admission/control interface;
   connect conversation, pending answers and existing agent follow-ups without
   sending routine controls through general planning. Make listening/readiness
   the primary UX. Preserve exact text, finalization and independent outcomes.
4. Process speech during capture and connect language-aware input/output.
   Run the bounded broader-language provider check, then integrate the selected
   supported path through existing seams. Keep echo isolation and fast barge-in.
5. Stage one coherent reviewed candidate. Demonstrate launch/listen, native
   action, varied follow-up, stop, conversational answer, delegated work/status,
   and recovery through the actual app. One short human session after machine
   checks, not repeated P3 qualification after every patch.

Implementation contract must enumerate exact owned paths/consumers before edits.
Likely existing surfaces: Voice/{ConversationCapture,ConversationContext,
LocalSpeechSession,RealtimeVoiceLane,VoiceController,VoiceSemanticRouter,
SpeechOutput}, Intelligence/{LocalTranscriber,LocalVoice}, Drive/{FastLane,
FastLaneExecutor,NativeWindowObservation,VoiceTaskCoordinator},
Companion/VoiceAgentBridge, Settings/Config, UI/{OnboardingChecklist,VoiceWindows,
ContentView,SettingsView}, main.swift, packaging/manifest scripts and affected
existing tests. A new provider or changed cross-phase interface needs its
concrete contract, not an open-ended permission to rewrite the repository.
EyeTracking remains a separate write owner.

## Evidence, clocks and constraints

- This machine is an Apple M1 MacBookPro17,1, 8 GiB RAM, macOS 26.2.
- Record speech end→first visible effect, commit→dispatch, dispatch→independent
  readback and complete task time separately. Do not rename a 50 ms dispatch as
  50 ms speech response. Current speed targets remain unproven.
- Native-only controls require zero semantic/planner calls after a fully grounded
  local admission. Natural interpretation and larger tasks report their own calls.
- Include wrong window/document, stale context, denial, negation/correction,
  ambient/quoted speech, stop, unavailable audio/model and interleaved work.
  Missing proof must not become either an input or a success claim.
- Retain failed evidence. Use production-shaped driver data. Test changes that
  protect behavior, then move to the real application.
- Preserve daily/rollback files and source changes. Build/sign through the
  existing serialized lane, stage outside synced Documents. Free only approved
  superseded artifacts; keep the storage guards.
- C1, broad multilingual quality, physical always-on behavior and release
  acceptance are still open.

## Sources checked

- Pinned FluidAudio 0.17.5 `Documentation/ASR/ParakeetUltra.md`:
  https://github.com/FluidInference/FluidAudio/blob/v0.17.5/Documentation/ASR/ParakeetUltra.md
- TypeSafe live index, Choice and confidence guidance:
  https://docs.typesafe.ai/llms.txt
  https://docs.typesafe.ai/primitives/choice.md
  https://docs.typesafe.ai/confidence.md
- Pinned Cua 0.38 scroll implementation:
  https://github.com/trycua/cua/blob/85e2b1318bd77ccf3cfa88ccdf875a4bb7eaed19/libs/cua-driver/rust/crates/platform-macos/src/tools/scroll.rs
- WhisperKit current Package.swift/README/MIT license:
  https://github.com/argmaxinc/WhisperKit
- Apple SpeechAnalyzer explanation and locale APIs:
  https://developer.apple.com/videos/play/wwdc2025/277/
- Installed macOS SDK HIServices AXAttributeConstants.h / AXActionConstants.h.

Review coverage: source roots enumerated (106 Swift files); main runtime
composition, speech/capture/turn authority, conversation routing, native/driver
and browser boundaries, agent/companion/routine interfaces, permissions/settings,
UI onboarding/readiness, evidence contracts and canonical packaging. This does
not establish full behavioral qualification of those components.

The remaining integration questions were traced as well. Eyes currently use
one ONNX/WASM dedicated worker, with native host health/restart and calibration
interfaces; keep it optional rather than reviving retired Python/LiteRT paths.
The application's input lease is DictationDelivery.sharedLease, passed into
DriveLoop by VoiceTaskCoordinator; agent MCP hosts still have their own
transports. RealtimeVoiceLane already accepts the authoritative transcript as
text for its existing dialogue backend, but that path is tied to its own
response/admission owner and is not safely callable by merely forwarding a
continuous transcript. Reuse requires explicitly joining turn ownership,
pending input, reply events, cancellation and provider accounting.

The concrete first implementation contract is
`c1-r8-native-first-contract.md`, pending G2. It makes native control and
continuous admission coherent, corrects default listening and canonical VAD
staging, and requires a useful signed app before broader speech/dialogue work.
It does not assert that the whole assistant vision fits into that first boundary.
