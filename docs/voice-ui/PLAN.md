# Cua + Jev continuous voice migration plan

Status: approved revision recorded 2026-09-19. **Implementation resumed; migration remains incomplete.** Preserve implemented UI, Fn, Apple speech, Swift MCP, Jev and provider work. The new work is broad Cua capability coverage, local perception, reliable continuous intent/dictation, shared-desktop coordination and complete application acceptance. A prior fixture pass does not close a revised gate.

**Contract:** [SPEC.md S1–S9](SPEC.md). **Execution entry:** [EXECUTION.md](EXECUTION.md). Read the current phase and relevant evidence, not the historical plans. Required behavior is firm; implementation choices may change with recorded evidence. The approved direct-transcript voice implementation plan and copy-ready execution prompt are in [2026-09-22-direct-transcript-to-cua.md](../superpowers/plans/2026-09-22-direct-transcript-to-cua.md).

**Scoped execution simplification:** follow
[EXECUTION-SIMPLIFICATION-PLAN.md](../EXECUTION-SIMPLIFICATION-PLAN.md) when replacing
overlapping Jarvis execution machinery with proven Cua/Jev capabilities. That plan
owns its sequence, integration-boundary decision and completion criteria. This
document retains the broader migration backlog; its P0–P5 sequence is not the
simplification task's entry point. Scoped replacement evidence may inform a gate
but does not close it unless that gate's full requirements are met.

## Scope and current progress

| Phase | Existing evidence to preserve | Outstanding gate / dependency |
| --- | --- | --- |
| P0 — Cua foundation and perception | Recoverable snapshots, Swift MCP, Jev and packaged setup; some browser/native fixtures | Audit selected source/PR stack, full capability inventory, native perception and cross-app targeting. Resume here after checking actual code. |
| P1 — Speech readiness and responsiveness | SpeechAnalyzer, ranged transcripts, physical Fn opening, prewarming and stage timings | Preserve implementation; finish lifecycle and cold/warm physical validation. Independent of P0 perception work. |
| P2 — General actions and continuous voice | Normal voice routes to Cua; early opening, simulated revision/cancellation checks | Direct transcript handoff is implemented; complete generic controls, target freshness and owned live dictation. Depends on relevant P0 contracts and P1 events. |
| P3 — Concurrent tasks | Task UI, queue and initial app leases | Persistent contexts, finer conflict coordination, actual two-task progress while user types. Depends on P2 identity/cancellation. |
| P4 — Optional generation/reasoning | Groq configuration, real summary and isolated draft fixtures | Normal-voice source/destination, cancellation and send-boundary acceptance. Reuse configuration; depends on P2 task ownership. |
| P5 — Cleanup and delivery | Staged package and regression evidence | All required acceptance, measured performance, legacy removal, installed package and rollback. Depends on P0–P4. |

No completed functionality is scheduled for reimplementation. The latest recorded stage is `~/Library/Caches/JevVoice/staging/cua-migration/Jev Voice.app`; the installed baseline remains at `~/Library/Caches/JevVoice/build/Jev Voice.app`. Verify actual identities before implementation. Historical claims about a stable Driver lacking perception/range operations describe that inspected build, not a prohibition on building upstream changes.

## Architecture and implementation boundaries

Retain Swift UI/Fn/audio and the existing private-stdio Swift MCP connection. Cua owns computer observation, actions and cursor rendering; Jev selects grounded actions and semantic voice decisions; the configured Groq provider supplies prose and optional advisory reasoning. Keep one production execution path. Do not add a Python service solely because an earlier plan suggested one.

Inspect existing `CuaConnection`, `CuaActionCatalog`, `CuaTaskAgent`, `CuaVoiceRuntime`, `CuaWorkQueue`, `ContinuousIntentCoordinator`, `SpeechAnalyzerCapture`, `VoiceController`, speech provenance types and their tests. File boundaries are not mandated. Inspect legacy executor/parser call sites only as needed for replacement/removal. Reuse existing provider, settings, Keychain and packaging code.

Typed boundaries retain capture/audio-range/revision identity, task and dispatch identity, target/window/tab identity, cancellation and observed outcomes. Preserve MCP images and structured results; do not flatten away perception data. Independent model judgments may batch; dependent actions wait for observed prerequisites. No generic workflow engine, duplicate cursor renderer or second hidden executor.

## Upstream integration shortlist — investigate, do not blindly cherry-pick

These are research candidates, not assertions that their current heads are compatible or accepted on this Mac. At P0 refresh status, inspect ancestry and overlapping diffs, reproduce the relevant failure, and record exact base/head SHAs, dependency order, local repairs, tests and revert path. Prefer already-merged equivalents. Select the smallest coherent set that meets the contract; a PR's draft/unmerged status alone is not grounds to reject it. Upstream test results are not Jarvis acceptance.

| Candidate / source | Purpose and adoption check |
| --- | --- |
| [#3943](https://github.com/trycua/cua/pull/3943), [#3942](https://github.com/trycua/cua/pull/3942) | Preferred native local OCR/icon perception and capture transforms. Build worker/assets and verify actual capture provenance, scale/display coordinates and semantic labels. Check whether transform work is already included. |
| [#3976](https://github.com/trycua/cua/pull/3976) | Background click targeting/positioning; reproduce generic controls across apps and check Chromium interaction. |
| [#3873](https://github.com/trycua/cua/pull/3873) | Fresh native target resolution; breaking element-token identity contract must be adopted consistently, not just on the Driver side. |
| [#3947](https://github.com/trycua/cua/pull/3947), [#3945](https://github.com/trycua/cua/pull/3945) | Custom AX actions and submenu discovery. Distinguish listing from invoking a leaf; inspect lazy menu side effects and response changes. |
| [#3813](https://github.com/trycua/cua/pull/3813), [#3827](https://github.com/trycua/cua/pull/3827), [#3817](https://github.com/trycua/cua/pull/3817) | Useful AX descriptions, schema preservation and truthful macOS observation completeness. Expand truncated trees before declaring controls absent. |
| [#3855](https://github.com/trycua/cua/pull/3855), [#3863](https://github.com/trycua/cua/pull/3863) | Modifier correctness and exact-window foreground shortcuts; inspect the dependency and user-focus effects. |
| [#3816](https://github.com/trycua/cua/pull/3816) → [#3857](https://github.com/trycua/cua/pull/3857) → [#3858](https://github.com/trycua/cua/pull/3858), [#3897](https://github.com/trycua/cua/pull/3897) | Text mutation/commit outcomes. Resolve overlapping changes and enum contracts. Single-line commit support does not prove multiline owned-range dictation. Preserve uncertain outcomes. |
| [#3946](https://github.com/trycua/cua/pull/3946) | Per-action change-detection control. Avoid duplicate settling only when the host performs adequate outcome observation; measure the combined path. |
| [#3019](https://github.com/trycua/cua/pull/3019), [#3886](https://github.com/trycua/cua/pull/3886) | Multi-display cursor surfaces and off-Space cursor visibility. Preserve Cua rendering; verify available physical display/Space cases. |
| [#3961](https://github.com/trycua/cua/pull/3961), base [#3916](https://github.com/trycua/cua/pull/3916) | Factorized Jev selection and progress/reobservation signals. Reuse useful mechanisms without adding unnecessary backends or allowing uncertain decisions to execute through a fallback. |
| [#3391](https://github.com/trycua/cua/pull/3391), [#3373](https://github.com/trycua/cua/pull/3373) | Native action scheduling ancestry; first establish what current Driver already serializes. Host coordination covers task/resource conflicts, not a duplicate native scheduler. |

Secondary candidates only if their failure is relevant: [#1755](https://github.com/trycua/cua/pull/1755)/[#1757](https://github.com/trycua/cua/pull/1757) AX timeout/batching; [#3795](https://github.com/trycua/cua/pull/3795) document metadata; [#3995](https://github.com/trycua/cua/pull/3995) existing-profile browser attachment; [#3872](https://github.com/trycua/cua/pull/3872)/[#3668](https://github.com/trycua/cua/pull/3668) browser identity; [#3800](https://github.com/trycua/cua/pull/3800)/[#3666](https://github.com/trycua/cua/pull/3666) local signing. Missing/false edited metadata is not proof that quitting will preserve user work. [#3914](https://github.com/trycua/cua/pull/3914)'s alternate action chooser is not a reason to add a competing Jev path or narrow coverage to named AX elements.

## P0 — Preserve the baseline and validate Cua capabilities/perception

**Entry:** verify current dirty/untracked source, installed/staged bundles, rollback archives and actual tools/permissions. Preserve secrets in place. Use an isolated Cua source checkout; do not reset this working tree.

- [x] Verify recoverability of the existing baseline; supplement it for changes since the snapshot. Record source/app identities without exporting secrets.
- [ ] Build the preferred native perception PR with a compatible Driver base. Pin source revisions, assets, build commands and selected PR dependencies. Repair tractable build/integration issues. Use `cua-som` or another backend only after documenting a concrete technical reason, not because the native code is unmerged.
- [ ] Inventory the selected Driver's actual schemas/capabilities. Map every applicable capability to task execution, setup/settings or diagnostics, with an explicit reason for platform limitations. A missing Jarvis adapter is unfinished work, not an unsupported Cua function. Verify schema/result compatibility, image transport and installed dependency selection.
- [ ] Prove screenshot → native OCR/icon perception → meaningful Jev choices → Cua action → independently observed effect. Combine semantic AX/DOM with visual regions; retain capture/window/display transforms and provenance. Prevent a result from an old capture being applied to a new target.
- [ ] Validate semantic, OCR-only and icon controls; moved/resized windows; stale captures; available display scales/coordinates. Measure cold/warm perception time, memory and misses. Build the smallest selected PR set and rerun affected upstream and host contract checks together.
- [ ] Prove packaged connection/dependency readiness, cursor feedback, cancellation and helper/worker failure handling. Record any missing native contract as a specific implementation task rather than defaulting to the old executor.

**Gate:** A12 perception checks and A13 schema/inventory checks pass; remaining adapter coverage has explicit P2 owners and is not marked complete. At least one real browser and native-app action has verified effects through the packaged integration. No setup-only or upstream-only pass closes the phase. Record partial gates precisely so independent P1 work can continue.

## P1 — Preserve Apple speech and finish readiness/latency validation

**Entry:** retain the existing SpeechAnalyzer implementation and P1 evidence; inspect the remaining gaps rather than replacing it.

- [ ] Verify assets/language readiness, persistent per-hold capture, range/revision/finality events and no idle capture. Keep microphone UID routing, meter, Fn combinations, Escape and interruption behavior.
- [ ] Profile first and repeated holds: Fn feedback, permission/credential access, microphone setup/first audio, model preparation and transcript delivery. Keep UI responsive while setup waits. Prewarm reusable resources without recording at idle.
- [ ] Cover quick release during startup, trailing words, silence, capture limit, late callbacks, microphone change/loss, sleep/wake and failed assets. Reuse recorded-audio tests plus separate physical Fn/microphone checks.
- [ ] Review lifecycle/thread ownership and finalization, repair regressions and verify the packaged speech path. Microphone test never dispatches commands.

**Gate:** S2/S3 speech requirements and applicable A1/A8 checks pass. Report recorded, simulated and physical evidence separately; one faster hold is not a latency distribution.

## P2 — Generic controls, natural continuous intent and live dictation

**Entry:** relevant P0 targeting/action/perception contracts and P1 ranged events are verified. Preserve verified CUA action behavior while replacing incomplete adapters; do not retain a parallel voice interpreter or hidden executor.

**Approved voice decision architecture (source implemented; full P2 gate remains open):** Apple SpeechAnalyzer text enters the same Jev/Cua task-execution workflow that chooses and grounds actions. The preceding `JevSpeechIntent` interpretation path and its routing/text extraction calls were removed; speech completeness, task relationship, controls, and literal-span selection are part of the executor's first decision. Multiple Jev calls inside that workflow remain available when later calls use new Cua observations. The voice layer keeps capture/revision/finality/provenance and cancellation mechanics only; Swift does not infer speech meaning or independently validate CUA actions. Focused simulated evidence is recorded in [EVIDENCE.md](EVIDENCE.md). See the linked implementation plan for scope and acceptance tests.

- [ ] Expose supported Cua actions with typed arguments and grounded targets: keyboard/modifiers, pointer/drag/scroll, menus/custom AX actions, browser navigation, text/value operations and relevant observation tools. Do not restrict actions to existing demo apps. Expand incomplete observations before reporting an absent control.
- [ ] Persist the task goal and app/window/document/tab context across steps and holds. Validate the selected target and action preconditions rather than exact equality of an entire dynamic page. Reobserve relevant changes; unrelated animation must not invalidate a valid control. Separate unique dispatch identity from intentional repeated actions.
- [ ] Use observed progress and bounded recovery. After an uncertain mutation, inspect state before any retry; do not replay from a timeout or identical action description. Review outcome/settling costs before opting out of redundant Driver polling.
- [x] Keep Apple STT and the existing capture/revision lifecycle. Send transcript text, ranges, finality, capture identity, and task context directly to the Cua/Jev execution workflow. Do not make a separate Jev speech-classification, routing, or text-extraction request before execution; no local model or alternate-framework comparison is part of this gate.
- [x] Resolve completeness, command/content boundaries, follow-up/new-task/correction routing, stop controls, and literal spans in the executor's first Jev decision, alongside the existing Cua app/action context. Subsequent Jev calls remain inside that task execution as Cua observations arrive. Preserve early execution before Fn release, multiple completed requests per hold, coalescing, stale-revision invalidation, and consumed-range tracking; pauses, punctuation and fixed command prefixes do not decide meaning.
- [ ] Complete Cua-owned live text insertion/readback. Reconcile only the hold's owned range, validating target, surrounding content and selection. If needed, add the minimal generic addressed-range contract in Cua using native primitives, with atomic validation where feasible. Do not overwrite the whole field, simulate a range using unverified focus, or revive the legacy writer. Unsupported fields visibly insert on release; TextEdit streaming remains mandatory.
- [ ] Preserve explicit literal dictation, command words inside content, manual mode, task-scoped stop/Escape and safe launch correction. Check cancellation before dispatch and after awaits. Reobserve ownership/user work before compensation; never force quit or dismiss save prompts.
- [ ] Exercise revisions, incomplete searches, negation, conditions, filler, mixed tasks/content, repeated scrolls, finalization, uncertain failures and corrections before/during/after execution. Verify real browser, Notes and media workflows with different phrasings and content.

**Gate:** A1–A5, single-task A8 and A11 pass through normal voice, including real before-release in-app work and owned TextEdit revisions. A release-only insertion or successful app launch cannot substitute for these outcomes.

Additional voice gate: focused simulated tests now prove the first Jev decision receives the exact transcript and task context, stale revisions are discarded, finalization does not replay accepted spans, multiple requests work within one hold, Jev-selected task controls apply to their selected task, and literal text comes from the original transcript. Controller tests also exercise no-dispatch for incomplete, negated and conditional source text when Jev returns `wait`; they do not establish real-model semantic accuracy. These checks do not close the P2 Gate: real-model semantics, live TextEdit owned-range dictation, physical Fn/microphone behavior, and broader application acceptance remain outstanding.

## P3 — Persistent shared-desktop tasks and Cua feedback

**Entry:** P2 target, dispatch and cancellation ownership works. Preserve the existing task UI and Cua cursor renderer.

- [ ] Keep persistent task/session context across utterances and Fn holds. Default to three active tasks, queue overflow, and use stable session labels in both Cua and the UI. Reuse upstream identity where supplied; assign a simple unique label otherwise.
- [ ] Replace unnecessarily broad whole-app leases with resource-aware conflicts: window/tab/document where independently addressable, application-global menus, clipboard and foreground-critical sequences where necessary. Reuse Driver input serialization. Permit independent observations/model work; do not hold a resource through unrelated model waits without need.
- [ ] Protect the user's active edits. Explicit open/show requests may foreground their requested target; background work must use supported targeting or wait visibly for participation. Never silently foreground an unsupported background step.
- [ ] Test two independent tasks while the user types in a third window, same-app different-window work, same-window conflicts, overflow, task selection/routing, later holds, selected Stop and Stop All. Verify no cross-task content or late-result revival.
- [ ] Verify Cua cursor/badge/action feedback on available monitors and Spaces, including cleanup and hidden targets. Record unavailable hardware as unverified. Review UI responsiveness, nonactivating pill behavior and session teardown.

**Gate:** A6/A7 and concurrent A8 pass with observed application progress and preserved user text/focus. Multiple cursors or accepted tool calls alone do not pass.

## P4 — Reuse configurable Groq generation and reasoning

**Entry:** reuse saved provider configuration and existing fixture evidence. P2 context ownership is required for normal-voice integration; configuration checks can proceed independently.

- [ ] Preserve endpoint/model/key settings and verified provider contracts. Jev selects grounded actions; optional provider plans/recovery suggestions are advisory data, never scripts or a second executor. Do not add a provider round trip to every ordinary action.
- [ ] Complete normal-voice page/document summaries and drafts using observed source/destination. Draft does not send; explicit unambiguous sending is tested only in disposable local fixtures.
- [ ] Verify source/recipient changes, cancellation, provider failure/rate limits, late output and bounded quality repair. Ordinary Jev/Cua work continues without a generation key. No silent provider fallback or secret/private-content logging.
- [ ] Verify at least one real configured provider through the packaged voice path. Record untested presets honestly; do not rebuild configuration already working.

**Gate:** A9 passes; isolated provider/DOM fixtures remain supporting evidence, not normal-voice acceptance.

## P5 — Cross-app acceptance, cleanup and installed delivery

**Entry:** P0–P4 behavior is implemented and its gates verified; no critical unresolved correctness issue is hidden by aggregate scores. Prepare acceptance fixtures and measurement tooling earlier where independent, rather than deferring all integration feedback to this phase.

- [ ] Run the matrix below with fresh content, different initial app states, varied phrasings and held-back combinations not used for tuning. Repeat representative workflows; include delayed/revised speech, stale observations, helper death, uncertain mutations, microphone interruption and cancellation races.
- [ ] Measure the complete pipeline and S8 targets. At least 30 varied valid requests for accuracy and at least 30 warm simple-action samples for preliminary median/p95; report cold runs, failures/timeouts and sample counts separately. Preserve failures. Transcript-injection timings do not establish spoken-completion latency.
- [ ] Use applicable Cua verification/recording/benchmarks and independent application readback or fixture oracles. Do not build a new benchmark platform or mistake browser benchmarks for native macOS acceptance.
- [ ] Review the entire migration against the preserved dirty baseline. Remove replaced legacy executor/parser/speech production paths, dead probes and unused dependencies after replacement proof; preserve useful regression intent and stored preferences. Simplify duplicated state and unnecessary layers, then rerun affected checks.
- [ ] Run relevant Swift and selected Cua tests/type checks, release build and packaging. Validate the actual app at `~/Library/Caches/JevVoice/build/Jev Voice.app`, strict/deep signature, normal launch, selected Driver/perception assets and no developer-shell dependency. Prevent silently substituting a stock Driver lacking required patches.
- [ ] Verify preserved credentials/preferences, bundle identity and rollback; document usage, correction/stop behavior, tested background limits, measurements and unmet requirements. Continue independent work around external blockers but do not claim readiness until required gates pass.

**Gate:** all S1–S9 requirements have evidence, every required matrix family passes, critical invariants have zero observed violations, and the installed package—not merely a staging build—has been exercised.

## Acceptance matrix — observable outcomes

Use installed apps confirmed at execution time and disposable content. App names are acceptance targets, not routing whitelists. Preserve each family's intent; unavailable required behavior stays open rather than being replaced with an easier launch test.

| ID / owner | Workflow and required result |
| --- | --- |
| A1 / P1–P2 | Fn hold: open TextEdit, create a new document, continue listening. Both actions occur before release; pauses do not end capture, trailing words survive and release does not repeat effects. |
| A2 / P0,P2 | Browser search → repeated scrolling → open result → back. Verify query, continuing tab identity and navigation. One compound search makes one intended tab; separately requested tabs remain distinct. Incomplete/revised queries do not execute early. |
| A3 / P2 | Notes → genuinely new note → supplied content → follow-up edit. Varied polite wording and initial state; verify the new note and correct destination/content. |
| A4 / P2 | TextEdit dictation appears while held, revisions change only the owned insertion, finalization inserts once. Surrounding text, user edit/selection/focus changes and literal stop/app names are covered. Unsupported fields visibly use release fallback. |
| A5 / P2 | Cancel before dispatch, correct during/after eligible launch, replace a command, try correction with an already-running app or user work. No discarded content or unsafe quit; pending corrections invalidate old decisions. |
| A6 / P3 | Two tasks progress with separate contexts; later hold adds/follows up a task. Same-app separate windows, queue overflow, routing, Cua visuals, selected Stop and Stop All work. |
| A7 / P3 | User types in a third disposable document while supported background work progresses. Focus/text stay intact. Same-window conflict waits; unsupported foreground steps request participation. Test available displays/Spaces. |
| A8 / P0–P3 | Speech revisions, cancellation, delayed callbacks, network/helper loss and post-dispatch timeout/restart do not replay mutations. Manual mode has no early effects; duplicate approval executes once. Disposable deletion/purchase fixtures require the exact-operation pill confirmation; ordinary valid actions have no generic Run gate. Sleep/mic recovery never resumes capture. |
| A9 / P4 | Normal voice summary/draft with real provider and correct source/destination. Draft remains unsent; explicit send, ambiguity, cancellation and provider failure have correct disposable-fixture outcomes. |
| A10 / P5 | Installed package preserves UI/Fn/preferences/credentials, resolves pinned dependencies, has no legacy production fallback and has usable rollback. |
| A11 / P2 | Media app search → select intended result → play/pause. Verify actual playback state changes, not just discoverable controls. Repeated intentional actions remain possible. |
| A12 / P0,P2 | Local OCR-only and icon controls lead to correct actions with verified capture/coordinate provenance; semantic AX/DOM remains available. Moved/resized/stale capture cases cannot misdirect input. |
| A13 / P0,P5 | Selected Driver capability inventory has an explicit integration route and evidence for every applicable capability; platform limitations are identified. Schema/result compatibility tests and representative live action-family checks pass; no silent tool whitelist. |

Traceability: S1 → A1–A4/A11–A13; S2 → A1/A7/A8/A10; S3 → A1/A2/A8; S4 → A4/A5/A8; S5 → A2/A6–A8/A11–A13; S6 → A9; S7/S9 → A10; S8 → measurements across the matrix. This mapping supplements, not replaces, the full specification.

Every family must pass; a 90% aggregate cannot excuse lost user text, duplicate effects, unintended sends, focus takeover or broken cancellation. Physical input and OS-grant evidence remains distinct. No real outgoing messages, purchases or personal-content deletion are authorized as tests.

## Evidence ledger and decisions

See [EVIDENCE.md](EVIDENCE.md) for recorded builds, outcomes, limitations and dependency inventory. New phase evidence belongs there; this plan owns current progress and gates.

## Rollback contract

P0 must record a new verified snapshot of the current source including untracked work and installed bundle before app changes. To roll back, quit the app/helper normally, move the new bundle aside and restore the preserved bundle to its original path. Extract source into a separate directory and compare before restoration; never hard-reset over subsequent user work. Preserve preferences/Keychain entries. macOS may require grants for a restored ad-hoc binary. Historical archives in HISTORY.md are reference material, not a substitute for P0's current snapshot.

## Historical reference

See [HISTORY.md](HISTORY.md) for superseded plans and earlier rollback records. Historical headings do not define the current backlog.
