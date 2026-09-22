# Jarvis execution simplification plan

Status: 2026-09-22 reviewed candidate checkpoint. Baseline/replacement map and
selected Swift/stdio boundary recorded; native and quoted browser workflows have
limited live proofs. Scroll readback now has a separately preserved, offline-tested
Driver candidate; repeated scrolling still needs live acceptance. TCC logs identify
the bundled Codex CLI as the isolated Driver's permission owner. Unquoted payload
selection remains unreliable. Production replacement/deletion remain incomplete.
See [the scoped implementation record](EXECUTION-SIMPLIFICATION-REPLACEMENTS.md).

**Goal:** replace overlapping Jarvis execution machinery with existing Cua/Jev
capabilities, keep one production execution loop, and preserve the existing
voice/UI system. Prove replacements before removing current protections.

**First implementation deliverable:** a replacement map, a selected integration,
and a proven native/browser execution path with failure-path evidence.

**Final result:** a smaller Jarvis that delegates everything Cua/Jev can reliably
own, with custom code retained only for evidenced gaps.

## Scope and document authority

This is an execution simplification, not a restart of the broader migration.
[SPEC.md](voice-ui/SPEC.md) remains the behavioral contract;
[the migration plan](voice-ui/PLAN.md) retains its existing gates and backlog.
Use those requirements as behavioral constraints without automatically resuming
P0–P5 or following the broader migration's EXECUTION.md.

Use [ARCHITECTURE.md](ARCHITECTURE.md) for subsystem ownership,
[DEVELOPMENT.md](DEVELOPMENT.md) for commands and live-test rules,
[LOCAL-DEVELOPMENT-STORAGE.md](LOCAL-DEVELOPMENT-STORAGE.md) for workspace isolation,
and [ThirdParty/Cua/README.md](../ThirdParty/Cua/README.md) before changing or
rebuilding Driver. Preserve unrelated work, credentials, preferences, app identity,
dependency pins, and recovery material.

Keep the replacement map, integration decision, deletion criteria and scoped step
status with this plan as implementation proceeds. Record build-specific checks and
measurements in [EVIDENCE.md](voice-ui/EVIDENCE.md), explicitly labelled as execution
simplification evidence and linked to the relevant step. Put generated artifacts
in workspace-local development outputs. Update migration gate status only when
its full acceptance requirements have actually been met.

Existing short-hold speech and live-dictation limitations remain migration work
unless this change causes a regression or they prevent the agreed replacement
proof. Do not silently weaken those requirements or mark them complete.

## Astra execution approach

Use a proof-driven simplification plan: clear ownership, explicit deletion
criteria, and freedom to choose the smallest reliable integration. Define outcomes
precisely, make routine reversible implementation decisions autonomously, and
continue when evidence gates pass. Gates are technical checks, not repeated
milestone approval requests.

Read the context needed for the current responsibility. Keep status and decision
records concise enough to resume without rereading the complete history. Run
verification appropriate to the affected behavior; broaden or repeat checks only
when edits, failures, or unresolved risks justify it.

The research supporting this plan found:

- The bounded `jev-use` chooser selects an ID; it leaves action construction,
  execution, observation, and verification with the host. Adopting it alone would
  retain much of the machinery targeted for removal.
- The pinned full example contains reusable mechanisms and fixture-specific
  logic. Its candidates target a verification form, and completion depends on
  that fixture's `/state` endpoint. General native/browser execution needs proof.
- Upstream proposal [#3961](https://github.com/trycua/cua/pull/3961) adds action
  selection, goal-progress, and reobservation judgments. At research time its
  author reported no desktop validation. Its additional backends are not
  automatically needed here. Refresh its status and inspect actual code before
  adoption; draft or unmerged status alone is not grounds to reject useful code.

These are planning findings, not live validation of the installed runtime.

## 1. Establish scope, baseline, and Conductor workspace

- [ ] Define success as a smaller production execution system that delegates
  proven responsibilities to Cua/Jev while retaining existing voice, UI, settings,
  credentials, authorization, and task behavior.
- [ ] Record the current source revision, tracked/untracked changes, local Cua
  modifications, selected Driver identity, packaged app identity, and recoverable
  baseline. Preserve existing uncommitted workspace-setup work.
- [ ] Use the configured Conductor setup and verify supporting source and generated
  outputs are workspace-local. A setup command that skips missing assets is not
  proof that the workspace can build the selected integration.
- [ ] Keep shared reference assets read-only. Never use the legacy cache path for
  workspace outputs. Preserve ignored Cua source changes as a reviewed patch when
  sharing or backing them up in Git.
- [ ] Run relevant baseline checks and record known failures separately from
  regressions. Preserve secrets in place rather than exporting them into evidence.

**Deliverable:** a reproducible baseline, scoped acceptance checklist, and recovery
record.

## 2. Build a replacement map from actual contracts

Inspect the complete execution path, starting with:

- `Sources/JevVoice/ComputerControl/CuaTaskAgent.swift`, `CuaVoiceRuntime.swift`,
  and `CuaWorkQueue.swift`.
- `Sources/JevVoice/ComputerControl/CuaActionCatalog.swift`,
  `CuaBrowserTarget.swift`, and `CuaVisualObservation.swift`.
- `Sources/JevVoice/ComputerControl/CuaConnection.swift`, the Jev clients under
  `Sources/JevVoiceCore/Models`, and the existing provider integration.
- The voice/task boundary only where it feeds this execution path.
- The pinned `development/JevVoice/cua-source/libs/cua-driver/examples/jev-use/`
  implementation, its tests, and selected upstream changes.

- [ ] Give every candidate replacement a row with the following fields.

| Field | Required content |
| --- | --- |
| Current responsibility | What behavior the Jarvis code provides |
| Current owner | Concrete code and relevant tests |
| Proposed owner | Existing component and exact revision |
| Availability | Present in selected runtime, integration needed, or narrow upstream change |
| Contract | Inputs, identities, outputs, failure and cancellation semantics |
| Deletion evidence | What must pass before the Jarvis mechanism can go |
| Remaining host work | Any evidenced gap and why it remains necessary |

- [ ] Distinguish available upstream, present in our source, installed, and verified
  through Jarvis. Do not assume current upstream documentation describes the pinned
  runtime.
- [ ] Investigate candidates until the evidence supports a decision. Keep the
  inventory bounded to responsibilities this task can replace.

**Gate:** each proposed deletion has a named replacement and a concrete proof
requirement.

## 3. Select one reusable execution integration

- [ ] Evaluate the full external `jev-use` approach first, including useful
  mechanisms from the upstream proposal. Compare implementation boundaries using
  the same requirements below.

| Criterion | Required result |
| --- | --- |
| Native and browser work | Both can use the same execution architecture |
| Action coverage | No restriction to the demo's small candidate set |
| Observations | Relevant semantic, structured, and supported visual evidence reaches the decision layer |
| Task continuity | Goals, follow-ups, and corrections retain their originating task |
| Cancellation | Pending work stops; late results cannot restart execution |
| Uncertainty | A missing response cannot cause an automatic repeated mutation |
| Packaging | Runs from the packaged app without a developer-shell dependency |
| Maintenance | Less custom code and coordination across the entire system |

- [ ] Choose the language/process boundary after this comparison. Preserve upstream
  code directly where practical. If a native adaptation is smaller overall,
  document what is adapted, why, and which upstream tests/contracts transfer.
- [ ] Count custom code, local upstream patches, runtime dependencies,
  startup/shutdown handling, IPC, and packaging effort together. A reduction in
  Swift files alone does not establish simplification.
- [ ] Compare another framework only when a specific capability demonstrably
  replaces additional machinery. Changing Jev remains a separate product decision.
- [ ] Pin the selected revisions and dependencies. Do not blindly adopt the
  restricted chooser CLI, rewrite everything in Swift, or add a Python service
  before assessing the integration boundary.

**Gate:** one selected approach, pinned dependencies, a short decision record, and
explicit remaining gaps.

## 4. Prove native and browser replacement workflows

- [ ] Build an isolated candidate using existing seams where possible. Keep
  candidate selection explicit during development; failures must not silently
  fall back to another executor.
- [ ] Prove the following workflows sequentially against disposable content.

| Workflow | Observable proof |
| --- | --- |
| Open TextEdit, create a document, insert supplied text | A genuinely new document contains the exact text; existing content is untouched |
| Browser search and navigation | Correct query, tab identity, destination, and navigation outcome |
| Repeated scrolling | Two intentional requests produce two effects |
| Changed target | Stale references are rejected or refreshed without switching destinations |
| Cancellation | No further dispatch after cancellation is acknowledged; in-flight effects are reported accurately |
| Timeout after dispatch | State is inspected; the action is not automatically repeated |

The execution sequence is: accept the request → observe → obtain a grounded Jev
decision → validate authority and arguments → dispatch through Cua → consume the
outcome → verify or reobserve → continue or finish.

- [ ] Use Cua's supported verification where it expresses the required condition.
  Retain a narrow application readback where necessary. An accepted call or a
  model's completion judgment does not prove the entire user goal. Contradictory
  application evidence prevents a success claim.
- [ ] Run live checks only when explicitly authorized and through the shared
  desktop lock described in DEVELOPMENT.md. One agent owns live desktop testing
  at a time.

**First implementation deliverable:** the replacement map, selected integration,
native/browser proofs, and failure-path evidence. Report this checkpoint and
continue within the authorized scope.

## 5. Connect the existing Jarvis system to the single loop

Keep ownership explicit:

| Owner | Responsibility |
| --- | --- |
| Existing Jarvis voice system | Fn, microphone, Apple speech, capture/revision bookkeeping |
| Jarvis UI and settings | Presentation, credentials, preferences, approvals, progress |
| Thin integration boundary | Associate incoming goals, corrections, approvals, and cancellation with the correct task/session |
| Selected Jev execution integration | Interpret desktop goals, choose actions, assess progress, request observations |
| Cua | Supported observation, targeting, actions, outcomes, verification, native serialization and session mechanisms |
| Minimal host coordination | Conflicts and lifecycle obligations not covered underneath |
| Existing optional provider | Requested text generation and existing advisory behavior |

- [ ] Define the integration contract using existing types where possible. Preserve
  task identity, request revisions, cancellation, approval scope, and terminal
  outcomes.
- [ ] Keep one authority over desktop execution. The loop can make several bounded
  judgments and perform necessary verification. Jarvis must not independently
  maintain another planner deciding the next desktop action or declaring the same
  goal complete.
- [ ] Preserve working speech behavior at this boundary. Adapt how completed
  requests and corrections enter execution without redesigning capture or the UI.
- [ ] Preserve provider configuration and credential handling. Generated plans or
  advice remain data subject to the same execution and authorization checks.

**Gate:** normal Jarvis requests reach the candidate path, and progress,
clarification, cancellation, follow-ups, and provider results remain correctly
associated with their task.

## 6. Replace overlapping mechanisms with proof attached to each removal

Use the following order where dependencies permit:

| Replacement candidate | Evidence required before removal |
| --- | --- |
| Broad window-content comparisons | Target protection survives relevant changes while unrelated changes do not unnecessarily block work |
| Browser identity comparisons | Correct window/tab/frame and snapshot validity remain enforced |
| Description-based action matching | Validated identities resolve to the intended action and original arguments |
| Predicted window creation/window-set tracking | Rediscovery identifies the requested new document without selecting unrelated windows |
| Ad hoc outcome handling | Structured outcomes preserve refusal, partial effect, uncertainty, and required recovery |
| Custom polling | Supported verification expresses the same condition and preserves its failure semantics |
| Completed-action descriptions | Dispatch identity prevents replay while allowing intentional repeated actions |
| Duplicated Jev plumbing | The selected integration owns the same decision and retains relevant evidence |
| Whole-app locking | Narrower resources are independently addressable and global focus/clipboard conflicts remain protected |

- [ ] For each row, establish the contract, run the focused proof, remove the
  superseded production mechanism, and rerun affected checks.
- [ ] Retain request-specific conditions where Cua cannot own them. A valid target
  does not by itself establish that it is the recipient or document the user
  requested.
- [ ] Narrow task coordination only when evidence permits it. This task does not
  require inventing a replacement scheduler.

These are replacement candidates, not already-proven redundancies.

**Gate:** every removed protection has equivalent evidence; every retained custom
mechanism has a specific responsibility.

## 7. Validate behavior and measure simplification

- [ ] Start with relevant existing suites for task execution, action catalogs,
  browser targeting, voice-controller integration, generation, approval, launch
  correction, and task coordination. Carry over useful upstream contract tests.
  Add coverage for actual gaps discovered during replacement.
- [ ] Exercise the changed production path explicitly. Injected callbacks and mock
  decisions do not establish live Jev behavior or packaged application acceptance.
- [ ] Cover native documents, browser navigation and repeated actions, follow-ups,
  corrections, cancellation, drafts remaining unsent, stale observations,
  uncertain outcomes, and concurrent tasks preserving user focus/text.
- [ ] Compare baseline and candidate using matched fixtures and initial states.

| Measure | Reporting rule |
| --- | --- |
| Task success | Preserve failures, partial results, and uncertainty |
| Latency | Separate task duration, decision time, observation/verification, and queue waits |
| Model calls | Count all decision/provider requests, including retries |
| Driver calls | Count actions, observations, verification, and recovery calls |
| Maintenance burden | Report custom code and dependencies across all languages/processes |

- [ ] Repeat representative workflows and report sample counts. Small samples
  support a preliminary comparison, not a reliable p95. Explain increases in calls
  or latency necessary for correctness.
- [ ] Distinguish automated simulations, recorded-audio checks, observed app
  behavior, and user-reported physical input. Preserve pre-existing failures as
  separate evidence.
- [ ] Run `make test` for the integrated change. Broaden or repeat checks when
  edits, failures, or unresolved risks justify it.

**Gate:** agreed changed behaviors pass, existing supported behavior is preserved,
and reduced complexity is demonstrated without hiding failures.

## 8. Review, remove the retired path, and deliver

- [ ] Review the complete change against the preserved baseline, including ignored
  Cua source patches and packaging changes.
- [ ] Prioritize late actions after cancellation, duplicate mutations, incorrect
  destinations, false completion, and interference with user focus or edits.
- [ ] Resolve material findings and rerun affected checks.
- [ ] Remove the superseded production loop, duplicate state, and unused
  dependencies after replacement proof. Preserve useful regression coverage and
  recovery artifacts. Finish with one production execution path.
- [ ] Build with `make app`, verify the bundle signature, and exercise affected
  behavior from the packaged app. If the selected approach adds a helper, prove
  startup, shutdown, credential handling, and dependencies without relying on the
  development shell.
- [ ] Record adopted revisions, local repairs, test commands/results, measured
  comparisons, retained gaps, and rollback instructions.
- [ ] Commit focused changes without absorbing unrelated work.

**Completion:** the selected replacement is integrated and verified, superseded
production machinery is removed, packaging works, and evidence explains what
became simpler. Unrelated migration requirements retain their existing status.

## Conductor operating arrangement

| Setting | Recommendation |
| --- | --- |
| Primary session | One Astra implementation session owns integration and task state |
| Reasoning | Start with High; increase for difficult contract or concurrency decisions if available |
| Planning | Use Plan mode for review, then execution mode for approved implementation |
| Additional sessions | Use a read-only reviewer at stable checkpoints; split implementation only where deliverables and file ownership are independent |
| Live desktop | One owner using the shared lock |
| Handoffs | Record baseline, selected revisions, completed proofs, remaining gaps, and the next concrete action |

These are workflow recommendations, not a demonstrated optimal Astra
configuration. Source workspaces do not isolate the macOS desktop, permissions,
Keychain, preferences, or installed Driver.

Ensure new workspaces receive the intended setup. Shared repository settings take
effect through Conductor's default-branch configuration; local overrides can
differ. New workspaces do not automatically inherit another checkout's uncommitted
work. Conductor checkpoints supplement the explicit source/runtime recovery
record; they do not replace it.

## Execution prompt

> Implement the approved Jarvis execution simplification. Preserve the existing
> voice/UI system and use the broader migration specification as a behavioral
> constraint.
>
> Start by producing the replacement map and proving one native and one browser
> workflow through the selected Cua/Jev integration. Choose the integration
> boundary from actual source, runtime contracts, and total maintenance cost.
>
> Continue through integration, focused verification, review repairs, removal of
> proven duplicate machinery, and packaged delivery. Make routine reversible
> implementation decisions without milestone approval requests. Report material
> decisions and evidence as you proceed.
>
> Preserve protections until their replacements are proven. Keep one production
> execution loop. Retain custom code only for demonstrated gaps. Do not expand
> this task into unrelated migration work.
>
> Keep live desktop checks explicitly authorized and serialized. If an external
> prerequisite blocks a check, continue independent work and identify precisely
> what remains unverified.
>
> Finish when the scoped acceptance criteria pass, the retired production path is
> removed, and packaging and recovery are verified.

## Research references

Research reviewed on 2026-09-21 local time. Verify changing upstream status and
contracts again when making an adoption decision.

- [OpenAI Astra guidance](https://developers.openai.com/api/docs/guides/latest-model)
- [Rethinking skills and prompts for Astra](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)
- [Cua jev-use integration guide](https://cua.ai/docs/how-to-guides/driver/jev-use)
- [Cua jev-use base contribution #3916](https://github.com/trycua/cua/pull/3916)
- [Factorized Jev decisions proposal #3961](https://github.com/trycua/cua/pull/3961)
- [Cua interface contracts](https://cua.ai/docs/reference/cua-driver/contracts)
- [Cua verification example](https://cua.ai/docs/how-to-guides/driver/verify-a-desktop-action)
- [Conductor agent controls](https://www.conductor.build/docs/concepts/agent-modes)
- [Conductor parallel work](https://www.conductor.build/docs/concepts/parallel-agents)
- [Conductor settings](https://www.conductor.build/docs/reference/settings)
- [Conductor checkpoints](https://www.conductor.build/docs/reference/checkpoints)
