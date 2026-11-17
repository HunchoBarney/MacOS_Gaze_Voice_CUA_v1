# Jev Voice model and execution architecture research

Research checked 2026-11-12 UTC. This is a research handoff, not an approved implementation plan or a change to acceptance, providers, model wiring, or contracts.

The user explicitly rejected a model-replacement bakeoff as the next task. They want a recommendation from published benchmarks, current documentation, other agents' designs, and the actual application code. They asked particularly about Mammoth versus Jev, fast text generation, and how to fix the current problems. Do not restart this discussion by proposing a lengthy comparison harness.

## Source of truth and current implementation

The IDE checkout is `/Users/karanvirkang/Documents/code/JarvisMacOSv1-empryo-staging-20260928`, on `ship/v1-p2d`. Current P4 work is in `/Users/karanvirkang/Documents/code/jarvis-v1-agent`, on `ship/v1-p3`. Both reported HEAD `4b263b3` during this research, but their working files differ substantially. Read the P4 working tree, not just the commit or the IDE checkout. Source paths below refer to `jarvis-v1-agent`.

Relevant current program decisions:

- `.agent/PROGRAM.md:31-35`: OpenAI and TypeSafe are the locked providers; Sol handles planning/recovery; Jev's window-image fallback is an approved experiment, not qualified production behavior. One TaskLoop owns execution.
- `.agent/PROGRAM.md:120-126`: P4 is TaskLoop/Jev, P5 is OpenAIResponsesClient/SolDecider, P6 is deterministic scripts and inbox work, P7 is browser DOM execution, P9 later compiles repeatable skills.
- P4's fast slice requires at least 95% strict success and p50 at most four seconds. P5 and P7 have distinct workload bars. Broad OSWorld results do not qualify P4.
- The current program has progress-driven Jev rounds with no default round ceiling. The older main-checkout wording says at most four rounds. Do not accidentally restore that older design.
- `.agent/CONTRACTS.md:241-281`: deciders propose actions; TaskLoop owns actuation, settling, budgets and consent.
- `.agent/CONTRACTS.md:610-644`: the observed-goal proof is specifically pinned to the Jev path. Model-written predicates and text are not accepted as proof, and future P5/P7/P9 consumers do not automatically inherit this proof mechanism.

There are generative components already:

- `Sources/JevVoice/Voice/RealtimeVoiceClient.swift:315` defaults to `gpt-realtime-2.1`.
- Persistent agents use the Codex runtime; `Sources/JevVoice/main.swift:340-355` inherits the user's Codex model configuration or the OpenAI provider default. This is not evidence that an in-loop Sol recovery implementation exists.

The missing integration is specific:

- `Sources/JevVoice/Voice/RealtimeVoiceLane.swift:654-661`: the current `computer_task` route calls the command handler with the original admitted goal, `nil` literal text and an empty steps array.
- `Sources/JevVoice/Drive/VoiceTaskCoordinator.swift:800-855`: the older coordinator can accept steps, but converts them into a `Plan: ...` context string. That does not establish a maintained, executable plan, and the current route above supplies no steps.
- `Sources/JevVoice/Drive/DriveLoop.swift:2033-2052`: escalations map to handed-back, blocked or exhausted results.
- `Sources/JevVoice/Drive/VoiceTaskCoordinator.swift:1694-1708`: low-confidence handback becomes a user-facing block/number-overlay suggestion; it does not automatically resume with a stronger model.
- `Sources/JevVoice/Drive/JevDecider.swift:326-347`: entry requires a supplied literal or asks the user what to type. A decision model cannot draft a reply or summarize a document into a new value.
- Searching `Sources` found no implemented `SolDecider` or `OpenAIResponsesClient`.

Thus the application has voice understanding and delegated generative agents, but the planned generative computer-task execution/recovery path is unfinished. Adding a different decision model does not fill that gap.

## Mammoth versus Jev

Published numbers retrieved during this session:

| Property | Mammoth-1 / Mammoth 27B | Jev 1.14 |
| --- | --- | --- |
| Current Artificial Analysis Decision Index | 71 | 66 |
| AA time per task | 106 ms | 92 ms |
| Jev Decision Index 0.4 full score, as recorded in Mammoth's release card | 71.24 | 62.2 |
| Input price per million tokens | $0.10 | $0.042 |
| Context | 16,384 tokens | Default 64k per request, 32k per question |
| Typed outputs | Choice, Noul, Score | Choice, Noul, Score, experimental Box |
| Text generation | No | No |
| Image input | Supported | Supported experimentally |
| Weights | MIT, 27B | Hosted |

AA's Decision Index combines correctness, calibration and symmetry. Its time metric is the index-weighted average of benchmark median task times. The values are not UI success percentages, not Mac measurements, and not a promise that every request differs by exactly 14 ms. Jev Decision Index is a separate benchmark; do not combine its scores with AA's. Mammoth's release article also cites an older self-run AA result of 65.9; that is not the current AA score of 71.

Judgment: Mammoth is the stronger published-evidence choice for semantic decisions over observed controls and text. The approximate 14 ms benchmark difference is a small trade for its higher decision score. Jev retains advantages in context size, price, existing integration and modestly lower published latency. Neither score proves a fix for the exact Calculator refusal.

For Jev Voice, Mammoth would fit selecting an observed control, distinguishing valid operations, routing uncertainty and judging textual evidence. It would not write a reply, create a plan, or directly replace the image-to-coordinate path.

Important integration details:

- Baseten exposes the System One pattern and evaluates related questions against a shared input prefix. It explicitly tells callers to use `probabilities[choice]`, not the normalized `confidence` field, as the selected-option probability.
- Its published question types do not include Jev's Box output. `JevVisualDecision.swift:239` and `NativeUIOutcomeEvidence.swift:162` explicitly check the Jev model identity. A new base URL is not a complete integration.
- Any provider adapter must preserve genuine provider/model provenance. Never relabel Mammoth as Jev to satisfy existing guards.
- Its 16k limit must accommodate the state and decision questions. Do not silently omit target candidates or proof context to make a request fit.
- Treat Mammoth as hosted on the 8 GB M1 hardware floor.
- Baseten's technical report says the release was trained on text alone with a frozen vision encoder, while the current Hugging Face card says text and image decisions with the vision encoder frozen. This documentation disagreement prevents a definitive training-modality claim. Neither source supplies a demonstrated Mac GUI grounding replacement for our Box path.
- TypeSafe explicitly labels Images/Box as not ready for production and supplies no recommended Box confidence threshold.

Sources:

- https://artificialanalysis.ai/decision-models/mammoth-27b
- https://artificialanalysis.ai/decision-models/jev-1-14
- https://huggingface.co/baselabs/mammoth-1
- https://labs.baseten.co/articles/mammoth-1-and-elephant-1-frontier-decision-models
- https://docs.baseten.co/inference/model-apis/decision-models
- https://docs.typesafe.ai/models
- https://docs.typesafe.ai/primitives/box

## Fast text generation

The generative role creates draft text, summaries, arguments, plans and recovery actions. It can be supplied by the same model that reasons over screenshots. It need not be called for a deterministic command or every button press.

**Qwen3.8-27B on Cerebras is the strongest speed-oriented option found for routine generation.** Cerebras advertises about 1,850 tokens/s, exposes strict structured outputs and tool calling, and supports `reasoning_effort: none`. Thinking defaults to high, so merely choosing this endpoint does not select its shortest path. Qwen's model card reports 84.3% OSWorld-Verified and 64.8% WebArena-Verified. These are original-model benchmark results, not a Cerebras reproduction or evidence for reasoning-off performance.

Cerebras supports images for this model, but the image API is marked Public Preview. Its ordinary text generation is the most directly useful capability here. It would add a provider beyond the current locked plan.

**GPT-OSS-120B on Cerebras advertises about 3,000 tokens/s**, but always enables reasoning; `none` is unsupported. It is text-only. Its higher advertised throughput does not establish a shorter time to a usable answer for a small writing request.

**GPT-6 Luna with reasoning off is the inexpensive OpenAI option for simple writing and extraction.** AA showed approximately 1.65 s to first answer token and 91 tokens/s full-request throughput. Its current AA Intelligence Index score was 9, so it should not inherit difficult planning duties just because it is cheap.

**GPT-6.1 Terra is a stronger OpenAI option for combined writing and computer use.** AA's non-reasoning snapshot showed approximately 2.11 s to first answer token, 67 tokens/s full-request throughput and an Intelligence Index score of 31. OpenAI reports over three times faster task completion than Sol/Astra on its cited professional-work evaluation. That is a vendor result on that workload, not subsecond UI inference. Terra supports reasoning off; tool calling requires Responses. Replacing the currently specified Sol with Terra would be a prospective plan change.

**Sol already is a text-generation model.** Finishing its planned P5 integration can provide writing, planning and recovery without inventing a separate model category. A faster routine generator can later share that task interface while Sol handles difficult cases.

Cerebras' advertised generation rates and AA's full-request throughput are different metrics. The first useful answer must include prompt processing, any hidden reasoning, transport and necessary output. Do not turn 1,850 tokens/s into a claimed 50 ms complete response. Short complete tool arguments must be received and validated before execution; streaming partial JSON is not execution authority.

Sources:

- https://inference-docs.cerebras.ai/models/overview
- https://inference-docs.cerebras.ai/models/qwen-3.8-27b
- https://inference-docs.cerebras.ai/capabilities/reasoning
- https://inference-docs.cerebras.ai/capabilities/image-inputs
- https://inference-docs.cerebras.ai/resources/designing-for-cerebras
- https://huggingface.co/Qwen/Qwen3.8-27B
- https://artificialanalysis.ai/models/gpt-6-luna-non-reasoning
- https://artificialanalysis.ai/models/gpt-6-1-terra-non-reasoning
- https://developers.openai.com/api/docs/models/gpt-6-luna
- https://developers.openai.com/api/docs/models/gpt-6.1-terra
- https://openai.com/index/introducing-gpt-6-1-terra/

## What other agents teach us

**Browser Use:** DOM-first operation, screenshots on demand, stable prompt prefixes and concise actions. Its older engineering report says its actions commonly fit in 10–15 output tokens and its image processing added about 0.8 s in its own experiments. Its newer Ultrafast announcement reports a 22 s median on completed production runs. Those runs are not a randomized comparison and are not our four-second workload. The applicable lesson supports our existing P7 and persistent real-browser plan; it does not justify moving users into an unrelated hosted browser.

**Simular Agent S:** S2 separated planning from grounding. S3 subsequently removed the manager–worker hierarchy to reduce overhead and, together with a native coding agent, reported 62.6% single-run OSWorld success. Its higher 69.9% result used ten rollouts. We should reuse the lesson of a simpler controller and appropriate action interfaces; neither best-of-N rollouts nor arbitrary desktop code execution is in our current scope.

**Asteroid:** reports that ordered action batches reduced model calls by 32–52% across four production-style healthcare workflows, with wall-time reductions ranging from 7% to 59%. This is a vendor case study, not an app speed prediction. Current OpenAI and Anthropic computer-use APIs support ordered batches. Keep batches conditional on valid target/focus state and stop on failure or cancellation.

**VLAA-GUI:** directly addresses early stopping and repetitive loops using observable completion conditions and escalating recovery strategies. Its paper reports 77.5% OSWorld and 61.0% WindowsAgentArena. These are framework/backbone results, not standalone model speed. Its useful lesson matches the gap in our current handback behavior.

Sources:

- https://browser-use.com/posts/speed-matters
- https://browser-use.com/posts/bu-ultrafast-is-live
- https://www.simular.ai/articles/agent-s2-technical-review
- https://www.simular.ai/articles/agent-s3
- https://asteroid.ai/blog/computer-use-in-healthcare/
- https://arxiv.org/html/2604.21375
- https://developers.openai.com/api/docs/guides/tools-computer-use
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool

## Concrete implications for the current failures

1. **Native observation remains an independent blocker.** The latest diagnostic rerun failed in the SDK before any model request: 5 s timeout, four nodes, no display. `NativeWindowObservation.swift` queries window identity before setting the timeout on those returned references; its original collection deadline starts after initial identity/document reads. That is a real scope limitation of the deadline, but it does not prove the cause of the separate SDK stall. The current owner has D15 trace-and-preview approval and has begun diagnostic source changes. Do not duplicate that work or assert the stall cause is established.

2. **Make recoverable uncertainty reach the planned generative controller.** Low selection confidence or lack of grounding can justify a fresh observation and stronger reasoning within the same task/window authority. Cancellation, permission denial and an exhausted deadline remain terminal. “Escalation” must not become a way around a safety refusal.

3. **Add an explicit generated-content path in P5.** “Draft a polite reply” requires a new text artifact based on read evidence. Keep generated content distinguishable from literal dictation and from user authorization. Do not mark model-authored content as user-supplied merely to satisfy the current literal fast path.

4. **Track the current subgoal and actual outstanding conditions.** A prose plan in context leaves the chooser to rediscover unfinished work every round. One controller can maintain a compact task state and request new planning only when the state changes materially. The active P3 route currently supplies no plan at all.

5. **Specify verifiable outcomes without manufacturing proof.** For a calculation, parsed operands can be evaluated by code, then compared with a fresh result from the bound application. For a message, a saved/sent record and correct recipient/thread matter. A generator's proposed expected value is never itself evidence that the task happened. These mechanisms need a reviewed P5/P7 contract; P4's current Jev-only proof must not be silently broadened.

6. **Reduce unnecessary decision and observation cycles.** Ordered local action batches, reusable connections, one capture reused when needed, stable prompt prefixes and DOM extraction are supported by current external designs and largely anticipated in P5/P7. D14 already introduced schema caching and dispatch pacing changes, so do not describe those as new discoveries. Keep identity and state checks at meaningful boundaries.

7. **Use P6 and later P9 for repeatable work.** Calendar/reminder/script operations and compiled repeatable skills need not repeatedly rediscover a GUI workflow. This is already part of the program.

P4 remains 4/6. D14's two successful candidate runs were about 4.023 and 4.027 seconds, and the third was an early refusal. Three rows per arm do not prove a reliability regression. `visual_trace_collection_ms` measures post-run log collection after `wall_ms` stops; it is not two seconds of in-task screenshot overhead. No replacement model was called, no live benchmark was run, and no production files or acceptance flags were changed by this research.

## Recommendation

Favor Mammoth over Jev for the semantic decision role on the published evidence, while recognizing the smaller context and lack of Box output. Favor Qwen3.8-27B on Cerebras when fast routine text generation is the priority. Retain the planned strong generative controller role for difficult planning, visual work and recovery; Sol can already supply that role and text generation, with Terra a newer prospective alternative.

The application should retain one TaskLoop and its current authority boundaries. Model selection is separate from completing the missing P5/P7 execution paths. Custom Gemma training is not necessary to supply those missing product capabilities. Any change to the locked providers, proof provenance, generated-value handling or phase order remains a proposed program change rather than an action authorized by this research memo.

## Follow-up: recent visual specialists alongside Jev

The user subsequently asked specifically for newer models that identify buttons and understand screens, with strong speed and accuracy, potentially alongside Jev. This does not require first replacing Jev with Mammoth. The relevant addition is visual grounding inside the existing execution loop.

Distinguish three capabilities:

- A screen parser inventories controls, text and regions in a screenshot.
- A target grounder receives a screenshot and a target description and returns a point or region.
- A GUI agent interprets the current state, proposes actions and reasons over a workflow.

A fast target grounder does not necessarily provide a complete screen inventory or understand whether a whole task succeeded. Native AX and browser DOM already supply structured observations on many of our surfaces.

### Shortlist checked against primary sources

| Candidate | Recency | Relevant reported result | Latency evidence | Practical judgment |
| --- | --- | --- | --- | --- |
| GUI-Decisions-31B, published LoRA path | October 2026 | 86.6% ScreenSpot click accuracy on 1,272 cases; 65.9% held-out AGUVIS step accuracy | About 146 ms per step, Gemma 4 31B NVFP4 with vLLM on one RTX PRO 6000; median over 80 cold screenshots | Most interesting recent speed research candidate; favor over the 2B variant when GPU hosting is acceptable |
| GUI-Decisions-2B, published LoRA path | October 2026 | 77.0% ScreenSpot clicks; 62.6% AGUVIS steps | About 87 ms through the client, versus 83 ms for the merged release, on RTX PRO 6000 | Faster but materially weaker on the reported click evaluation; do not select it as the default solely for its speed |
| UI-Venus-2-9B | August/September 2026 | 73.0% ScreenSpot-Pro, 77.1% VenusBench-GD, 78.5% OSWorld-G-R | Grounding explicitly uses reasoning off and temperature zero; no comparable measured subsecond latency found | Strong recent GUI-grounding reference, but weight-license status currently prevents treating it as a cleared product dependency |
| Holo4-35B-A3B / Holo4-27B | September 28, 2026 | Vendor OSWorld results of 80.8% / 85.2%, respectively | Documented screenshot-plus-target localization API with thinking off; no verified millisecond grounding latency found | Practical hosted option for broader screen understanding and localization; do not attach Holo3.1 timing claims to Holo4 |

ScreenSpot, ScreenSpot-Pro and OSWorld are different evaluations. Do not compare their percentages as one ranking or substitute them for our strict task-success requirement. All GUI-Decisions speed measurements are author-reported GPU experiments, not measurements over a public production API or on an M1.

GUI-Decisions is particularly relevant because it reads categorical action and coordinate distributions instead of generating a long reasoning trace and textual coordinates. Its 31B version uses Gemma 4 as the foundation. The technique demonstrates that a visual specialist can operate at decision-model-like inference times on suitable hardware.

Preserve variant attribution: the merged 31B checkpoint reports 86.9% ScreenSpot accuracy with bf16/in-process evaluation, whereas the published NVFP4 LoRA evaluation reports 86.6%. Its plain-transformers full-slot forward pass is reported at 150–210 ms. Do not combine the merged bf16 accuracy with the NVFP4 speed as if they were one measured configuration. The merged 2B checkpoint reports 76.3%, while the original LoRA reports 77.0%. The comparison against vanilla GUI-Owl uses its agent prompt, not its dedicated grounding prompt, so it does not prove superiority over the best configured GUI-Owl grounder.

GUI-Decisions remains a research release with important limits: it does not execute or maintain workflow memory; text values need a separate generator; tiny targets can be missed. The 31B model's UI box mean IoU is only 0.467 on ScreenSpot even though point-click accuracy is higher. The 2B variant does not supply boxes. Neither is established as a direct replacement for all of our Box-based proofs.

UI-Venus-2's current model card explicitly says that its weight license is pending confirmation due to conflicting upstream declarations. Record this rather than repeating earlier Apache-2.0 claims. A community 4-bit MLX conversion exists at about 5.6 GB of weights, already above the app's overall resource target before image processing and runtime memory. It is not an attractive local default on the 8 GB M1 floor.

Holo4 exposes element localization through an ordinary model request: screenshot, target description, thinking disabled, and structured x/y output. This can be used without adopting its separate agent harness. The current 35B-A3B weights are Apache-2.0; the 27B weights are CC BY-NC 4.0. Some older H documentation still groups both as noncommercial; the current model cards distinguish them. Three billion active parameters do not make the 35B model a three-billion-parameter memory footprint.

Other models considered:

- GUI-Owl-1.5 is a 2026 GUI-trained family with small instruct variants and broader GUI understanding. The family headline of 80.3 on ScreenSpot-Pro must not be attributed to its 2B checkpoint.
- GoClick, published April 2026, offers 230M and 0.8B grounders. Its 37.7/91.1 ms figures are time to first token, not complete-response latency; its reported ScreenSpot-v2 results are 75.2/81.1%. Useful size research, but not the default recommendation for the user's accuracy priority.
- OmniParser-v2 inventories controls, but its published full-pipeline latency is about 0.6 s on A100 and 0.8 s on RTX 4090. Its 39.6 ScreenSpot-Pro result is for a parser-plus-GPT-4o system. Its original release is older than this shortlist.
- Holo3.1's documented optimized 35B pipeline averages about 3.3 s per step on DGX Spark. Third-party 140 ms claims were not supported by its primary release. Do not repeat them.
- Indeed-UI and KV-Ground achieve strong ScreenSpot-Pro results, but their best headline results add zoom-in calls. No comparable latency result was found; KV-Ground also has noncommercial weight terms.
- GPC-1 supplies continuous coordinates and decisions but no verified GUI accuracy/latency evidence sufficient to rank it above this shortlist was found.

### Fit with our code

`JevDecider` already has an optional `VisualChoose` seam and a screenshot-request path. `JevVisualDecision.swift` currently asks Jev for `target_present` and `target_box`, checks the Jev model identity, and binds results to the task and screenshot. A visual helper should be introduced at that responsibility boundary, not as an always-running perception service.

Recommended division:

1. Use AX/DOM when it provides usable controls and state.
2. Use Jev for bounded semantic choices over available evidence.
3. When the intended control is known but its location cannot be grounded, call a GUI grounder with that target description and the current bound window image.
4. When the workflow or screen meaning itself is unclear, use the planned generative/GUI reasoning role; a coordinate-only model does not supply that capability.
5. TaskLoop validates provenance, coordinate mapping, freshness and authority, executes through Cua, and obtains fresh outcome evidence.

The helper's text labels are predictions, not independent confirmation. Jev evaluating a supplied label does not independently establish that the label is at the proposed pixel. Do not average Jev confidence with a grounder's coordinate distribution or accept two-model agreement as completion proof. Absent targets and conflicting evidence must remain representable; a model that always emits a point cannot be treated as a calibrated presence detector.

Preserve Retina scale and crop-to-window transforms. Do not fabricate a bounding box from a point simply to satisfy the current Box schema. Cache only within the same valid captured observation; a new UI state requires fresh grounding. Keep screenshots out of Realtime and keep gaze as an identity hint, as required by the current program.

Research preference: retain Jev and prioritize a dedicated visual helper over another general decision-model swap when addressing visual target failures. GUI-Decisions-31B is the leading speed research candidate from this search; Holo4 is the more straightforward current hosted interface for combined localization and broader UI interpretation. UI-Venus-2 is a useful quality reference pending license clarification. None of the reviewed sources establishes both Jev-like end-to-end latency and the app's reliability requirement on the target Mac.

No model inference, replacement bakeoff, model download, production edit, provider change or acceptance update was performed. The only downloaded asset was H Company's public benchmark-table image, inspected as research evidence.

Sources:

- https://huggingface.co/blog/infinitylogesh/gui-decisions-stop-decoding-coordinates
- https://huggingface.co/infinitylogesh/GUI-Decisions-31B
- https://huggingface.co/infinitylogesh/GUI-Decisions-2B
- https://huggingface.co/inclusionAI/UI-Venus-2-9B
- https://arxiv.org/html/2609.00028
- https://huggingface.co/lethargicgeek/UI-Venus-2-9B-mlx-4bit
- https://huggingface.co/blog/Hcompany/holo4
- https://huggingface.co/Hcompany/Holo4-35B-A3B
- https://huggingface.co/Hcompany/Holo4-27B
- https://hub.hcompany.ai/models-api/element-localization
- https://huggingface.co/mPLUG/GUI-Owl-1.5-2B-Instruct
- https://arxiv.org/abs/2604.23941
- https://huggingface.co/HongxinLi/GoClick-Base
- https://huggingface.co/microsoft/OmniParser-v2.0
- https://hcompany.ai/newsroom/holo3.1
- https://github.com/intelligence-indeed/Indeed-UI
- https://huggingface.co/vocaela/KV-Ground-8B-BaseGuiOwl1.5-0315
- https://huggingface.co/suryatmodulus/GPC-1
