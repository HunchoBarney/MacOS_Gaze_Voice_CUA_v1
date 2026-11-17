# Jev Voice: program review and finish recommendation

Research date: 15 November 2026. This reviews the whole PROGRAM, P0–P13, P4's accumulated work, retained run evidence, current implementation, and current primary competitor documentation. It is a research deliverable, not a fresh-context acceptance verdict or an approved implementation amendment.

Follow-up: the user subsequently authorized documentation updates.
The current delivery sequence is `.agent/SHIP-PLAN.md`, the stricter
unproven interaction goals are in `.agent/PROGRAM.md`, and open-source
selection is in `.agent/REUSE.md`. P5–P13 now have draft plans and
default-fail criteria. Statements below about missing planning artifacts
describe the audit baseline; historical measurements and acceptance
counts have not been rewritten as current implementation claims.

Subsequent user direction keeps Jev primary and permits Terra API recovery.
The replacement-model shortlist below is historical advice, superseded by
`jev-first-competitive-audit-20261115.md` and `.agent/COMPETITIVE.md`.
The underlying retained measurements remain unchanged.

**Recommendation: keep the working product foundation, make the decision model replaceable, and finish the missing fast execution paths. Stop treating P4's Jev visual loop as the place to implement the entire product.**

The 22–24 second Safari result exposes a real speed problem, but changing Jev alone cannot account for most of that recorded time. The broader audit also finds unfinished production capabilities that the original plan deliberately assigned to later phases. We should complete those paths in a coordinated delivery sequence, then qualify one frozen installed app through Fn, the pill, gaze, and real applications.

There is useful work to preserve: one-turn voice ownership, direct native text insertion, captured-target authority, the shared TaskLoop, session reuse repair, native and visual observations, scoped browser actions, and honest refusal/verification machinery. A rewrite would throw away substantial working infrastructure.

The immediate priorities are:

1. Consolidate a reproducible candidate and resolve the verification-contract issues identified below.
2. Attribute the unmeasured command time and remove repeated observations and model round trips.
3. Implement the missing P5/P7 planner and browser paths; compare a small model shortlist on the same executor.
4. Finish the script, replay, eye-tracking, onboarding and packaging work required by the whole program.
5. Run one bounded release qualification against the final artifact, reusing valid earlier evidence.

## What is actually complete

The active application work is in `jarvis-v1-agent`, on `ship/v1-p3`, with substantial uncommitted implementation. The checked worktrees share HEAD `4b263b35175cda5f90589758f1cbaef31fd75e51`; that commit alone does not describe the candidate. P3 evidence also lives in `jarvis-v1-p3-semantic-closeout`; the recent signed visual artifacts live in `jarvis-v1-vision-driver`.

Recorded acceptance is **P0 13/13, P1 11/11, P2a–P2d 8/8 each, P3 0/8, P4 4/6**. These are acceptance-record counts, not percentages of product completion or a fresh verification of every current source byte. P5–P13 have PROGRAM entries but no phase ExecPlans or acceptance files in the checked worktrees. Existing implementation must still be considered individually.

| Phase | Purpose and retained evidence | Current readiness and remaining obligation |
|---|---|---|
| P0 | Execution harness, contracts, evidence schema, verification lane and worktree rules. Accepted 13/13. | Foundation exists. Keep it, but use reviews and signing at cohesive milestones rather than after every prompt adjustment. |
| P1 | Real-app bench, independent end-state checks, baseline, Wilson reporting. Accepted 11/11. | The harness is accepted. The original product baseline was poor. Its handoff still records the separate test user as uncreated and distinguishes MCP timing from voice timing. Reuse the harness; do not mistake its acceptance for product acceptance. |
| P2a | Core ML tracker spike on M1/8GB. Accepted 8/8; promoted `onnxruntime-node`/Core ML with a CPU detector fallback. | A measured inference decision, not a shipped camera-to-gaze pipeline. P8 must integrate it and prove real frames, calibration, wake recovery and resources. |
| P2b | Chrome DevTools MCP versus Cua browser-driver spike. Accepted 8/8; DevTools primary, Cua fallback. | The driver choice has evidence. The planned persistent production browser lane still needs P7. Startup attachment and first-run Chrome consent must stay off the warm action path. |
| P2c | Codex computer-use feasibility. Accepted 8/8; 3/4 console-session canaries, p50 27.6s. | Useful background/complex fallback. Locked or switched-user operation remains unproven. This cannot become the path for subsecond commands. |
| P2d | Speech bakeoff. Accepted 8/8 as a measured spike with an accuracy-blocked product conclusion. | No replacement ASR was promoted. Apple fast-results was faster to finalize but had worse measured literal WER, including GitHub→GateHub. Physical voice latency remains a separate obligation. |
| P3 | One final transcript and dispatch per voice turn; local partials; remote gating; exact literals; native typing and focus repairs. | Substantial implementation and source/replay evidence exist. Full current signed-app, physical Fn/pill, remote and final phase evidence remain incomplete; acceptance stays 0/8. Preserve the user's decision to defer repetitive qualification to the release check. |
| P4 | Shared TaskLoop/JevDecider, session-label repair, dead perception removal, reliable fast local-safe actions. | Recorded 4/6. P4-5's ≥95% strict success/p50 ≤4s and P4-6's complete fresh review/handoff remain open. D121 proves one synthetic Safari task at 22–24s. |
| P5 | Responses client, general/visual decider, bounded action batches, effort escalation and safety routing. | No integrated `OpenAIResponsesClient`/`SolDecider` implementation found. Existing agent delegation is separate. This missing recovery path is a major reason P4 keeps accumulating general-reasoning work. |
| P6 | Fast typed script intents for the hero jobs, contacts/dates, read-back and inbox brief. | FastLane primitives exist, but the planned script registry/executor does not. The voice catalog explicitly marks `run_script` and `inbox_brief` unavailable. |
| P7 | DOM-first browser decider, persistent Chrome driver, Safari driver, extraction and settling. | Scoped browser primitives exist in BrowserSupport/BrowserActuation. The planned browser decider and driver set are absent; voice `browser_task` is unavailable. |
| P8 | Production Core ML eye pipeline, durable calibration, camera recovery and visionOS-style targeting. | Tracker, gaze service and recovery scaffolding exist. Production inference still imports the web runtime; the Core ML spike has not become the production path. |
| P9 | Compile successful traces into validated reusable skills. | No skill compiler/store/matching/retirement implementation found. RoutineScheduler repeats a task through an agent; that is different from validated fast replay. |
| P10 | First run, permissions, browser setup, calibration, three useful moments, undo/read-back/feedback. | A permission checklist and settings exist. Complete onboarding is unproven, and some suggested first-run commands point to unavailable capabilities. |
| P11 | Eye polish, sampling/resource budgets, resolved-target integration and opt-in dwell. | Existing gaze components are reusable. Full integration is unqualified, and the current dwell default conflicts with PROGRAM. |
| P12 | Portable signed bundle, complete runtimes, keys/spend controls, diagnostics and tester guide. | Build/sign/stage machinery exists. A development install is not a clean-Mac release: tracker staging can be skipped, candidate driver provenance must be reconciled, and a final sealed runtime needs proof. |
| P13 | Final release bars and matched competitor comparisons. | Not completed. No current matched head-to-head establishes “fastest.” This is the final integrated product gate. |

Evidence: `.agent/PROGRAM.md:110–171`, `.agent/acceptance/*.json`, phase Outcomes/Handoff sections, and the implementation references below.

The plan therefore contains six accepted foundation/spike phases, two open production phases, and nine later phases without execution plans in these trees. Counting green criteria would produce a misleading completion percentage because those later phases have not yet contributed their acceptance criteria.

## P4 as a whole

P4 originally has four concrete jobs: fix repeated-session wedges, put DriveLoop on one TaskLoop, remove the dead perception path, and qualify the Jev slice. The recorded source reviews support the first three. Later approved work added progress-driven budgets, native value/effect evidence, generic screenshot reasoning and capture-bound driver inputs.

Those additions address real product needs. The difficulty is that P4 now carries part of P5's visual reasoning, P7's browser behavior, driver/SDK integration, and an expanding completion-proof system. At the same time, the production code still lacks the planned higher-level recovery path.

`DriveLoop.swift:841–864` constructs a JevDecider. Its escalation mapping at `:2051–2069` produces handed-back, blocked or exhausted results. `VoiceTaskCoordinator.swift:1696–1706` turns a low-confidence handback into a blocked result and suggests the numbered overlay. It does not invoke an integrated general decider. We have repeatedly been improving Jev's ability to carry tasks that the original architecture expected another lane to handle.

The successful repairs should remain:

- Session identity and transport handling, shared loop ownership, cancellation and stale-turn checks.
- Native target/value evidence and explicit captured-window/literal authority.
- Correctly labeling AX enumeration as potentially off-screen; a tree entry is not proof that pixels are visible.
- Code-derived geometry when the native evidence actually proves the actuation point.
- Bounded re-observation on uncertainty and independent effect verification.
- D119's retained continuation evidence and the reduction from repeated final verification cycles to one in D121.

The acceptance evidence remains narrower than the implementation:

| Evidence | What it establishes | What it does not establish |
|---|---|---|
| Historical P4 source reviews and passing affected checks | Implemented loop/refusal contracts and specific regressions | Latest whole-tree release correctness or physical voice success |
| Corrected historical bench: 16/30 strict successes | End-state matches had overstated completion; blocked rows must remain failures | ≥95% P4 reliability |
| Native candidate: 6/9 strict successes; successful median 8.419s | Some real native tasks work with independent verification | P4's ≤4s bar; failed rows cannot disappear from the reliability result |
| D16 signed visual pilot: 0/1, blocked in 2.428s | Presence passed; location and authorization failed the existing gates | A speed improvement or successful action |
| D121 Safari scroll: 3/3 strict, no false Done in those rows | One synthetic Safari scroll task reached its independently observed endpoint | Broad app reliability, physical Fn, release readiness or competitive speed |

There is also review debt. Recent visual addenda identify themselves as self-review with a fresh-review quota caveat. The earlier source PASS is not a fresh-context PASS over all D119–D121 behavior.

One material issue needs resolution before promotion: `VisualGoalProof.swift:349–365` replaces `hidden_required` with zero, and replaces non-exact `exact_required` with zero, when the model's `kind_supported` reaches .95. That is a derived model assertion, not an independent native proof of those requirements. It changes the effective verifier even though the numeric .95 threshold remains unchanged. The D11 contract explicitly preserves independent gates and prohibits synthesized scores.

D120 similarly uses the scroll operation's probability as authorization evidence. That can only be equivalent if the operation judgment establishes the same caller, direction, target region and scope as the original authorization question. It needs counterexample review, not an assumption that an unchanged threshold makes the contracts identical.

The right repair is to derive requirements and permissions from authoritative task/target facts where possible, retain separate judgments where needed, and test contradictory evidence. Do not restore redundant requests merely for ceremony; do not erase an independent requirement because another model answer sounds sufficient.

These are release-review findings. This report does not claim that the three recorded Safari completions performed an unsafe action.

## Where the 22–24 seconds went

The following was recomputed directly from the retained D121 JSON, summing every logged `Visual infer <kind>_ms` span:

| D121 row | Command wall time | Logged visual inference | Visual calls | Time outside those logged spans |
|---|---:|---:|---:|---:|
| after-0 | 24.167s | 8.458s | 16 | 15.709s |
| after-1 | 22.412s | 8.141s | 16 | 14.271s |
| after-2 | 22.582s | 6.982s | 15 | 15.600s |

Median command wall time: **22.582s**. All three rows report `done`, `strict_success=true`, `false_done=false`, with scrollbar progression from 0 to 1.

The first two rows each contain six primary calls, five grounding calls, four redraws and one final verify. The third has six primary, four grounding, three redraws, one goal-evidence redraw and one verify. Primary request samples carry roughly 76–78KB of questions and 9–10 images; some asset sets reach approximately 1.24MB.

Logged visual inference is only **31–36% of wall time**. The remaining **14.3–15.7 seconds is unattributed by these spans**. It may include native observation, screenshot preparation, other unlogged model calls, transport, scheduling and actuation. It is not justified to call all of it “driver time” or to claim that it will disappear with a model replacement.

As a subtraction exercise, even removing every logged visual-inference millisecond would leave that remainder. This is not a predictive benchmark: a different architecture could also change the surrounding work. It explains why a model-only substitution is an incomplete plan.

Important measurement boundaries:

- The harness starts the actor before timing `native.drive` and stops the timer before collecting the independent oracle and logs. This is command time, not Fn-release-to-effect, app cold start or screenshot-artifact collection.
- The result metadata does not prove physical microphone/Fn or GUI autospawn.
- Harness metadata listing 20 window-state calls is not established product per-task call attribution.
- Three repetitions establish the observed median, not a meaningful p95 or a 95% general reliability claim.

The next trace needs separate spans for app/window resolution, Cua state, native AX, capture, encoding, each model request, input dispatch, settle, verification and coordinator completion. Record counts, bytes, cache hits and overlapping spans under one task/turn ID, without private content. Extend the existing LatencyLedger; do not build another timing framework.

Source-supported optimization candidates, with savings still unmeasured:

| Candidate | Evidence and constraint |
|---|---|
| Repeated observation | DriveCaptureSource awaits driver state and then native observation. Establish which facts each supplies, remove duplication, and retain independent native evidence where the driver does not supply an equivalent trustworthy fact. |
| Excessive visual calls | 15–16 calls are directly recorded. Batch truly independent judgments, scope state to the question and avoid resampling unchanged questions until one passes. |
| Large repeated assets/questions | The retained traces record large request payloads. Use one capture per state, scoped crops only where useful, and shared references rather than repeating irrelevant images. |
| General driver work for simple input | Earlier native typing traces already motivated direct AX insertion. Finish and qualify that existing path; do not send known focused-field insertion back through a general visual planner. |
| Missing browser fast path | P2b established a useful DevTools route, but P7 is unfinished. A DOM locator plus native scroll-to-visible can avoid interpreting every screenshot while retaining a fresh visibility check. |
| Resource contention | The M1 floor must run speech, tracker, driver and app together. The Core ML spike does not measure the combined production process budget. |

Two proposed “fixes” would repeat completed work: DriveLoop already sets `settleReobserves=false`, and eligible native dispatch already uses D14's 120ms pacing/`post_action_wait=none`. The default TaskLoop settle delay is not evidence that this Safari path paid that delay every round.

## Other product blockers the P4-only view misses

**The voice catalog advertises capabilities whose executors are absent.** `RealtimeVoiceClient.swift:12–17` explicitly marks `run_script`, `browser_task`, `ask_about_screen`, `web_lookup` and `inbox_brief` unavailable. That is correct fail-closed behavior, but it means “look and command anything” and the four hero jobs cannot yet be judged complete. `OnboardingChecklist.swift:93` even suggests asking what is on screen. P10 must follow actual capability readiness.

**The production eye runtime does not use the promoted spike.** `EyeTracking/package.json` depends on `onnxruntime-web`; `web/src/inference/runtimes.ts:97` imports its WebGPU runtime. TrackerHost's fallback can request WASM with a 10fps cap. P2a's roughly 5–7ms weighted inference result used seeded inputs and excluded camera/preprocessing/calibration. P8 must integrate the measured runtime and prove the whole path; it should not promise 199fps real gaze from that spike number.

**Dwell defaults conflict with the locked interaction model.** `DwellClick.swift:166–172` defaults an absent preference to `.safe`, while PROGRAM requires off by default and a separate selection channel. The coordinator suppresses dwell during capture/asks/picks, rather than disabling it globally. This is a source-confirmed default mismatch, not a newly observed unintended click. Correct the fresh-profile default and review existing preference behavior in P8/P11.

**P3 has an unresolved availability result as well as missing evidence.** The retained November 8 readiness audit records raw replay 35/35 versus the exact signed candidate 34/35, with one safe ASR timeout. Its latest historical typing median was 1,250.363ms versus 1,049.536ms before. Preserve both the improvement work and the regression; neither an unsigned pass nor the user's successful physical use supplies the missing full current-artifact qualification.

**Development installation is not finished onboarding.** `make local` is useful, but the release must run without a source checkout, Homebrew, developer caches or manual app-specific flags. `Makefile` permits `bundle-tracker --if-present` for development. The candidate Cua 0.45.4 work and the installed 0.38 pin are explicitly distinct in the upgrade records. P12 must seal one coherent reviewed runtime rather than assume any current build command reproduces the tested candidate.

## What competitors are doing

These are primary-documentation findings unless explicitly labeled a vendor measurement. No competitor application was freshly benchmarked during this review.

| Product/system | Documented mechanism | Useful lesson and comparison limit |
|---|---|---|
| Apple Voice Control | Native navigation, named/numbered controls, grids, dictation and commands; offline after the initial download. | Routine input does not need a cloud planning loop. Its command interface is different from arbitrary natural-language task completion. Apple's suggested pause between commands is not a latency benchmark. |
| Talon | Voice commands, dictation, scripting and optional eye tracking with supported hardware. | Hands-free speed comes from reliable input primitives. Its command scripts and eye-tracker requirements are not the setup experience requested for Jev Voice. |
| Wispr Flow | Streaming speech and specialized dictation work. Its technical material targets under 700ms from speech end to inserted text; Canto replaces a more complicated recognizer pipeline. | Keep transcription and insertion tight. This is a vendor target/result context for dictation, not a browser-task speed comparison. |
| Aqua Voice | Specialized Avalon voice-input models and context-aware dictation. Vendor material claims speed advantages over other transcription models. | Evaluate end-to-end exact insertion and proper-name accuracy on our hardware. Do not transplant a provider's model-speed ratio into desktop task latency. |
| Superwhisper | Local/cloud speech options, optional language processing and published hardware-specific measurements. | Local speech and optional formatting are separate choices. M4/M4 Max results do not establish performance on M1/8GB. |
| Alter | AX-first computer use, window targeting, scoped screenshots and `perform_sequence` from one observation, with re-observation after layout changes. Also provides app-specific guidance. | Adopt scoped observation and bounded action batching. Keep general operation available without requiring each application to acquire a recipe. No matched local latency result is available here. |
| Raycast | Executable extension tools and direct selected/focused-text workflows. | Use typed actions for known operations. An extension catalog alone does not provide arbitrary desktop grounding. |
| Claude Cowork | Prefers connectors, then browser interaction, then screen control; documentation acknowledges screen operation can be slower. | Choose the cheapest capable interface before pixels. Preserve Jev Voice's authority, confirmation and target checks across every interface. |
| Browser Use | Persistent execution context, AX/DOM helpers, stable browser node IDs and automatic state returned after actions in ultrafast mode. | Reduce model-to-tool round trips and preserve browser sessions. Do not copy arbitrary-code execution or automatic dialog acceptance into our consent policy. Published long-task benchmarks are not comparable to a three-run Safari fixture. |
| Vercel agent-desktop | Model-independent AX driver with snapshot-qualified references, stale-reference rejection, bounded resolution and observation completeness. | Separate targeting evidence from presentation. A smaller displayed tree does not automatically mean less native traversal. This is execution infrastructure, not an end-user voice model. |
| ChatGPT Atlas | Native shell, asynchronous browser startup and purpose-built browser/screenshot/input plumbing. | Integrating the execution runtime matters as much as the model. It is not a drop-in desktop-driver replacement. |

The shared pattern is concrete: **direct tools for routine work, stable sessions, compact state, fewer round trips, and screenshots when the task needs visual reasoning.** There is no public evidence here that any provider makes arbitrary multi-step desktop work take 2ms.

For Jev Voice, “fastest” should become a published comparison on common dictation, native control, browser, gaze and short workflow tasks at equal or better strict success. Compare the complete interaction, count failures, report cold and warm operation separately, and keep a complex-task category. A quick refusal cannot win the speed comparison.

## Model recommendation

**Stop requiring Jev to be the sole general visual decision-maker. Test GPT-6.1 Terra first as a challenger; retain Jev only where its narrow typed judgments earn their cost.**

TypeSafe's current documentation strengthens that recommendation:

- `jev-latest` and `jev-preview` currently resolve to 1.14.0. An alias change alone is not a newer-model experiment.
- Images and Box are explicitly described as not yet meeting TypeSafe's production-readiness standard.
- Box always returns a box, including when the requested thing is absent. Presence, location, identity and permission must remain separate.
- The jaggedness guide warns about indirection, irrelevant large state, numeric precision, adversarial content and using Jev for generation.
- Independent questions share state but cannot see each other's answers. Put truly independent questions in one request; dependent reasoning needs code-controlled stages.

| Candidate | Role to test | Why it belongs in a bounded shortlist |
|---|---|---|
| Current Jev 1.14 | Incumbent; compact observed-candidate selection and narrow semantic judgments | Existing integration and recorded subsecond API calls. The current call topology and experimental visual surface are the concern, not a claim that every Jev call is slow. |
| GPT-6.1 Terra | First challenger for structured action proposals and visual/general tasks | Officially documented visual/computer-use capability and low/no-reasoning options. OpenAI is already an allowed provider, although the production Responses adapter still needs implementation. |
| Claude Haiku 5.5 | Latency-oriented alternative for the same action/grounding contract | Current official computer-use documentation supports evaluation. It adds a provider and requires an explicit policy/key decision before use. |
| Gemini 3.5 Flash | Additional fast multimodal challenger if the first comparison is inconclusive | Current documented model option. Browser-oriented computer-use claims do not establish native-Mac reliability. |
| GPT-6.1 Sol or a stronger reasoning model | Escalation for difficult or novel tasks | Keep expensive deliberation out of ordinary input. The existing locked model policy must be explicitly amended before a production change. |

This is a shortlist, not a measured ranking. The report does not establish API access to every candidate, a price advantage, or an accuracy winner. Do not replace Jev probabilities with a generative model's self-written `0.99` field and pretend the safety contract is unchanged.

Use two separate comparisons so model quality and architecture improvements do not get conflated:

1. **Same executor, different decision model.** Freeze a representative set of states, screenshots, goals, literal payloads, protected controls, ambiguous targets, stale references, hidden outcomes and absent targets. Compare legal proposals, exact target correctness, abstention and decision latency. Screen candidates before desktop actuation.
2. **Same chosen model, improved execution topology.** Compare current versus compact observations/batches with the same task population, verifier, repetitions and cold/warm definitions. Then run the best two candidates through the actual signed application.

Measure strict task success, wrong/duplicate actions, false Done, p50/p95, timeouts, request counts/bytes, actual usage cost and resource load. Keep every attempt. Five repetitions per task is the program floor; use enough pooled per-class observations to discuss tails and Wilson bounds. Three successes do not justify a p95 or broad reliability claim.

Stop after this bounded shortlist unless a named failure explains why another candidate is needed. Local small VLM work already measured roughly 12.5–22s per image query on M1/8GB; repeating that approach is not the immediate critical path.

## Execution architecture to finish

The original separation of input, decision and execution is sound. Finish it around the existing TaskLoop:

```text
Fn/pill + local speech + optional resolved gaze target
    -> one final, turn-owned request
    -> direct native/dictation path when fully grounded
    -> typed script/API or persistent DOM path when capable
    -> compact AX reasoning for ordinary native UI
    -> screenshot/general reasoning for ambiguous or unsupported surfaces
    -> stronger reasoning only when needed
    -> fresh independent consequence evidence -> completion
```

Use the fastest capable path without making every task pass through every model. Jev must not become an obligatory preflight before Terra, and voice transcription must not invoke the general computer-use loop just to insert text.

**Observation:** maintain a foreground identity channel separate from slow CoreGraphics inventory. Obtain one scoped state per needed transition and reuse its capture within that step. A blocked inventory call cannot provide continuity evidence. Cache stable capabilities and sessions, not permission or mutable target truth. Reject incomplete or stale observations rather than silently broadening authority.

**Actions:** let one model proposal contain a bounded typed sequence when its targets and preconditions are already known. The executor checks each step, stops on changed state, asks at consequential actions and never replays an uncertain mutation. This is a transport optimization, not a blanket authorization to execute generated code or auto-accept dialogs.

**Verification:** use exact native/DOM postconditions for properties those interfaces can prove. Use pixels for visual outcomes when necessary. Visibility, semantic identity, geometric location, authorization, target safety and consequences remain distinct. Batch independent checks; do not convert a successful click into proof that a save/send/backend outcome occurred.

**Browser:** complete P7 with one persistent connection to the actual logged-in browser, stable scoped references, DOM extraction and settling. Keep Safari's supported path and the generic visual fallback. Do not restart applications, clone the user's profile or require new per-site flags for routine operation.

**Repeated work:** P9 should compile only successful, verified traces into parameterized actions with fresh locator binding and postconditions. Retire failed recipes. A compiled skill is an acceleration for a task that already works, not a prerequisite for an app to be usable.

**Eyes:** integrate the measured P2a runtime rather than start a native-UI rewrite. Keep gaze as a target hint, with explicit voice/key/click selection; opt-in dwell stays separate. Measure camera-to-highlight latency and targeting accuracy alongside inference FPS.

## Speed budgets

Existing PROGRAM bars remain binding. The additional targets below are proposed engineering goals, not achieved measurements or replacements for acceptance:

| Interaction | Proposed target | Boundary and evidence requirement |
|---|---:|---|
| Input acknowledgment | ≤100ms | Fn/pill event to visible listening/working feedback; never claim an action completed at this point |
| Warm dictation | p50 ≤200ms, p95 ≤500ms | Fn release to final exact inserted text; preserve proper names and captured-field authority |
| Simple grounded command | p50 <500ms, p95 ≤1s | Fn release to independently observed effect; retain P3's ≤300ms median dispatch bar and PROGRAM's ≥99% one-shot success |
| Single ambiguous/visual action | p50 ≤2s, p95 ≤4s | Final request to verified effect; distinct from a multi-page task |
| Short everyday workflow | p50 <5s, proposed p95 ≤10s | Entire task, at ≥95% success; retain P4's stricter ≤4s qualifying-slice median |
| Repeated verified workflow | p50 <3s | PROGRAM replay bar, ≥95% success |
| General browser task | p50 <15s | PROGRAM browser bar, ≥90% success; ordinary one-step browser actions should meet the faster category |
| Novel complex task | p50 <60s | PROGRAM complex bar, ≥80% success; communicate progress and allow cancellation |
| Background CU fallback | p50 ≤30s | Existing TC category; not the default for a simple voice command |
| Gaze and resources | ≥15fps, wake ≤5s; steady RSS ≤2.5GB, idle CPU ≤10% | Whole packaged app on M1/8GB; calibration ≥80% first try and dwell off by default |
| First run | Three useful moments within three minutes | Final portable signed app, permissions and capability readiness included |

A useful provisional warm one-shot allocation is 150ms final speech, 30ms admission/dispatch, 170ms native effect and 100ms independent readback, leaving approximately 50ms headroom. This is a design budget to validate. If a measured stage exceeds it, fix or reroute that stage; do not hide the overrun in a different timer.

Cold start, model preparation and browser attachment need separate reported distributions. Prewarm after permissions are ready and while the user speaks where safe; never actuate partial speech, hide missing readiness or discard the first utterance.

## Bounded delivery sequence

This is the proposed next program amendment, not authority to begin all source changes immediately. It preserves the whole v1 goal and the acceptance bars. The first useful installed milestone can arrive before every phase is accepted, with its remaining release obligations explicit.

| Order | Work and phase ownership | Concrete exit |
|---|---|---|
| 1. Consolidate | P3/P4/P12: bind the current source, driver, resources and evidence into one reproducible subject; index the sibling-worktree artifacts; resolve D120/D121 proof semantics with independent review. | A candidate whose behavior and provenance are reviewable, with no self-promoted acceptance. Existing failures and user data preserved. |
| 2. Make routine input fast | P3/P4: instrument the missing wall time; reuse direct typing/focus/keys/scroll paths; remove the measured repeated work; retain foreground-monitor separation. | Identical before/after evidence for ordinary voice/typed commands, exact effects and no wrong/duplicate action. Sign a cohesive candidate rather than each prompt experiment. |
| 3. Finish general and browser execution | P5/P7 on the stable TaskLoop contract: implement the provider adapter, bounded typed proposals and persistent DOM browser lane; perform the bounded model comparison. | Real native and browser tasks use the intended capable lane; supported voice tools no longer return placeholder capability errors. Pixel fallback remains generic. |
| 4. Complete fast hero and repeat work | P6/P9: typed scripts/APIs for inbox/messages/calendar/reminders/notes, read-back for consequential actions, and validated trace replay. | Each hero job has a working route and independent consequence evidence; repeated jobs meet their own bar. Generic fallback works without app-specific enablement. |
| 5. Complete eyes and setup | P8/P11 plus P10/P12: integrate Core ML, correct dwell defaults, prove calibration/recovery; make first run capability-aware; stage a strict portable bundle early enough to expose packaging defects. | Gaze targets correctly with separate selection, fresh setup works without development dependencies, and the three useful moments work. Eyes can be a separate owned track if parallel work is authorized. |
| 6. Freeze and qualify | P13 plus the remaining P3/P4 gates: one final signed subject, real-app breadth, normal Fn/pill and gaze, resource checks, matched competitors and fresh-context acceptance. | Complete evidence, final handoff and the user's approved install/release decision. |

P5/P7 currently depend on earlier phase acceptance in the DAG. The recommended amendment should allow implementation against the reviewed stable P4 interface while P4's broader qualification remains open. It must not move failing tasks between slices to make a phase green. Freeze task membership before comparison, retain the historical scores and keep every original release obligation.

The real-app set should cover exact text insertion and editing, Calculator, menus, chords, dragging, browser navigation/extraction/scrolling, target changes, cancellation and stale-state refusals. Use the existing isolated fixtures and independent oracles. Preserve the approved Notes restriction: only the labeled synthetic note, existing notes untouched, synthetic note left afterward. Check Spotify's local output route before any playback test.

Complete the normal physical path once on the final artifact, with the required cases and unchanged bars. Do not ask the user to re-record the 35 existing speech clips or repeat known-good P3 setup for every internal change. If the physical population itself is amended, record that decision before collecting new evidence; do not silently relabel earlier diagnostic runs.

The operating rules that stop this becoming another long tuning cycle:

- One measured cause and one coherent change at a time, followed by the same measurement.
- Reuse the verification lane, real-app harness, LatencyLedger and retained fixtures.
- Review contracts before structural changes; review the completed source delta at a stable boundary. Routine fixes within an approved contract do not need a new permission ceremony.
- Do focused checks while developing, then full required checks and signing at candidate milestones.
- Stop revisiting the successful Safari fixture unless a change can affect it. Expand representative coverage instead.
- Do not lengthen deadlines, increase retries or remove independent checks to manufacture a speed/reliability win.
- Preserve one working daily app until its replacement is proven and approved for installation.

This sequence is an implementation order with explicit stop conditions, not a promised calendar date. The remaining P5–P12 work makes “just consolidate and install” an insufficient description of finishing the locked v1 program.

## Evidence and primary sources

Repository references are relative to `jarvis-v1-agent` unless a sibling tree is named:

- Program, gates, contracts: `.agent/PROGRAM.md`, `.agent/PLANS.md`, `.agent/CONTRACTS.md`, `.agent/acceptance/P0.json` through `P4.json`.
- Historical phase scope/results: `.agent/phases/P0-harness.md`, `P1-bench.md`, `P2a-coreml-tracker.md`, `P2b-browser-drivers.md`, `P2c-codex-cu-headless.md`, `P2d-speech-bakeoff.md`, `P3-voice-one-brain.md`, `P4-taskloop-jevdecider.md`.
- P3 current historical closeout: `../jarvis-v1-p3-semantic-closeout/.agent/results/P3/P4-READINESS-AUDIT.md`, `normal-voice-qualification/SPEED-CLOSEOUT.md`, and the raw/signed replay and typing artifacts identified there.
- P4 visual history: `.agent/results/P4/jev-pixel-routing-source-review.md`, particularly addenda 24, 42 and 81–84; `.agent/results/P4/jev-explicit-decision-results.md`; `.agent/results/P4/jev-vision-cua-045-candidate.md`.
- D121 artifact root: `../jarvis-v1-vision-driver/development/JevVoice/staging/vision-pinned-owner-20261110.artifacts/completion-research-20261110/`.
- D121 raw rows: `native-d121-scroll-r1/summary.json`, SHA256 `f223170f70bc32ac17f51c679cf7ece1816b18fc8f465ef0cae16e7842fa5642`.
- D121 stage receipt: `native-d121-candidate-stage/stage-receipt.json`, SHA256 `929e92fdf51d403ecd7f34bd78e75df3f40741aa6c2d673751d1906ce70366ac`.
- D121 after executable SHA256: `03d704eef79d9df8f731b7fbcc81b054bfadd555d3b593a910de38617cc9f8f2`. Current JevVisualDecision and VisualGoalProof match their D121 receipt hashes; this is not a whole-tree provenance assertion.
- Critical implementation: `Sources/JevVoice/Drive/{DriveLoop,TaskLoop,VisualGoalProof,JevVisualDecision,FastLaneExecutor,BrowserSupport,BrowserActuation,VoiceTaskCoordinator}.swift`, `Voice/{RealtimeVoiceClient,DictationDelivery}.swift`, `Support/LatencyLedger.swift`, `Gaze/{DwellClick,GazeService,TrackerHost}.swift`, `UI/OnboardingChecklist.swift`, `EyeTracking/package.json`, `EyeTracking/web/src/inference/runtimes.ts`, `Makefile`.

Primary web documentation read for this review:

- TypeSafe: [models](https://docs.typesafe.ai/models.md), [System One](https://docs.typesafe.ai/concepts/system-one.md), [confidence](https://docs.typesafe.ai/confidence.md), [Box](https://docs.typesafe.ai/primitives/box.md), [model jaggedness](https://docs.typesafe.ai/model-jaggedness.md).
- OpenAI: [GPT-6.1 Terra](https://developers.openai.com/api/docs/models/gpt-6.1-terra), [GPT-6.1 Sol](https://developers.openai.com/api/docs/models/gpt-6.1-sol), [building Atlas](https://openai.com/index/building-chatgpt-atlas/).
- Anthropic: [Haiku 5.5 documentation](https://platform.claude.com/docs/en/models/haiku-5-5/), [Cowork computer use](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork).
- Google: [Gemini models](https://ai.google.dev/gemini-api/docs/models), [computer use](https://ai.google.dev/gemini-api/docs/computer-use).
- Browser Use: [current agent](https://docs.browser-use.com/open-source/agent.md), [ultrafast mode](https://docs.browser-use.com/open-source/ultrafast.md), [benchmarks](https://docs.browser-use.com/benchmarks/agents).
- Vercel: [agent-desktop](https://github.com/vercel-labs/agent-desktop), [reference/observation concepts](https://github.com/vercel-labs/agent-desktop/blob/HEAD/CONCEPTS.md).
- Alter: [computer use](https://docs.alterhq.com/apps-tools/computer-use), [dictation](https://docs.alterhq.com/workflows/dictation).
- Raycast: [AI extensions](https://manual.raycast.com/ai/ai-extensions), [AI commands](https://manual.raycast.com/ai/ai-commands).
- Wispr: [Canto results](https://wisprflow.ai/canto-1-results), [technical challenges](https://wisprflow.ai/post/technical-challenges).
- Aqua: [Avalon](https://aquavoice.com/guide/how-to-use-avalon), [voice model/product material](https://aquavoice.com/blog/aqua-voice-for-ios).
- Superwhisper: [voice models](https://superwhisper.com/docs/models/voice), [hardware-specific benchmarks](https://superwhisper.com/docs/models/benchmarks).
- Apple: [Voice Control commands](https://support.apple.com/guide/mac-help/use-voice-control-commands-mh40719/mac), [offline setup](https://support.apple.com/guide/mac-help/turn-voice-control-on-or-off-mchl63d14732/mac).
- Talon: [official setup and capabilities](https://talonvoice.com/docs/reference/official.html).

No production source, model policy, pricing, acceptance flags or installed application was changed for this report. No new paid-model test, desktop action, microphone trial, build, commit or push was performed. Verification consisted of source/record inspection, current documentation research, receipt comparison and recomputation of retained measurements. The latest visual verifier still needs independent review, whole-product breadth and physical qualification remain open, and no competitive speed win is claimed.
