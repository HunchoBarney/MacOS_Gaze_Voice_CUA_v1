# Jev-first routing and competitive plan audit

Research date: 2026-11-15. Scope: audit and update planning documents,
inspect relevant source without executing it, and read current primary
documentation. No app modification, runtime test, install or inference
request. This is a planning audit, not an independent phase verdict.

The user prefers Jev as the primary decision model, Cua as executor,
GPT-6.1 Terra when needed, and subsequently explicitly allowed the Terra
API. They want Wispr-level dictation accuracy and leadership across
computer-use categories. The latest direction supersedes the earlier
replacement-model search and default-Sol planning assumption.

## Findings and changes

| Finding | Evidence | Planning correction / owner |
|---|---|---|
| The plan was drifting toward replacing Jev | Previous SHIP-PLAN P5 model-selection tournament and PROGRAM's Sol default | Keep direct operations first, Jev as primary semantic chooser, Terra API for explicit recovery/planning/generation needs; P4/P5/P7 |
| An ASR engine score is not dictation quality | Wispr Canto research and Voice Arena's ready-to-send evaluation | Add raw WER, critical-content errors, final insertion, zero-necessary-edit rate and correction effort; P3/P10/P13 |
| Streaming partials do not establish a fast accurate final | LocalTranscriber uses EOU for provisional output and Ultra to transcribe the whole hold after release | Trace actual final compute/drain/decoder/delivery; do not claim EOU previews solve the final tail; P3 |
| Some proposed speed fixes already exist | finishHold starts the whole-hold final without awaiting the provisional tail; P4 D14/settle work already exists | Reuse those changes; only optimize demonstrated remaining cost |
| Streaming vocabulary support was too easy to assume | FluidAudio documents CTC vocabulary boosting as batch-only, not EOU streaming | Measure SDK support/accuracy/resources before a personalization or incremental-final change; no guessed API or universal finalization promise |
| ChatGPT account access and API support are different routes | OpenAI model/auth/tool documentation and existing Codex bridge | Terra API is the approved P5 route. Keep existing ChatGPT/Codex background integration; do not build new OAuth just for this milestone |
| The old minimum competitor gates cannot establish leadership | >=70% shared Codex task wins; browser allowed up to 1.2x Browser Use | Keep old gates and add a per-category correctness/p50/p95/edit-burden scorecard and explicit goal gaps; P13 |
| The timers were not all comparable | S-VISUAL started at admission; Wispr speech-end clock; external CU verifier may be off-clock | Start automation measurement before routing/planning, preserve whole voice time, report separate effect/verification/benchmark clocks |
| Read-only fan-out and speculative actions were ambiguously grouped | PROGRAM banned speculation while SHIP-PLAN allowed independent judgments over one state | Permit bounded independent reads/Jev questions; forbid speculative mutations, answer-shopping and routine speculative Terra calls |
| Some necessary harness files are in a sibling tree | `.agent/results/P3/` is absent in this worktree, present in `jarvis-v1-p3-semantic-closeout`; verification-lane references it | C1 must bind/restore reviewed harness assets before calling an existing command runnable. No broad copying or fabricated pass |

## What the current sources support

TypeSafe's current docs support small typed decisions over supplied state,
code-owned execution and parallel independent questions. Confidence is a
distribution statistic, not task correctness or a permission token.
Images/Box remain explicitly experimental and mutable. Jev being primary
does not remove their qualification gate or prove it can handle every
arbitrary interface by itself.

Terra is documented as `gpt-6.1-terra`, supports text/image input and
Responses tool calling, and does not support Realtime/audio/transcription.
It is suitable as the requested reasoning/recovery layer; it is not the
dictation engine or a replacement microphone transport.

The repository already has `CodexModelProvider.chatGPT()` and CodexAuth.
This shows reusable integration, not current account entitlement or
proven low-latency recovery. OpenAI's separate Sign in with ChatGPT
plan-usage preview does not support native computer_use/hosted MCP, though
local function/custom/MCP tools can be used under its documented rules.
Those preview limitations are not blanket claims about every Codex route.
The user's API clarification avoids making this auth integration a release
dependency. API model access/tool compatibility must still be verified on
the selected configuration; no silent billing-route switch on quota/error.

LocalTranscriber source evidence:

- `Sources/JevVoice/Intelligence/LocalTranscriber.swift:193–213`: Ultra
  final models and ms160 EOU streaming models.
- `:298–345`: finalization captures the whole hold, starts independently
  of pending provisional work and calls `asr.transcribe(wholeHold, ...)`.
- `:365–374`: provisional streaming remains display-oriented.

These are source facts, not measured contributions to the current delay.
FluidAudio's EOU chunk-size/quality tradeoff and batch-only vocabulary
boosting mean the 50ms exact final is a real engineering question.
Do not substitute an early lower-quality partial for the final to meet it.
If the incumbent cannot meet the combined goal, run a bounded existing-SDK
upgrade/alternative check with held-out accuracy; do not restart an
unbounded speech bakeoff or add a general LLM cleanup call to every utterance.

## Current public evidence and its limits

Wispr's Canto evaluation reports about ten hours of real English dictation
from more than 2,300 speakers, with speaker separation, plus a three-hour
challenge set. It is Wispr's own corpus/evaluation; it is not our local
product comparison or evidence for every accent/language.

The November Canto update reports 13% fewer dictations needing edits and
54% fewer desktop dictations exceeding one second after speech ends,
relative to its own earlier system. Its stated budget is under 700ms for
recognition, formatting, OS and network. Neither percentage is a measured
Jev comparison, absolute success rate or published 700ms median.
The article says one accurate model replaced several speech recognizers
after live A/B testing; copying that architecture without accuracy proof
would repeat our existing regression risk.

Voice Arena's November macOS/US-English benchmark reports Wispr at
79.4% zero-edit rate and 0.40% AMEND across its 761-clip/87-speaker study.
The zero-edit ranking uses five-provider LLM consensus, not direct
observation that 79.4% of all real users need no edits. The visible latency
column is still "coming soon"; this leaderboard does not establish the
fastest dictation app. Its app configurations, reference/normalization and
judge setup matter. COMPETITIVE separates our human/literal checks from an
adapted AMEND score and makes no claim of reproducing that leaderboard.

Cua-speedrun standardizes machines, task populations, clocks and cost,
but its VM/environment results are not M1 native-app results. Its FastCUA
example cuts environment I/O to milliseconds while a model can take
longer overall because it sees screens before they settle and retries.
Adopt its measurement lesson; do not promise 2ms full voice workflows from
a 2ms key-dispatch result. Retain independent settle/verification.

## Primary sources

1. https://docs.typesafe.ai/llms.txt
2. https://docs.typesafe.ai/images.md
3. https://docs.typesafe.ai/confidence.md
4. https://docs.typesafe.ai/patterns/fan-out.md
5. https://developers.openai.com/api/docs/models/gpt-6.1-terra.md
6. https://openai.com/index/introducing-gpt-6-1-terra/
7. https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations.md
8. https://developers.openai.com/siwc/token-sharing-open-source/codex-app-server.md
9. https://developers.openai.com/siwc/token-sharing-open-source
10. https://wisprflow.ai/canto
11. https://wisprflow.ai/canto-1-results
12. https://voicearena.com/dictation-bench
13. https://voicearena.com/__l5e/assets-v1/e3b73104-9f2c-436d-bd32-6bc81deff56e/VoiceArena_Dictation_Benchmark_Methodology.pdf
14. https://github.com/VoiceArenaAI/AMEND
15. https://docs.fluidinference.com/asr/streaming
16. https://docs.fluidinference.com/asr/custom-vocabulary
17. https://docs.fluidinference.com/asr/getting-started
18. https://cuaspeedrun.com/
19. https://arxiv.org/html/2609.40284
20. https://github.com/cua-speedrun/cua-speedrun
21. https://github.com/jitsi/jiwer

Voice Arena direct HTML retrieval returned 403; the live search tool
exposed the leaderboard and methodology, and the linked AMEND source was
available. No dataset was downloaded and no raw benchmark was reproduced.
Other statements above are bounded to retrieved documentation/source.

Repository metadata checked: AMEND Apache-2.0 at research HEAD
`69c8b9d5ba75c48bca58f1c3d50fb4683123378a`; jiwer Apache-2.0 at
`2227002889f20f3fb19d523eeb322732cb67b431`. Cua-speedrun metadata did not
identify a license at `be17c72c5efbb145d06f86028336fdf2743a3d98`;
use it as a methodological reference until license scope is established.
Dataset and dependency rights need separate review before adoption.

## Next concrete work

C1 remains first: resolve the exact candidate/harness manifest, preserve
authority/dwell requirements, run a bounded dictation/native baseline,
then fix the measured finalization/delivery cost and compare the same way.
Do not block that work on a broad model tournament or a new ChatGPT
authentication implementation. C2 adds Terra recovery with measured
benefit; C3 publishes the complete category/accuracy scorecard.

## Documentation validation and handoff

Updated PROGRAM/SHIP-PLAN/CONTRACTS/PLANS/REUSE/AGENTS/README, affected
phase plans and their draft criteria. Added COMPETITIVE and P13-8/P13-9;
P5 now plans RecoveryDecider with Terra API while retaining Jev primary.
The historical Sol pixel baseline remains explicitly a benchmark
reference, not the production fallback.

Validation passed: all 17 acceptance schemas; all nine draft plans'
required sections, owned paths and criterion mappings; 59 false/null
criteria; local links, fences and tracked documentation whitespace.
The eight pre-existing P0–P4 acceptance files remain byte-identical.
The 291-file unignored implementation fingerprint remains
`558e8489bfbd71b6a16aa210db99b55296b1694cd447c124b0a565aba26c7145`.
No source/build/test/install or model inference occurred. These are
documentation checks, not phase acceptance or comparative product proof.
