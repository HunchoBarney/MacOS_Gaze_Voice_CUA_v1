# Jarvis execution simplification plan

Status: 2026-09-25, updated after unlocked-session proof and exact-package
setup verification. Steps 1–2 have a recoverable baseline and installed-contract inventory for
all 58 Driver tools. Step 3 provisionally selects Swift/stdio. One bounded
observe–choose–act–verify loop serves normal runtime requests; new action
families remain behind an isolated candidate surface. Real Jev/Cua evidence
includes exact native text with preserved seed content, quoted browser
search/navigation, direct quoted navigation, an approved single-file upload,
hover, an accepted JavaScript dialog, a native new-document workflow, and the
pinned-scroll refusal after one observed 500 px effect. The latest continuation
also passed a simulated-transcript production new-document task, real-effect
post-dispatch timeout inspection and cancellation fixtures, and one isolated
browser drag/drop candidate. Sample sizes and failures are in the newest
replacement and scoped evidence entries.

The pinned Driver still cannot verify repeated browser scrolling; the isolated,
uninstalled candidate passes two effects with independent positions `[500,
1000]`. The latest setup code writes its disposable fixture under the system
temporary directory, follows the installed `launch_app` schema, and requires an
exact verified foreground window before reading or typing. The 2026-09-24
opt-in check stopped while the console was locked. With the console unlocked,
one check completed after a bounded wait for the pinned Driver's launch
watchdog. The Cua permission probe reports Accessibility and Screen Recording
granted. Immediate production opening remains unproven.

The latest release app and archive are built and signature/extraction
verified. Its visible packaged setup check passed a disposable Cua/Jev
insertion, but a normal production voice task through that package remains
unverified. The full Swift suite passes 320
tests with 34 opt-in skips, and all six tooling tests pass in workspace-local
verification. The Makefile `make test` target now passes when run through a
workspace-local `swift` shim that directs SwiftPM to a fresh scratch directory;
an unwrapped invocation still hits the preserved `.build` cache from the prior
workspace. No retired production path or protection has been removed. Steps 4,
6, 7, 8 and the final gates remain open; see
[the scoped implementation record](EXECUTION-SIMPLIFICATION-REPLACEMENTS.md).

**Goal:** replace overlapping Jarvis execution machinery with existing Cua/Jev
capabilities, keep one production execution loop, and preserve the existing
voice/UI system. Prove replacements before removing current protections.

**Next deliverable:** finish the remaining live native/browser and lifecycle
proofs, run a normal production task through the exact package, establish matched
measurements, and retire only mechanisms with proven Cua/Jev replacements.
Keep the pinned-scroll refusal and repetition guard until a supported runtime
postcondition passes. Do not retire a protection until its replacement passes
the corresponding success and failure checks.

**Current priority:** the installed Cua pin cannot independently confirm the
browser scroll outcome required for safe repetition. The preserved local
scroll-readback patch is uninstalled. Its embedded candidate reports current
Accessibility and Screen Recording grants as false, but a fresh loopback DOM
scroll proof succeeded; this does not establish candidate native-action
readiness. Do not change the pin or automate TCC. Continue independent proofs and
keep candidate routes isolated until representative action families and packaged
acceptance meet their gates. Treat setup/diagnostic tools and exact user-supplied
arguments separately from ready-to-dispatch observed actions.

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

- [x] Define success as a smaller production execution system that delegates
  proven responsibilities to Cua/Jev while retaining existing voice, UI, settings,
  credentials, authorization, and task behavior.
- [x] Record the current source revision, tracked/untracked changes, local Cua
  modifications, selected Driver identity, packaged app identity, and recoverable
  baseline. Preserve existing uncommitted workspace-setup work.
- [x] Use the configured Conductor setup and verify supporting source and generated
  outputs are workspace-local. A setup command that skips missing assets is not
  proof that the workspace can build the selected integration.
- [x] Keep shared reference assets read-only. Never use the legacy cache path for
  workspace outputs. Review tracked Cua source changes before sharing them in Git;
  preserve ignored development assets separately.
- [x] Run relevant baseline checks and record known failures separately from
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

- [x] Give every candidate replacement a row with the following fields.

| Field | Required content |
| --- | --- |
| Current responsibility | What behavior the Jarvis code provides |
| Current owner | Concrete code and relevant tests |
| Proposed owner | Existing component and exact revision |
| Availability | Present in selected runtime, integration needed, or narrow upstream change |
| Contract | Inputs, identities, outputs, failure and cancellation semantics |
| Deletion evidence | What must pass before the Jarvis mechanism can go |
| Remaining host work | Any evidenced gap and why it remains necessary |

- [x] Distinguish available upstream, present in our source, installed, and verified
  through Jarvis. Do not assume current upstream documentation describes the pinned
  runtime.
- [x] Investigate candidates until the evidence supports a decision. Keep the
  inventory bounded to responsibilities this task can replace.

**Gate:** each proposed deletion has a named replacement and a concrete proof
requirement.

## 3. Select one reusable execution integration

- [x] Evaluate the full external `jev-use` approach first, including useful
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

- [x] Choose the language/process boundary after this comparison. Preserve upstream
  code directly where practical. If a native adaptation is smaller overall,
  document what is adapted, why, and which upstream tests/contracts transfer.
- [x] Count custom code, local upstream patches, runtime dependencies,
  startup/shutdown handling, IPC, and packaging effort together. A reduction in
  Swift files alone does not establish simplification.
- [x] Compare another framework only when a specific capability demonstrably
  replaces additional machinery. Changing Jev remains a separate product decision.
- [x] Record the selected Driver pin and the current `jev-latest` model alias;
  the alias is not an immutable revision. Do not blindly adopt the
  restricted chooser CLI, rewrite everything in Swift, or add a Python service
  before assessing the integration boundary.

**Checkpoint:** the Swift/stdio boundary is provisionally selected and its
dependencies and remaining gaps are recorded. Final adoption still requires the
live integration, reliability, and packaging gates below; do not describe the
Jev alias as a pinned model revision.

## 4. Expand grounded Cua choices and prove native/browser workflows

- [x] List the installed pinned Driver's 58 advertised tool names and assign
  preliminary dispositions in the replacement record. This is not a validated
  contract or complete action-coverage inventory.
- [x] Check the installed input/output, targeting, refusal, background/focus,
  session and verification contracts for each applicable family. Record whether
  it has a grounded route, a required integration gap, or a justified exclusion.
  Distinguish explicit user-directed window changes from excluded automatic
  arrangement. Browser preparation/attachment is a lifecycle prerequisite for
  normal browser work, not merely a setup diagnostic. Include session/cursor
  controls in the host capability map even where they are not Jev choices.
- [x] Stage new choices in an isolated candidate before promoting them to the
  normal execution path. Move the current browser pointer additions behind the
  candidate seam before packaging or releasing the app: they currently sit in the
  same catalog source but are visible only on the candidate surface. The runtime
  defaults to production; candidate effects require an explicit live-test route.
  Candidate failures must not silently fall back to another executor.
- [x] Add immutable task/revision-bound candidate IDs, grouped/paged choices,
  typed observed arguments, and exact-span binding for quoted literal payloads.
  Automated catalog and parser tests cover the candidate seam; they do not
  establish all live action-family effects.
- [x] Expand native and browser choices using the Driver's actual capability and
  observation contracts. Present only actions with a resolved target and typed
  arguments. Jev selects one immutable candidate ID, reobserve or abstain;
  Jarvis validates task authority and Cua validates the supplied target at dispatch.
  Bind URLs, keys, values, file paths, coordinates and dialog decisions from an
  unambiguous user-owned span or current observation, with the originating task
  revision. Ambiguous or truncated payloads abstain or ask for clarification.
  Apply the existing confirmation and privacy rules before dispatch, including
  exact confirmation for destructive operations. Do not enable high-impact or
  ungrounded calls through model-produced tool JSON.
- [x] Keep choices manageable. Jev Choice accepts at most 255 options; when a
  snapshot has more candidates, count action and control choices together, then
  select a relevant target/group before its action without silently discarding
  controls. Automated coverage of 600 actions proves every target remains
  reachable through paging and preserves no-match/reobserve paths. Dense live
  snapshots and candidate/context-size comparisons remain unmeasured.
- [ ] Prove representative actions and refusals from the selected native and
  browser families, including keyboard/value, pointer/drag, menu, navigation,
  text, dialog and file operations where the installed contract supports them.
  Record supported background routing and the cases that visibly wait for
  foreground participation. Tool advertisement alone is not effect proof.
- [ ] Prove the following workflows sequentially against disposable content.

| Workflow | Observable proof |
| --- | --- |
| Open TextEdit, create a document, insert supplied text | A genuinely new document contains the exact text; existing content is untouched |
| Browser search and navigation | Correct query, tab identity, destination, and navigation outcome |
| Repeated scrolling | Two intentional requests produce two effects |
| Changed target | Stale references are rejected or refreshed without switching destinations |
| Cancellation | No further dispatch after cancellation is acknowledged; in-flight effects are reported accurately |
| Timeout after dispatch | State is inspected; the action is not automatically repeated |

Current evidence: exact quoted browser search, direct navigation, upload, hover,
and dialog each have one real Jev/Cua trial on the pinned installed Driver. Exact
native text passed once through the production runtime with the seed preserved;
a separate native new-document trial also passed after a test-only nine-second
settle, preserving its seed. On the pinned Driver, a repeated-scroll trial now
ends with one observed 500 px effect and an explicit incomplete refusal before
any later mutation. The same workflow passed on the isolated patched Driver with
positions `[500, 1000]`; the patch is not installed or enabled in production.
Browser stale-tab live behavior, live cancellation/timeout inspection, and broad
native key/value/drag proof remain open. The older unquoted write form is now
refused unless it is one quoted span or explicitly begins with `dictate`/`say`;
unquoted browser search extraction is not established.

The 2026-09-25 unlocked continuation added one isolated stale-page refusal after
navigation, a native `verify_state`/`set_value`/retired-token proof, and a
repeated native Return-key refusal with no newline. These samples do not prove
changed-tab/frame behavior, native drag, cancellation after live dispatch, or
timeout recovery. A structured `effect=refused` shape from the stale browser
probe exposed and drove a host transport fix; no Step 6 protection was removed.

Source review confirms the production `CuaVoiceRuntime` leaves
`CuaTaskAgent.allowConfirmedRepetition` at its initializer default `false`; only
test harnesses enable it. The production loop therefore suppresses a previously
completed effect identity from later choices even when the dispatch result
contains confirmation evidence. Keep this protection until the pinned runtime
passes the live repeated-action and postcondition checks.

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

**Step 4 gate:** the coverage map distinguishes working routes, required blockers,
and justified exclusions. An unresolved required action family does not pass this
gate. Selected IDs resolve to original Cua arguments; representative native and
browser effects, refusals, and background/focus behavior have live evidence;
dense candidate sets do not silently hide controls. The exact native text/replay
workflow must pass before production promotion. Report interim checkpoints without
claiming this gate has passed.

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

- [x] Define the integration contract using existing types where possible. Preserve
  task identity, request revisions, cancellation, approval scope, and terminal
  outcomes. `CuaVoiceRuntime.Work.id` and speech revisions remain host-owned;
  `CuaActionOwner` binds candidate IDs to the work UUID and revision. Existing
  runtime/controller, cancellation, correction, provider, and approval tests pass
  in the 2026-09-23 full suite.
- [x] Keep one authority over desktop execution. The loop can make several bounded
  judgments and perform necessary verification. Jarvis must not independently
  maintain another planner deciding the next desktop action or declaring the same
  goal complete. Normal runtime work is delegated to one `CuaTaskAgent` loop;
  task relationship routing remains a host boundary decision.
- [x] Preserve working speech behavior at this boundary. Adapt how completed
  requests and corrections enter execution without redesigning capture or the UI.
- [x] Preserve provider configuration and credential handling. Generated plans or
  advice remain data subject to the same execution and authorization checks.

**Gate status (2026-09-23):** normal `CuaVoiceRuntime` requests use the selected
observe–choose–act–verify integration, not a second desktop planner. Here,
“candidate path” means that selected integration; experimental action families
remain isolated behind `CuaActionSurface.candidate`. One live Jev/Cua runtime
trial verified exact native text with the seed preserved, and automated runtime,
controller, correction, cancellation, approval, and provider suites pass. Broader
live follow-up/correction/provider behavior and packaged-app acceptance remain
Step 7/8 validation work.

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
| Completed-action descriptions | An observed outcome plus explicit additional intent permits repetition; uncertain dispatch remains suppressed until state is inspected. A dispatch UUID labels history but does not prevent replay |
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

- [x] Start with relevant existing suites for task execution, action catalogs,
  browser targeting, voice-controller integration, generation, approval, launch
  correction, and task coordination. Carry over useful upstream contract tests.
  Add coverage for actual gaps discovered during replacement.
- [x] Exercise the changed production path explicitly. A real Jev decision through
  `CuaVoiceRuntime` and installed Cua inserted one exact quoted native literal and
  preserved the seed. This proves one runtime workflow; it does not establish
  packaged application acceptance.
- [x] Prove two unrelated background text tasks can progress at once in distinct
  disposable app windows; both addressed bodies were checked and foreground stayed
  on the prior app. This does not prove same-app window concurrency or visible
  cursor identity.
- [ ] Cover native documents, browser navigation and repeated actions, follow-ups,
  corrections, cancellation, drafts remaining unsent, stale observations,
  uncertain outcomes, and concurrent tasks preserving user focus/text. For shared
  desktop work, show two distinct Jarvis tasks with matching Cua session/cursor
  identities. Prove independent addressed windows can progress concurrently where
  Cua supports background input; serialize actual focus, menu, clipboard and
  same-document conflicts. Visible cursors alone do not prove safe concurrency.
- [ ] Compare baseline and candidate using matched fixtures and initial states.
  A static inventory against baseline `d756cf3` and implementation commit
  `5bec4a6` is recorded on 2026-09-24 below. In the tracked production Swift
  scope (`ComputerControl` plus core `Models`), physical source lines grew from
  1,883 across 17 files to 3,083 across 19 (+1,200, about 64%; comments and blank
  lines included). The implementation diff also adds 2,589 net Swift test lines,
  139 fixture lines, 117 workspace-tooling lines, and three uninstalled Cua
  patch candidates totaling 684 patch lines plus a 54-line JavaScript test.
  `Package.swift`, `Package.resolved`, and `Makefile` are unchanged; the existing
  Swift-to-pinned-Cua process boundary remains. This is a scoped code inventory,
  not a matched behavior or simplification result. No old production protection
  has been retired, so these counts show current implementation growth rather
  than a demonstrated reduction in maintenance burden.

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
- [x] Distinguish automated simulations, recorded-audio checks, observed app
  behavior, and user-reported physical input. Preserve pre-existing failures as
  separate evidence. Current evidence labels automated and live-fixture results;
  no recorded-audio or physical Fn/microphone result is claimed.
- [x] Run the current integrated Swift and tooling suites. On 2026-09-24, the
  Makefile `make test` target passed through a workspace-local `swift` shim,
  invoking `swift test --scratch-path
  .context/execution-simplification/swift-scratch-native-new-document`; all six
  tooling tests passed, as did 317 Swift tests with 31 opt-in skips and zero
  failures. The new setup-flow opt-in is among the skipped desktop checks. A
  direct unwrapped `make test` still fails before compilation because `.build`
  contains a module cache from the prior workspace path. The preserved cache was
  not changed. The exact wrapper run is logged at
  `.context/execution-simplification/make-test-workspace-scratch-2026-09-24.log`.
  Broaden or repeat checks when edits, failures, or unresolved risks justify it.

**Gate:** agreed changed behaviors pass, existing supported behavior is preserved,
and reduced complexity is demonstrated without hiding failures.

## 8. Review, remove the retired path, and deliver

- [x] Review the complete change against the preserved baseline, including ignored
  Cua source patches and packaging changes. A fresh read-only review of
  `99d66cf..1d8d841` found no Critical, three Important and three Minor issues.
  All three Important findings received failing-first regressions and focused fixes;
  the full regression suite passes. Per the review workflow, no second review was
  requested. Deferred Minor findings and the reviewer’s Declined-to-judge rulings
  are recorded in the ignored SDD progress ledger.
- [x] Prioritize late actions after cancellation, duplicate mutations, incorrect
  destinations, false completion, and interference with user focus or edits.
  The review-fixed native rebind preserves selected-control semantics; unresolved
  scroll outcomes stop the task before any subsequent action or success claim.
- [x] Resolve material findings and rerun affected checks. The three Important
  regressions passed in the focused suites and `make test` passed afterward.
- [ ] Remove the superseded production loop, duplicate state, and unused
  dependencies after replacement proof. Preserve useful regression coverage and
  recovery artifacts. Finish with one production execution path.
- [x] Build with `make dist`, verify the candidate bundle signature, and preserve
  an archive plus prior packages for recovery. The 2026-09-25 final-code
  checkpoint uses unchanged app identity `com.chriswozniczek.jevvoice`,
  executable SHA-256
  `75fa830ff445610ebda7b1ab928bdc5782f46a9279c0074025caf4f98602507f`,
  and ZIP SHA-256
  `b5f609180132a00ef03aef4f6ff44cc64328a7c41bb18fa699085e2fd31687d3`.
  Strict signature verification, archive integrity, extraction, and executable
  comparison pass. It is under
  `development/JevVoice/verification/execution-simplification/scoped-delivery-2026-09-25-final/`;
  the verified 2026-09-24 r2 archive remains available for rollback.
- [x] Open the exact final-code package and inspect its visible setup state.
  The 2026-09-25 build was launched by exact path with `--settings`; its Voice
  pane later displayed Microphone and Accessibility checked, and its Commands
  pane displayed the stored Jev key without revealing it. No grant was
  automated. The earlier r2 package remains the verified rollback.
- [ ] Verify setup and pass a normal desktop task through the exact packaged
  app. The final-code package's `Test Cua + Jev` button passed its disposable
  TextEdit setup insertion and fresh readback. This is a setup workflow, not a
  `CuaVoiceRuntime` voice task; packaged production-path acceptance is open.
- [ ] Record matched baseline/candidate comparisons and explain their limits. No
  controlled matched set exists yet; current samples and the missing baseline
  model/Driver counts are recorded in `docs/voice-ui/EVIDENCE.md`.
- [x] Record build identity, local repairs, test commands/results, retained gaps,
  and rollback instructions in the scoped evidence. The prior app recovery archive
  and verified extraction are documented there. The false-completion finding and
  its host refusal fix are included; matched performance comparison remains open.
- [x] Commit focused changes without absorbing unrelated work after final review.
  Commit `5bec4a6` contains the source, regression coverage, plan, and scoped
  evidence. No push was made; ignored `.context/` and `development/` recovery
  assets remain local. Package UI/task acceptance and the other open gates below
  remain incomplete.

**Completion criteria:** the selected replacement is integrated and verified,
superseded production machinery is removed, packaging and packaged-task checks
pass, and evidence explains what became simpler. These criteria are not yet met.
Unrelated migration requirements retain their existing status.

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

Copy the prompt below into a local Conductor implementation session containing
this workspace's changes. The document alone does not start an agent. The
prompt authorizes completion of this **scoped simplification**, with the active
voice specification as a constraint; it does not close unrelated migration gates.

> Complete the approved Jarvis execution simplification end to end in this local
> workspace. Work autonomously through implementation, verification, review,
> packaging, and delivery while I am away. Do not stop at milestones for routine
> decisions or return a partial implementation as if it were finished. Keep me
> informed of material findings, then give a final report when the scoped outcome
> is achieved or a genuine external prerequisite prevents further useful work.
>
> Read `AGENTS.md`, `README.md`, relevant `docs/ARCHITECTURE.md`,
> `docs/DEVELOPMENT.md`, this plan, its replacement record, and the applicable
> `docs/voice-ui/SPEC.md` requirements. Review the current working tree and
> preserve every existing tracked, untracked, and ignored change, credential,
> setting, app identity, Driver pin, and recovery artifact. Use the recorded
> baseline and setup rather than restarting the investigation. The Swift/stdio
> integration choice is provisional until integrated evidence supports it.
>
> First complete action coverage. Check the installed pinned Driver's actual
> contracts, then make applicable native and browser actions available to Jev as
> bounded, grounded choices. Each choice must carry its original Cua tool,
> arguments, exact observed target, relevant preconditions, and task/revision
> ownership outside the model answer. Bind text, URLs, keys, coordinates, paths,
> dialogs, and other arguments from unambiguous user input or current observation;
> ask or abstain on missing, conflicting, or truncated input. Handle more than
> 255 potential choices without silently hiding controls. Include browser
> preparation, session/cursor lifecycle, and explicit user-directed window
> changes in the appropriate host paths. Stage unproven choices behind the
> isolated candidate seam before packaging. Apply the existing confirmation,
> privacy, focus, and cancellation rules to every new action family.
>
> Prove the expanded choices with real Cua/Jev effects and refusals using
> disposable native and browser content. Resolve the recorded truncated-text,
> changed-label duplicate-insertion, repetition, stale-target, and uncertain-
> outcome failures. A dispatch ID, accepted call, or model completion claim is
> not proof of the requested effect. Never automatically repeat an uncertain
> mutation. Review the current 16-pass loop as an implementation limit, measure
> real workflows, and retain a bounded stopping policy that does not silently
> truncate valid work.
>
> Integrate one production observe–choose–act–verify loop. Keep Cua responsible
> for supported observation, targeting, actions, verification, sessions, and
> visual cursors; Jev chooses from grounded options and judges progress; Jarvis
> retains voice/UI, exact user content, goal/task identity, authorization,
> cancellation, and conflicts. Preserve follow-ups, corrections, optional text
> generation, unsent drafts, and provider credentials. Prove two distinct tasks
> can progress in independently addressable windows when Cua supports background
> input, while focus, menus, clipboard, and same-document conflicts wait or
> serialize. Multiple visible cursors alone are insufficient proof.
>
> For every proposed deletion in Step 6, name its replacement, prove the relevant
> success and failure behavior, remove only the superseded production mechanism,
> and rerun affected checks. Keep request-specific protections that Cua cannot
> express. Finish with one production desktop executor and no silent fallback.
> Do not resume unrelated P0–P5 migration work merely to enlarge this task.
>
> Check your own work adversarially: inspect complete affected paths and the
> final diff for duplicate effects, incorrect destinations, false success,
> late actions after cancellation, lost user text, focus theft, credential leaks,
> and concurrency conflicts. Run focused tests as changes land, `make test` for
> the integrated result, and the Step 4/7 disposable live workflows through the
> changed production path. Compare baseline and final task success, failures,
> latency, model/Driver calls, and total maintenance burden using matched
> fixtures; state sample sizes and limits. Build the packaged app with `make app`,
> verify its signature, launch and exercise the affected path from that bundle,
> and preserve a recoverable previous package before any replacement. Record
> exact commands, build identities, observed results, regressions, unresolved
> gaps, and rollback steps in the scoped evidence ledger. Fix material findings
> and repeat only checks affected by the fix.
>
> The replacement record documents prior authorization for serialized live
> desktop checks. Use the shared desktop lock, disposable content, and a fresh
> permission probe. Never send real messages, purchase, or alter personal
> content as a test. If macOS requires a new user-controlled grant or another
> external prerequisite blocks a check, continue all independent work first.
> Do not treat silence, elapsed time, or a failed check as approval or success.
>
> Stop only when the scoped acceptance gates pass, the retired production path
> is removed, the packaged app and recovery path are verified, and evidence
> supports a finished result. If an external prerequisite still prevents
> completion after all independent work is exhausted, report the exact blocker,
> what passed and failed, and the one action needed from me. Do not claim the
> broader migration or physical Fn/microphone acceptance without its own proof.

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
