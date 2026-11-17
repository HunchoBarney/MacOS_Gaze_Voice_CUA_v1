# P4 decision and speed recommendation

2026-11-12 UTC. Research requested after the decision-architecture diagnosis.
This is a recommendation, not an approved behavior amendment or a speed result.
Read PROGRAM, PLANS, current PROGRESS, the P4 owned paths and acceptance file.
Loaded TypeSafe and enliven guidance. No new model request, desktop interaction,
test, build, install, dependency change or acceptance change.

## Recommendation

Make the decision contract explicit first, with batching designed into that
change. Then reduce repeated observation work. Consider driver action bundles
only after those boundaries are sound. Keep the existing model, pricing policy,
authority checks and completion requirements.

The useful target is fewer sequential decisions and less repeated native work
per verified command. A faster refusal does not meet the reliability bar.

## Evidence already available

- The retained D14 comparison audit reports baseline 3/3 strict successes,
  successful median 7472.912625 ms. Candidate: 2/3, successful returns
  4022.587208 and 4027.342125 ms, no qualifying median, zero false Done.
  P4-5/P4-6 remain false. Source:
  `.agent/results/P4/jev-native-dispatch-live-results.md` and
  `native-d14-calculator-comparison-r3/comparison-audit.json` in the retained
  `completion-research-20261110` evidence root.
- The older controlled cursor-duration probe measured approximately
  800–876 ms native RPC medians with automatic glide, versus 364–425 ms with
  120 ms glide. A separate post-action-wait probe saved approximately
  97–130 ms per RPC (savings rounded down). These are separate diagnostic contrasts, not additive
  estimates of the current build. D14 already integrates both controls.
  Source: `.agent/results/P4/jev-native-dispatch-latency-plan.md:28-83`.
- A retained SDK read of 44 elements took 1427.250375 ms; another attempt
  returned only four nodes at its 5000 ms timeout. This is separate from the
  Swift collector's 500 ms traversal budget. Preparation time was outside
  the D14 goal clock; those rows do not qualify production cold startup.
- The old refinement capture had all 36 candidate-support scores below .90,
  maximum .86. A coherent candidate identity is necessary but does not prove
  that this particular judgment will improve. The latest D14 refinement
  answers remain unknown. See
  `.agent/results/P4/jev-decision-architecture-diagnosis.md`.

## What current external work supports

1. **Batch independent judgments, with explicit premises.** TypeSafe's current
   parallel-questions cookbook reports 0.24 s for 13 questions together versus
   2.81 s summed across 13 sequential requests over the same document. Its
   11.8x result is a vendor example, not a prediction for Jev Voice. Our chooser
   already batches many questions. The opportunity is removing avoidable
   dependency between requests, not adding batching for the first time.
   Questions cannot see each other's answers; each must name its candidate
   and operation in instructions/state. A question ID alone supplies no meaning.
2. **Read the necessary region and preserve identity.** Vercel agent-desktop
   documents map/drill/act/re-read, snapshot-scoped references, native object
   identity on macOS, explicit partial observations and independent delivery
   status. Its skeleton is not a blanket promise to skip a full identity
   read: some reference paths still require complete-window uniqueness.
   Transfer the scoped-evidence principle, not an assumption that less text
   returned means less native work.
3. **Bundle predictable execution, stop at a boundary.** Vercel batches run
   sequentially, are not transactions, and need stop-on-error. For
   action-then-event waits, the baseline is collected before the action.
   Anthropic's current reference implementation also executes ordered tool
   calls and marks remaining calls unexecuted after the first failure.
   Neither pattern authorizes stale targets or concurrent desktop mutations.
4. **Current Browser Use differs from indexed examples.** Its live 1.0 agent
   docs describe one model request producing a Python cell in a persistent
   REPL. The current parameter page says old `flash_mode`,
   `max_actions_per_step` and several other 0.x options warn and do nothing.
   Borrow the reduction in model/tool round trips; do not recommend obsolete
   knobs or introduce a generated-code executor into P4.

Sources read live:

- https://docs.typesafe.ai/llms.txt
- https://docs.typesafe.ai/patterns/fan-out.md
- https://docs.typesafe.ai/cookbooks/parallel_questions.md
- https://docs.typesafe.ai/api.md
- https://github.com/vercel-labs/agent-desktop/blob/main/CONCEPTS.md
- https://github.com/vercel-labs/agent-desktop/blob/main/skills/agent-desktop/SKILL.md
- https://github.com/vercel-labs/agent-desktop/blob/main/skills/agent-desktop/references/commands-system.md
- https://docs.browser-use.com/open-source/agent.md
- https://docs.browser-use.com/open-source/customize/agent/all-parameters.md
- https://github.com/anthropics/claude-quickstarts/blob/main/computer-use-best-practices/README.md

Anthropic's platform Markdown endpoint returned 403 in this research; its
official public reference implementation was read instead. Its prompt-cache
controls are provider-specific; the inspected TypeSafe API does not document
an equivalent control to transplant.

## Ordered work

### 1. One decision contract, without a new serial planner per action

Carry a concrete proposal: semantic step identity, operation, intended target,
literal reference where applicable, required evidence and expected change.
Reuse existing candidates, task authority and the already-bound second visual
grounding stage. A semantic step may persist; an old AX token must not be
silently reused after a new snapshot.

For candidates whose evidence is already available, ask the applicable
independent judgments together and compose only answers about the same
candidate. A later call remains necessary when new evidence or a prior result
is genuinely needed. Do not move post-action proof before the action or pretend
speculative questions can inspect another answer.

Keep explicit distinctions between step uncertainty, missing perception,
stale identity, policy refusal, delivery uncertainty and failed outcome proof.
Screenshots can resolve missing visual evidence; they are not the universal
response to low action confidence. Retain the full goal separately from the
current step: completing one step cannot mean the whole goal is done.

Initial review surface: `Sources/JevVoice/Drive/JevDecider.swift`,
`Sources/JevVoice/Drive/JevChooser.swift`,
`Sources/JevVoice/Drive/JevVisualDecision.swift`, and the existing candidate/observation contract
consumers. Use the existing tests as their home. Do not couple this first
change to a driver replacement, ASR change or new per-app recipe.

### 2. Reduce native work while preserving the proof's required scope

`Sources/JevVoice/Drive/DriveLoop.swift:1615-1666` currently awaits driver `get_window_state`, then
awaits `nativeRead` and merges the results. Both AX-only and screenshot
observations take this sequence. This is confirmed serialization, not yet a
measurement of how much a different design would save.

Define which target, document and surrounding state each decision/proof needs.
Read the smallest scope that can establish those facts, revalidate identity
and mutable values, and expand when coverage is insufficient. Keep modal,
subject/account and document checks where required. A complete subtree is not
a complete window; existing consumers must not receive a false completeness
flag. The independent native proof must not become trust in an SDK value.

Reuse stable structure only with explicit invalidation and fresh checks.
Notifications can trigger invalidation; notification silence cannot prove
that nothing changed. Do not blindly parallelize two AX traversals against
the same target application or cache permission/completion as durable facts.

`Sources/JevVoice/Drive/NativeWindowObservation.swift:281-295,323-362` also shows why a detached task
and cancellation are not a hard timeout for a synchronous AX call. A future
read-path change must bound in-flight work as well as caller waiting, retain
unknown/partial outcomes, and preserve the current budget rather than raising
it to get a pass. This needs a separate evidence/ownership contract.

### 3. Extend native execution where it removes a demonstrated round trip

Prefer a typed action plus its scoped fresh readback over another whole
observe/decide cycle when the result is deterministically checkable.
Only bundle operations whose targets, arguments and authority are already
established. Recheck necessary preconditions between operations; stop on
navigation, subject change, ambiguity, cancellation or uncertain delivery.
Never replay a partly delivered bundle as if it were a transaction.

Keep visual feedback. Investigate whether a native AX operation can proceed
without waiting for presentation-only cursor travel, using the already measured
animation cost as the hypothesis. Physical pointer operations retain their
own targeting requirements. This is a possible Cua extension, not a new
measured gain; driver-owned files/API changes need their own approved scope.

## Existing optimizations to retain, not rediscover

- `Sources/JevVoice/Drive/JevChooser.swift:258,317,415,510,542`: primary batching and conditional
  follow-up stages already exist. Audit the actual data dependency of each.
- `Sources/JevVoice/Drive/JevVisualDecision.swift:355-415`: later grounding already carries candidate
  identity and batches per-candidate checks. Reuse that machinery.
- `Sources/JevVoice/Drive/DriveLoop.swift:813-817`: this lane already disables the generic extra
  settle wait/read. Removing TaskLoop's default 1200 ms is not a new win here.
- `Sources/JevVoice/Driver/CuaConnection.swift:51-139`: generation-scoped schema caching, session
  motion preparation and advertised dispatch pacing already exist.
- `Sources/JevVoice/Drive/VoiceTaskCoordinator.swift:1200-1291,2201-2226`: driver/roster warming
  during listening already exists.
- `Sources/JevVoiceCore/Models/JevClient.swift:20-35`: URLSession.shared
  is already the default. Persistent HTTP is not a missing basic optimization.

## Proof and gates

Do the first coherent decision change before another live qualification loop.
Turn it into the G1 ExecPlan/G2 contract required by PLANS before production
edits. This research neither supplies independent plan review nor grants a
behavior change. Keep observation and driver follow-ups separately attributable.

Use the existing signed-app comparison instrument after the relevant change,
with a focused failure replay and one clean comparison, not retries until green.
Keep blocked/cancelled commands in reliability results. Report verified
completion time, request count, observation time and action time; separate
cold preparation, first goal, warm goals and physical Fn timing. Judge P4
against its unchanged >=95% success, p50 <=4 s and zero-false-Done bar.
A small diagnostic comparison is not the release reliability sample.

PROGRAM's <=300 ms acknowledgement and T0 target concern different work from
general verified computer use. No end-to-end 2 ms promise is justified by
network and macOS operations. Further speed targets require actual product
measurements. P4 remains 4/6; no speedup, signed candidate qualification,
physical-front-door qualification or installation is claimed here.
