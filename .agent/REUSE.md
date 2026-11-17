# Open-source-first implementation decisions

User directive, 2026-11-15: use free open-source projects before building
anything from scratch. This is a standing implementation rule, not a
suggestion to investigate after writing a replacement.

## Selection rule

1. Reuse working repository code and documented platform APIs.
2. Look for a maintained free open-source implementation of the missing
   capability. Prefer the smallest dependency that meets the real contract.
3. Compare integration cost, license/redistribution, maintenance, macOS/M1
   support, latency/resources, cancellation and authority semantics.
4. Reuse directly or write a thin product adapter. Extend an existing
   package or make a scoped upstream-compatible patch before creating
   another engine, protocol stack, runtime, harness or framework.
5. Write new implementation only for a documented gap. Record the
   alternatives, exact unsupported requirement and minimum custom scope
   in the phase's G2/Decision Log before implementation.

Do not equate available source, a free trial or a cloud free tier with
open-source licensing. SDK licensing does not cover model weights,
bundled binaries, transitive dependencies or paid inference.
Existing OpenAI/TypeSafe policy and request budgets still apply.

Pin the adopted release/commit and preserve notices. A newer release is
a research candidate, not permission to upgrade a working integration.
Use a bounded search: the existing implementation and at most two serious
alternatives per gap first. Stop when a candidate satisfies the contract.
No star-count contest, speculative migration or new dependency solely to
avoid a few lines of ordinary product glue.

## Current inventory and intended use

C1-R10,2026-11-16: the user selected OpenAI Realtime for default voice.
Reuse the existing URLSessionWebSocketTask/RealtimeVoiceClient GA adapter,
gpt-realtime-2.1/marin, PCM24k, shared native duplex playback, turn/response
authority and common conversation processing. Add only server-VAD/
input-item correlation and provider-independent final admission. Current
official realtime-conversations/realtime-vad/client/server event docs were
checked; input transcription uses gpt-4o-transcribe without forcing a
language. This is a paid hosted service, not open-source inference.
No new SDK, speech framework, model tournament or automatic local fallback.
FluidAudio/model assets stay for explicit legacy diagnostics/comparisons.
G2 PASS87dfafed; `results/P4/c1-r10-realtime-contract.md` owns consumers,
exact startup replacement and signed/human proof. No implementation claim.

Checked primary repository metadata/releases and documentation on
2026-11-15. Research HEAD is recorded below to make the inspection
identifiable; it is not an installed or approved pin.

| Need | Existing/reusable project | License and inspected version | Plan decision |
|---|---|---|---|
| Local speech and TTS | [FluidAudio](https://github.com/FluidInference/FluidAudio) | Apache-2.0; installed Swift pin 0.17.5; upstream latest v0.18.3 | P3 uses existing streaming/finalization and PocketTTS support. Inspect a newer version only for a demonstrated gap; preserve exact-word accuracy. |
| macOS actuation/AX/capture/recording | [Cua](https://github.com/trycua/cua) | MIT; local source notice verified; installed pin 0.38, separate 0.45.4 candidate | P4/P12 reconcile and extend the existing driver. Monorepo latest `cua-spaces-v0.36.20` is not a driver-version recommendation. |
| Native reference semantics | [agent-desktop](https://github.com/vercel-labs/agent-desktop) | Apache-2.0; latest v1.3.1 | Reuse snapshot-qualified ref, completeness and stale-ref ideas/code when compatible. A replacement driver requires a demonstrated gap plus matched A/B; do not rewrite Cua to imitate a demo. |
| Chrome tooling | [Chrome DevTools MCP](https://github.com/ChromeDevTools/chrome-devtools-mcp) | Apache-2.0; latest chrome-devtools-mcp-v1.13.0 | P7 consumes P2b's choice; persistent real-profile attachment and bundled node. Pin after API/compatibility review. |
| Browser execution patterns | [Browser Use](https://github.com/browser-use/browser-use) | MIT; latest 1.0.5 | Reuse compact state/session/DOM helpers where compatible. Its model-written Python REPL and automatic interactions do not inherit Jev permission to execute arbitrary code or acknowledge dialogs. |
| Responses Swift client | [MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) | MIT; current Responses documentation and 0.5.2 release notes inspected | First P5 SDK candidate: check exact computer-use events, safety checks, cancellation, streaming, tool arguments and transport support. Product `OpenAIResponsesClient` should adapt the SDK. |
| Alternate Swift client | [SwiftOpenAI](https://github.com/jamesrochabrun/SwiftOpenAI) | MIT; current Responses/streaming documentation inspected | Second P5 candidate only if the first misses a required contract. Both are community SDKs, not official OpenAI Swift SDKs. Freeze a tag before adoption. |
| Eye inference | [ONNX Runtime](https://github.com/microsoft/onnxruntime) | MIT; repo web runtime 1.30.0; upstream latest v1.32.0 | P8 promotes the P2a node/Core ML approach using the compatible validated version. Do not infer camera FPS from seeded model inference or upgrade automatically. |
| Background/complex agent | [Codex](https://github.com/openai/codex) | Apache-2.0; upstream latest rust-v0.169.0 | Preserve P2c app-server integration and packaged pin. Proprietary hosted models/desktop host components have separate terms and costs. |
| TTS model/runtime reference | [Pocket TTS](https://github.com/kyutai-labs/pocket-tts) | MIT repository; latest v4.0.1 | Preserve existing FluidAudio/AVSpeech path. Separate weight-license and artifact review before distributing any different model. |
| Browser/Electron verification | [Playwright](https://github.com/microsoft/playwright) | Apache-2.0; latest v1.65.1 | Optional test-only driver/profiler where existing real-app harness lacks a concrete measurement. It does not prove native Fn/microphone behavior. |
| Native application operations | Accessibility, EventKit, Apple Events, Shortcuts, AVFoundation, URLSession | Apple platform APIs, not described as open-source projects | P3/P6/P10 use supported platform functions rather than rebuilding OS facilities. No developer toolchain required in the distributed app. |
| Plans, bench, results and timing | Existing `.agent/`, `bench/`, verification lane, desktop lock and LatencyLedger | Already part of this repository | Extend existing seams; do not add another agent orchestrator, benchmark framework or bespoke results dashboard. |

Repository HEADs returned during inspection:

| Repository | Research HEAD |
|---|---|
| FluidInference/FluidAudio | `16780f04d2ece24f67d0fc00efccd0296491c1a8` |
| trycua/cua | `a459181d859143d33beffb21c654eb33d756012b` |
| ChromeDevTools/chrome-devtools-mcp | `8ba2ac945ebaf1adb92208c29f3a30e73a920956` |
| browser-use/browser-use | `085759dcd00f8d85534653502ba7ad6885decfdc` |
| vercel-labs/agent-desktop | `8ffecc1d3d088727f8d84baf4dde0224aab2e8ad` |
| microsoft/onnxruntime | `d889b8bdebd234bcf8d343aa6b4deae5d729d42d` |
| openai/codex | `a394ff9cf66e9c17258077e8f8295178ca0c2025` |
| kyutai-labs/pocket-tts | `9e8413ebc128dcbef682cce1906c7135f5b1e281` |
| microsoft/playwright | `b4d016aadc5cbd2b898a284307975fe73e05483d` |

## Application to the report

- Apple Voice Control/Talon: dependable direct input primitives; no
  per-command cloud planner for already known native operations.
- Wispr/Aqua/Superwhisper: optimize the full speech-to-insertion path,
  including release tail, exact names and hardware. Vendor results are
  not local evidence and these products are not presumed reusable code.
- Alter: scope AX observations and use guarded action sequences; retain
  re-observation after changes without requiring app-specific guidance.
- Raycast: direct typed tools and focused-text operations. Use supported
  APIs and licensed implementations, not proprietary application code.
- Browser Use: persistent sessions, node IDs, state returned after
  actions, fewer round trips. Retain Jev's own authority and verification.
- agent-desktop: freshness-qualified references and explicit observation
  completeness. A smaller displayed tree need not mean less AX traversal.
- Claude Cowork: choose supported direct interfaces before screen control.
  This is an architectural lesson, not authorization for a new provider.
- Atlas: integrated startup/capture/input plumbing matters alongside the
  model; it is not a drop-in desktop driver.

The report's primary-source list remains at
`results/P4/jev-program-review-20261115.md`. Chrome attachment behavior is
documented at
https://developer.chrome.com/docs/devtools/agents/get-started/configuration.
Browser Use's current repository/documentation must be checked together:
cloud API limits and paid cloud features are not evidence that the local
MIT implementation requires that service.

## Required G2 reuse record

Competitive-evaluation additions, checked 2026-11-15:

- [jiwer](https://github.com/jitsi/jiwer), Apache-2.0, research HEAD
  `2227002889f20f3fb19d523eeb322732cb67b431`: reuse validated existing
  scorers first; otherwise prefer this to new WER/CER/edit-distance code.
- [AMEND](https://github.com/VoiceArenaAI/AMEND), Apache-2.0, research HEAD
  `69c8b9d5ba75c48bca58f1c3d50fb4683123378a`: reuse its scoring ideas or
  compatible components. Its default OpenRouter/Anthropic judge is not
  authorized; use human/literal adjudication or a declared approved
  evaluator. An adaptation is not the official Voice Arena benchmark.
- [cua-speedrun](https://github.com/cua-speedrun/cua-speedrun), research
  HEAD `be17c72c5efbb145d06f86028336fdf2743a3d98`: method reference for
  matching machines/clocks/cost and diagnosing premature observations.
  Metadata did not identify a license; review actual license scope before
  copying code. Do not replace the existing macOS harness with its VM stack.
- FluidAudio's current docs say vocabulary boosting is batch-only, not
  EOU streaming. Inspect the actual pinned SDK before proposing fast
  personalized finalization. Do not introduce another speech engine or
  a general LLM cleanup pass without a demonstrated quality/latency gap.

The preferred model policy is now Jev primary, Terra API when needed.
Existing Swift Responses clients remain the P5 reuse candidates; a new
ChatGPT OAuth/client implementation is unnecessary for that approved route.
See COMPETITIVE.md and the follow-up audit for sources and measurement limits.

For each new subsystem/dependency record: the exact required behavior;
existing code/platform candidate; FOSS project and tag; license/notice and
weight/binary scope; accept/reject reason; missing API/contract if any;
minimal adapter/patch; packaging/resource effects; verification and rollback.
No custom replacement is approved just because this record has a heading.

A package that cannot preserve target identity, consent, cancellation or
independent completion is not suitable unchanged. Adapt the seam or
document the smallest necessary gap; do not silently bypass those checks
to claim reuse. General screenshot capability remains when AX/DOM is
insufficient.
