# Competitive quality and speed protocol

Updated 2026-11-15 following the user's direction: retain Jev, execute
through Cua/native tools, use GPT-6.1 Terra through the API when needed,
match or exceed Wispr Flow dictation quality, and pursue leadership in
every shipped interaction category.

PROGRAM owns the model policy, absolute budgets and release requirements.
This file owns the comparison method. SHIP-PLAN owns delivery order.
Research and limitations are in
`results/P4/jev-first-competitive-audit-20261115.md`.
There are no new measured Jev performance or competitor results here.

## What winning means

Optimize successful, correct work per unit of user time. A faster wrong
answer, missing final word, duplicate input, quick refusal or unverified
Done is not a speed win. Preserve privacy, cancellation, supported features
and the M1/8GB floor. Do not use one aggregate score to hide a weak category.

For each eligible matched category, aim for:

- At least the best comparator's strict success and critical-error rate.
- Dictation: no worse critical content errors or edit burden, and at least
  the same share of drafts usable without correction.
- Faster p50 **and** p95 time to the same verified/usable result, while
  satisfying the relevant absolute speed goal in PROGRAM.
- At least comparable recovery/availability and no regression in target
  safety, cancellation or user effort. Report CPU, RSS, footprint, energy
  and cost in their own units; unknown subscription cost is not zero.

These are stronger objectives than the old minimum release thresholds.
Retain the minimum gates and show every goal gap at the ship decision.
The user can decide to ship a useful candidate while a goal remains open;
the report must not turn that decision into a leadership claim.

Each scorecard row is `lead`, `parity`, `behind`, `inconclusive`, or
`not measured`, with corpus/version/OS/hardware/date/mode/sample count and
evidence. A missing or ineligible comparator is a coverage limitation.
Never promote it to a win. "Best on this measured population" does not
establish "fastest everywhere."

## Category matrix

| Category / owners | Initial comparator or reference | Primary correctness and time measures |
|---|---|---|
| Literal dictation / P3, P13 | Wispr Flow on the same clips; Superwhisper and Apple Dictation as secondary references if available | Raw and normalized WER/CER, exact names/numbers/code/negation/tail, field/selection integrity; speech-end and Fn-release to final insertion plus readback |
| Ready-to-send writing / P3, P10, P13 | Wispr Flow; then the strongest available peer identified by the pilot | Zero necessary edits, minimum edit burden, meaning preservation and correction time; complete usable draft latency |
| Native one-shot actions / P3, P4, P13 | Apple Voice Control/Talon where compatible; direct native/Cua primitive microbench as a separate lower-level reference | Correct target/effect, zero duplicate/unauthorized actions; common input-to-verified-effect clock, S-NATIVE |
| General visual computer use / P4, P5, P13 | Codex Computer Use; matched recorded/reference pixel path | Strict independently verified task success, action count, calls, p50/p95 completion, verified tasks/minute, S-VISUAL |
| Browser operations/workflows / P7, P13 | Browser Use on equivalent controlled tasks/profile state; pixel baseline | Correct data/account/tab/result, stale-ref refusal, loaded-page action and whole navigation/workflow latency separately |
| Hero actions and short workflows / P6, P13 | Supported native app/Shortcuts workflow and eligible voice/agent comparator | Exact recipients/content/dates and result receipts; verified complete workflow time and user interventions |
| Screen questions, lookup and brief / P5, P6, P10 | Appropriate installed assistant/read-only flow when available | Grounded/cited factual answer, omissions and invented facts; first useful answer and complete answer separately |
| Verified repeat work / P9, P13 | First run plus an equivalent supported macro/Shortcuts or agent repeat | Fresh target/consent, strict success, safe retirement; total verified completion and calls saved |
| Gaze-assisted selection / P8, P11, P13 | Previous verified Jev pipeline; eligible same-hardware assistive setup | Correct resolved target and separate actuation, stale-target safety, frame age/FPS, recovery, time and attempts to select |
| Startup, recovery and daily overhead / P10, P12, P13 | Previous signed Jev plus matched feature subsets of available peers | First real readiness, time to first successful action, wake/reconnect, crashes, CPU/RSS/footprint/energy and setup effort |

VisionOS is an interaction reference, not a comparable M1 webcam benchmark.
Do not compare a local model with eyes enabled to a cloud dictation app's
memory and call the numbers feature-equivalent. Show complete Jev resource
cost and matched subsets separately. Competitor evaluation does not add
that competitor's vendor to the production provider policy.

## Dictation: separate the things being tested

Retain two references per clip: words actually spoken and text intended
for insertion. Explicit literal/code requests use an exact-content policy.
Ordinary writing may resolve self-corrections and remove true fillers,
but cannot silently change meaning, names, numbers, dates or negation.
Specify the mode before collecting results; no scoring mode chosen after
seeing the output.

Measure the stages separately:

1. Captured audio and its tail.
2. Raw ASR result, with the current pipeline's provenance.
3. Any permitted normalization/formatting and its explicit changes.
4. Actual inserted text/selection and independent field readback.
5. Human corrections necessary before the draft is usable.

Low raw WER is necessary evidence, not the whole product metric. Conversely,
a polished paraphrase cannot excuse a corrupted exact literal. Record:

- Corpus WER/CER with frozen tokenization and normalization.
- Raw exact-match and dedicated errors for names, quantities, units,
  contacts/addresses/URLs, code, negation, self-corrections and utterance tail.
- Human-adjudicated zero-necessary-edit rate, minimum edit burden and
  correction time. Separate a user's stylistic rewrite from an ASR error.
- Substituted/invented/deleted content, hallucination on silence/noise,
  insertion into a decoy field, double delivery and selection corruption.
- Speech-end → insertion, Fn-release → insertion, readback/verified
  completion, first partial and cold readiness; p50/p95 and fractions
  over 150ms, 500ms and 1s. Display-only partials never stop the timer.

Wispr's under-700ms published budget starts at speech end and includes
recognition, formatting, OS and network delay. It is not a measured median
or a Fn-release number. Our 50ms/150ms goal retains its original clock;
the speech-end measurement prevents a longer hold from creating a fake win.

## Bounded dictation evaluation

Reuse the current 35 P3 recordings as regression evidence; do not call
them held-out data after they have guided changes. Do not amend the
existing physical P3 population silently.

The initial comparison pilot uses 24 declared controlled clips across
lengths, clarity, literal/writing modes and vocabulary. Run the exact same
audio through the real Jev and Wispr applications with identical timing
and audio delivery, then inspect the actual destination text. Use an
existing recorder/replay path; do not write another audio framework.
The pilot identifies causes and does not establish global accuracy.

After the candidate changes stabilize, freeze a separate qualification
population of at least 120 distinct clips, initially 15 in each stratum:

1. Ordinary messaging/email.
2. Work names, proper nouns and technical vocabulary.
3. Numbers, dates, units, contacts, URLs and code/literals.
4. Negation, corrections, restarts and fillers carrying actual meaning.
5. Very short speech, quiet speech and words ending at release.
6. Background speech/noise, far-field and microphone variation.
7. Longer multi-sentence writing, pauses and uninterrupted tails.
8. Supported accent/language variation and declared code-switch challenges.

Predeclare language support and unsupported challenges; do not silently
exclude difficult recordings after the run. Use consenting speakers or
licensed recordings with reviewed references; do not copy a competitor's
private corpus or invent speakers. For generalization beyond the test
users, obtain a real multi-speaker held-out set and state its limits.
120 is an initial bounded sample, not a guarantee of statistical power.

Neutral-profile and personalized-dictionary tracks are separate. Supply
equivalent permitted context to both products and record it. Evaluate
false corrections as well as name gains. A personal lexicon must be
user-controlled, local by default and removable; learning must distinguish
recognition fixes from intentional rewrites. No broad reading of mail or
notes to manufacture context.

Randomize/interleave paired runs with a recorded seed; keep machine,
microphone/audio path, accounts, locale, app state and network observations
comparable. The digital-audio comparison proves the deployed dictation
pipeline, not physical Fn/microphone capture. Add the required real
physical checks once on the frozen candidate, reusing their evidence.
Record capture failures separately and retain them in overall reliability.

## Scoring and uncertainty

Use existing validated scoring where suitable; prefer Apache-2.0 `jiwer`
over new edit-distance code. Apache-2.0 AMEND is a reusable method/library,
but its default OpenRouter/Anthropic judge is outside the current provider
policy. Do not execute that default. Human blind adjudication and frozen
literal predicates are primary; an approved OpenAI evaluator may assist,
with its prompt/model and disagreements reported.

The public Voice Arena leaderboard uses five-provider LLM consensus for
zero-edit rate and Opus for AMEND. A local adapted evaluator is not the
same benchmark. Its normalization can ignore punctuation/case; retain
raw checks for code, URLs, names and quantities so it cannot hide errors.
The acting model must not judge its own action completion.

Predeclare success and paired speed/accuracy comparisons. Use PROGRAM's
Wilson discipline for binary outcomes and paired uncertainty intervals
for edit/latency deltas, clustering by utterance and speaker as applicable.
For a strict "at least as accurate" or "faster" claim use a zero regression
margin; inconclusive intervals do not prove parity or leadership. Show
point estimates and intervals, not a naked rank. Repetitions of one clip
do not create independent accuracy examples.

Freeze attempts/cost/time and analysis before execution. At the cap,
report inconclusive rather than collecting until significance appears.
Additional samples need a specific statistical gap and bounded run plan.
Do not make the user repeat manual recordings to enlarge an automated
sample count. This is a staged evaluation within existing P3/P13, not
a new phase or an indefinite benchmark project.

## Computer-use comparison and optimization

Jev-only and Jev-with-Terra-recovery are the deployment-policy comparison.
Terra-only is an optional diagnostic reference on the uncertain subset,
not a search to replace Jev. Freeze observations, tasks, executor,
permissions, verifiers, deadlines and matching start states. Record
direct/Jev/Terra route, escalation cause/rate, false/unneeded escalations,
recovery success, requests, token/cost evidence, state/capture reuse and
unattributed time. Do not minimize escalation rate by accepting wrong
Jev choices or maximize success with repeated unbounded requests.

Start the automation clock when the task is submitted, before routing,
observation or planning. Voice adds its separate complete Fn-release
clock. Report verified completion in Jev; if an external benchmark stops
at model Done and verifies afterward, publish that separate clock as well.
Cold attach/launch, canceled/failed work and user confirmation time stay
visible. Preserve safety-confirmation rules even when a comparator skips
them. Report common-success paired latency plus all-task success,
timeouts and throughput to prevent survivor bias.

Optimize the measured critical path: persistent driver/browser sessions,
small but complete scoped AX/DOM observations, in-memory screenshot reuse
for one observation, concurrent independent reads/judgments, native typed
actions and condition-based settle. Capture after a mutation must reflect
its consequence. FastCUA research shows that prematurely fast screenshots
can cause more retries and slower completion; zero sleep is not zero wait
for the required condition.

No fixed long browser "network idle" requirement when the target/result
is already demonstrably ready. No blind action batching across changed
pages/windows. Keep target, permission, input and verification costs
separate so a faster SDK call cannot stand in for faster successful work.

## Delivery and evidence

C1 adds the timing/quality pilot and fixes the demonstrated bottleneck.
C2 measures whether Terra recovery adds enough successful capability for
its latency/cost while preserving Jev as primary. C3 produces the matched
dictation and category scorecard on one frozen signed artifact.

Reuse existing bench, P3 replay/native witnesses, LatencyLedger and phase
reports. Future evaluation assets, scoring configuration and raw results
live under the owning P3/P13 evidence directories, with a frozen manifest
and compatible owned-path amendment. No new benchmark service or
orchestrator. Every result identifies actual source/runtime/clip hashes;
normal diagnostics do not retain private speech/text by default.
