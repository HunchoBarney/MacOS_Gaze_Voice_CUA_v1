# Jev reliability and speed: recommendation after D16

Research date: 2026-11-12. Research only: no product changes, model inference,
desktop interaction, benchmark, installation or acceptance change.

**Recommendation: retain Jev for fast semantic decisions, implement the missing
recovery path, improve the evidence used to locate targets, and reduce repeated
observation/decision work. Do not make another isolated wording change or select
a replacement model from a leaderboard.**

Thirty primary documentation/paper pages were fetched successfully. Exact URLs,
retrieval timestamps, response hashes and full retrieved text are preserved in
`decision-research-20261112/sources.json` and the adjacent source files. Additional
official product/model sources are linked below. Vendor and paper results are
their measurements, not measurements of Jev Voice.

## What the actual code and failures establish

1. **The current Jev lane has no integrated reasoning recovery.**
   `JevVisualDecision.swift:319-320` maps its refusal helper to `.safety`;
   `:571-578` uses that helper when the target fails its combined checks.
   `TaskLoop.swift:658-665` terminates on blocked/escalated decisions.
   `DriveLoop.swift:2037-2047` turns low confidence into handedBack, and
   `VoiceTaskCoordinator.swift:1694-1705` settles it as blocked, suggesting
   numbered targets. Its run path at `:1447-1477` retries session death only.
   No `SolDecider` implementation exists in the current Sources tree.
   The separate Codex agent facility is not an automatic recovery path here.
   PROGRAM already calls for Sol planning/recovery; that intention is not a
   functioning capability in this loop.

2. **D16 repaired composition, not demonstrated visual reliability.**
   Its single signed pilot failed: presence .97, location .89, authorization
   .92; the latter two miss .95. Both fixture counters stayed zero.
   This identifies the failed gates, not whether Jev's proposed point was
   objectively wrong or why its scores were low. Full model requests/answers
   and actual request count were not recorded in that pilot.

3. **There is repeated native observation work.**
   `DriveLoop.swift:1622-1675` awaits the driver window state and then a separate
   native read, including in the image path. Earlier evidence includes a
   1427.250375 ms SDK read and partial reads at 5000 ms. D16's cold runtime
   validation alone took 14251.223833 ms outside its goal clock.
   These are different measurements; do not add them as one latency breakdown.

4. **Jev already does many things the literature recommends.**
   Candidate support and independent questions are batched. Shared HTTP,
   driver warming, capability caching, shorter cursor travel and removal of
   the generic extra settle wait already exist. Repeating those recommendations
   as missing features would be misleading.

## Competitors and adjacent products

| System | Current evidence | Useful lesson and limitation |
| --- | --- | --- |
| OpenAI computer use / Codex / Sky | Live API docs use `gpt-6.1-sol`, separate browser and computer drivers, ordered action batches, and application-owned permissions. Driver actions run once; the SDK does not retry them. OpenAI documents background Mac computer use in Codex. | The existing approved Sol model can supply recovery. Reuse our executor and authority; model output must not become permission. Background multi-app capability does not justify parallel input into the same window. |
| Anthropic computer/browser use | Current docs describe `computer_toolset_20260801`, 17 tools, zoom, multiple actions per response, and stopping a batch at the first failure. Current model support includes Sonnet/Opus 5.5 and Fable 5.2. | Batch predictable actions, use browser structure where available, preserve separate checks of results. Stronger models still require verification. New vendor would change our current policy. |
| Google computer use | Live main docs now list Gemini 4 Carbon/Argon/Hydrogen and earlier models, browser/mobile/desktop environments, and action intent. Older indexed pages still describe browser-only previews. | A useful external comparator for recovery. Do not recommend an old preview ID or presume support from the family name. Not a currently authorized product dependency. |
| Browser Use 1.0 | Current docs describe one Python cell per model request in a persistent REPL, using browser helpers/CDP. Several old 0.x settings, including `flash_mode` and `max_actions_per_step`, are ignored. | Fewer model turns and structured browser access matter. Adopt typed bounded batches, not arbitrary desktop code execution. Their finish-success flag is agent-reported, not independent proof. |
| Stagehand v4 | `observe()` can resolve an Action which `act(Action)` replays without inference. Self-healing can re-infer when its selector breaks. Server cache requires Browserbase and has no effect on local browsers. | Reuse validated procedures, re-resolve targets, and invalidate on changed state. Copying a cache setting will not accelerate our real logged-in local Chrome. |
| Simular Sai / Agent S | S2 separates planning and grounding; current S4 evolves tool interfaces. September neuro-symbolic work learns reusable policies with step/task judges. S3's highest scores include best-of-N. | Learn reusable typed procedures from verified experience. Do not compare multi-rollout or partial-credit scores with one-shot completion, or bring generated desktop code into this scope. |
| Vercel agent-desktop | Native AX references, map/drill/act/re-read, scoped observations, headless AX actions; no model inside. | Borrow observation scope and native identity patterns. It is not a replacement for our decision loop, and complete-window uniqueness can still require broader reads. |
| Wispr Flow / Superwhisper / Apple Voice Control | Flow/Superwhisper focus on dictation, contextual text editing and direct insertion. Apple's labels/numbers/grid make target selection explicit. | Keep dictation and already-resolved targets out of general GUI planning. These products do not establish arbitrary multi-app task reliability. Our resolved gaze identity can help targeting, with separate explicit actuation. |

Relevant product sources:

- https://developers.openai.com/api/docs/guides/tools-computer-use
- https://developers.openai.com/api/docs/guides/tools-computer-use-sdk-drivers
- https://openai.com/index/codex-for-almost-everything/
- https://openai.com/index/openai-acquires-software-applications-incorporated/
- https://platform.claude.com/docs/en/agents-and-tools/tool-use/computer-use-tool
- https://ai.google.dev/gemini-api/docs/computer-use.md.txt
- https://docs.browser-use.com/open-source/agent.md
- https://docs.stagehand.dev/v4/basics/act
- https://github.com/simular-ai/Agent-S
- https://github.com/vercel-labs/agent-desktop
- https://docs.wisprflow.ai/articles/4816967992-how-to-use-command-mode
- https://superwhisper.com/docs/modes/built-in
- https://support.apple.com/guide/mac-help/use-voice-control-commands-mh40719/mac

## Research that materially changes the recommendation

**Faster individual operations can make the task slower.**
[cua-speedrun](https://arxiv.org/html/2609.40284) reduces action-to-observation
latency to 2–28 ms. In its GPT-6 Astra comparison, environment processing falls
from 12.68 to .34 seconds per task, but total time rises from 89.5 to 99.0 seconds:
screenshots arrive before the UI changes, causing extra decisions.
Conversely, restricting a batching-capable configuration to one action per
response raises mean task time from 127 to 183 seconds at the same reported
91.6% score. These are specific OSWorld experiments, not universal effects.
The live leaderboard's high scores also still involve roughly minute-scale
tasks, not instant general desktop assistance.

For Jev: use event-triggered, fresh, scoped readback with a bounded readiness
condition. Notification silence is not proof of unchanged state. Do not remove
all waits, blindly increase polling, or hide another model call behind `wait`.
Less reasoning is not automatically faster: the same study shows configurations
where more reasoning reduces mistakes and total calls.

**The number of decisions and the quality of grounding matter more than a
token-speed headline.**
[OSWorld-Human](https://arxiv.org/abs/2506.16042), published at MLSys 2026,
finds planning consumes more than half, sometimes around 75%, of task latency
in the studied agents, with judging/reflection another large cost. Its final
paper reports 2.7–4.3 times the human-derived step count for top agents.
Older project summaries give different ratios; do not mix versions.
This motivates compact state, fewer necessary decisions, and selective recovery,
but does not establish that model inference dominates our own native read path.

**Specialist grounding is a real alternative to more general-purpose prompts.**
[Agent S2](https://arxiv.org/abs/2504.00906) separates generalist planning from
specialist localization. [GUI-Actor](https://github.com/microsoft/GUI-Actor)
uses an attention-based action head and candidate-region verification rather
than relying entirely on generated coordinate text.
[UI-Venus-2](https://arxiv.org/html/2609.00028) reports ScreenSpot-Pro 73.0% for
9B and 74.1% for 27B; its 9B weights are
[released](https://huggingface.co/inclusionAI/UI-Venus-2-9B).
Those are localization scores, not complete-task success or safe-click rates.
UI-TARS-2 also has a technical report, but its headline results must not be
attributed to the separately released UI-TARS-1.5-7B weights.

For Jev: prefer image-backed AX/DOM candidate identity when available, then
deterministic geometry and fresh native identity/hit checks where supported.
For custom-drawn UI, retain a genuine visual grounder. A containing AX canvas
is not proof of a particular control inside it. Prior crop/marked-point
experiments already failed; do not restart them without a different hypothesis.

**Uncertainty should trigger an appropriate recovery, not a universal stop.**
[LEASH](https://arxiv.org/html/2610.22280) reports 73.66% success versus 72.90%
for its always-strong comparator with lower inference cost, by selective
escalation and oversight. It needs open-model hidden states and stored
trajectories; its exact uncertainty estimator is not available through Jev's
API. Borrow the routing architecture, not its numbers or nonexistent internals.

[SafeGround](https://arxiv.org/html/2602.02419) calibrates accepted-error risk on
held-out data and can abstain/cascade. Its multiple stochastic grounding samples
add work and conflict with our desired hot-path simplicity.
[CORA](https://arxiv.org/html/2604.09155v1) separates a guardian from a
diagnostician and locks the user's intent. Both are research evidence for
calibration and structured recovery, not proof of safe arbitrary Mac operation.
Statistical guarantees depend on the calibration assumptions and distribution.

For Jev: measure wrong accepted actions and false refusals separately. A `.95`
model score is not an end-to-end safety guarantee. Several checks can be
correlated; do not multiply their scores as independent probabilities.
Keep existing gates until domain evidence supports any contract amendment.
Never lower .95 to .89 merely because the triangle pilot failed.

**Repeated workflows can get faster without handwritten app recipes.**
[Neuro-Symbolic Computer Use](https://arxiv.org/html/2609.36927) reports
3.4–5.1 times lower per-run latency and improved Pass^3 for learned recurring
policies. These savings exclude the idea that first-time exploration is free.
Its judges miss some hidden failures; the paper reports zero agreement on six
invisible divergence cases in a small human analysis.

For Jev: a later generic skill layer could retain typed ordering, parameters,
preconditions and outcome checks from successful runs, then re-ground against
fresh state. Never cache AX tokens, coordinates, consent or completion as
durable authority. This adds an optimization for learned procedures, not a
requirement to pre-enable each app. Open-ended execution remains available.
S4's evolving interfaces are a longer-term research direction, not this patch.

**There are promising small models, but no demonstrated M1 shortcut.**
[GUI-JEPA](https://github.com/bcwang-sjtu/GUI-JEPA) scores candidate actions
without decoding. Its 0.50B system reports 51.5 ms median on an NVIDIA H20 and
86–92% of a fine-tuned 7B comparator's in-distribution accuracy. It depends on
mobile candidates/data; it is not a ready Mac replacement and trades accuracy.
[LGWM](https://arxiv.org/abs/2610.11942) investigates fast action-conditioned
transition verification in latent space. Its diagnostic detection scores
do not prove saved files, correct recipients or other hidden business outcomes.
Consider these for later local perception/monitoring research, not release proof.

Mac-specific evaluation is essential:
[MacArena](https://arxiv.org/html/2606.06560) covers 421 verified tasks across
50 apps on Apple Silicon and finds model rankings can invert on native Mac
tasks. Its baselines include older models, so use its task design, not its
table as today's model ranking. OSWorld, ScreenSpot and AndroidWorld numbers
are not interchangeable.

## Recommended architecture and order

1. **Finish recovery while retaining the fast path.**
   Separate `policy_denied`, `target_unresolved`, `stale_observation`,
   `delivery_unknown`, and `outcome_unproven`. Hard policy/consent denials stay
   terminal. Unresolved evidence may acquire a fresh scoped observation or
   request a concrete proposal from approved Sol, within the task budget.
   Return through the same executor and fresh outcome verification.
   Do not let a second model override a denial or repeat a possibly delivered
   action. Do not run Sol on every easy step.

2. **Make target evidence concrete.**
   Use semantic selection among actual native/DOM identities, with screenshots
   when visual distinctions are needed. Let code prove coordinates, scope,
   freshness and exact literal ownership wherever it actually can.
   Model judgments remain necessary for unresolved meaning and consequences.
   A strong model's answer should not be reinterpreted as a new goal, nor
   rubber-stamped by a second copy of the same ambiguous question.
   Any new evidence path needs explicit review of the existing proof contract.

3. **Shorten the execution path after the failure boundary is understood.**
   Reuse stable observed structure with invalidation; freshly read mutable
   targets, subject context and results. Avoid two complete AX walks when a
   scoped independent read can prove the same claim. Bound in-flight native
   work; cancellation of an awaiting Swift task does not stop synchronous AX.
   Execute short typed action sequences only while all known preconditions
   hold, stop at navigation/identity/uncertainty boundaries, and verify effects.
   Preserve visible feedback without assuming cursor presentation is the only
   dispatch cost. Cold loader startup remains a separate issue.

4. **Learn verified routines later.**
   Retain generic parameterized action procedures, re-resolve their targets,
   and fall back to general planning when the state changes. No Spotify recipe
   or app enablement flag. This follows the existing tiered roadmap and is
   separate from the immediate recovery implementation.

Model recommendation now: keep `jev-1.14.0`; live TypeSafe docs say it is still
the newest release and preview currently points to the same model. There is
no newer Jev to solve this by changing an alias. Use already-approved
`gpt-6.1-sol` for the recovery comparison. Preserve low→medium→high policy;
measure complete-task efficiency rather than assuming minimum effort wins.
Anthropic/Google are external comparators, not silent dependency changes.
Open weights are optional future experiments: a 9B model needs roughly 4.5 GB
for four-bit weights alone, before runtime/vision/KV memory, incompatible with
calling it a free addition to our 2.5 GB product budget on an 8 GB M1.

## One useful next experiment

Before another signed-app round, use a fixed, labelled set of approximately
24 distinct captured states from owned/sanitized fixtures and already authorized
evidence. Include text, icon-only/custom controls, duplicate labels, absent
targets, overlays, changed windows/documents, exact text insertion/replacement,
and protected consequences. Split development cases from held-out cases.

Compare the current Jev grounding path, native/image-backed candidate selection,
and Sol recovery on the same evidence, operations and literals. Start with the
existing two approved vendors; an open-weight arm is a separate policy/deployment
choice. This is a read-only model experiment, not permission to click.

Record candidate coverage, actual correct target/point, false acceptance,
false refusal, the reason for each refusal, model requests, bytes/tokens and
latency. Preserve every result; no retries until green. Separate a wrong
coordinate from a correct coordinate rejected by a verifier, incomplete native
evidence, and service errors. Exclude no hard negatives to improve a percentage.
The D16 pilot's two trace messages alone are insufficient for that diagnosis.

Promote only a change that improves correct-target acceptance without introducing
wrong/forbidden accepted actions on the negative cases and whose measured
request/read cost fits the intended lane. Then perform one controlled signed
comparison through the real production path, with independent outcome proof.
This small diagnostic set is not a >=95% release reliability estimate.

Keep PROGRAM's latency distinctions: acknowledgement <=300 ms, one-shots
<0.5 s, Jev slice <=4 s, browser and complex tasks on their own budgets.
Sub-millisecond arithmetic and millisecond driver I/O do not imply a universal
2 ms voice-to-verified-outcome assistant.

The next implementation should address the missing recovery and evidence
contract. Another batch of wording tweaks, wider per-action model committees,
driver replacement without attribution, or repeated green-triangle pilots would
not resolve what the current evidence leaves unknown.
