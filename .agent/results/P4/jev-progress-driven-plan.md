# Progress-driven Jev and P4 re-audit

## User direction, 2026-11-08

User asks why 45/48 is not 48/48, what failed, how to improve, whether
P4 can close, and to double-check and fix actual bugs.
Mid-task correction: "there should be no limit to jev ... using it to
the max capabilities". This explicitly revises the former four-round
Jev ceiling. Do not merely change four to eight or another arbitrary cap.

Interpretation: no artificial step/ability ceiling while a task is making
verified progress. Preserve permission/deny/window authority, cancellation,
fresh observations, honest completion and non-progress protection.
Do not equate unlimited model capability with blindly repeating requests
against unchanged evidence or unconstrained computer mutation.

## Current state

Active repo is /Users/karanvirkang/Documents/code/jarvis-v1-agent, not
the unrelated IDE staging path or skill tool's P4-m1 source path.
Large dirty worktree contains existing edits/deletions from earlier phases.
No new production changes made for THIS follow-up yet; do not revert them.

Skills loaded: typesafe-ai, immune-system, enliven. Their native Swift
adaptation must drive real front doors where safe; do not build unrelated
immune dashboards or claim that fake UI equals desktop qualification.
Full skill text was read but tool output truncated: skill text remains
at the installed paths /Users/karanvirkang/.agents/skills/<name>/SKILL.md.

Current installed candidate2 and all prior artifacts are immutable.
Old 30-call grant untouched. New unlimited synthetic grant journal spent
243/512 LOCAL accounting batch. No new calls in this follow-up yet.
No new install approval yet; previous replacement approval was used.

P4 acceptance.json still has P4-1..4 true, P4-5/6 false.
P4-5 evidence incorrectly retains old "25/30 verified pass83%, model
limit" wording, despite later correction to strict16/30 and integration
defects. Reconcile it against raw artifacts WITHOUT flipping passes true.
P4 closure requires actual >=95% strict independently verified desktop
or judge-accepted DriveLoop slice, p50<=4s, zero false done, and phase G4.
The scoped repair review does NOT substitute for phase G4.

## Known three observations

Old final R2:45/48 (43/46 inference +2 zero-call postconditions).
Three false abstentions, no wrong primitive actions or unsupported done:
- Search-first trial0: type candidate .65, applicability .72,
  text-entry .67; focused type .78, action support .71<.9.
- Generic installer Continue trials0/1: candidate .71/.84,
  applicability .55/.63; focused .89/.93, support .64/.65<.9.
Relative Choice correctly naming a control is not proof that it fits.

Context probe already exists, 12 requests included in243. Real heading
helps installer support ~.97; scoped true/false criteria helps operation
match but not every case. Probe changes evidence/questions, NOT another
benchmark. The previous held-out slice is NOW SEEN. Do not tune against
it and relabel the score as fresh held-out success.

Investigate before choosing fixes:
- Does state drop explicitly empty field values (different from unknown
  nil), confusing whether a text-entry step remains?
- Are read-only headings/relationships omitted when they expose actions?
- Are generic support questions accidentally judging whole-goal success
  or policy permission instead of next-operation fit?
- Swift Question.noul currently supports only instructions, while current
  HTTP API supports criteria true/false. A source-additive supported
  criteria path may improve boundary clarity; test encoder first and
  audit all consumers.

## Limits found (code_search output saved)

Search tool full output:
/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/devin-overflows-501/1a69b092/content.txt

- DriveLoop.Config.maxRounds=4, elementCap32, browserRefCap8.
- DriveLoop passes maxRounds into TaskLoop.Config at756-757.
- TaskLoop.Config.maxRounds=4, run uses fixed for-range.
- RoundBudget.roundsRemaining is Int; consumers assume finite budget.
- JevDecider also has prior one-question-per-task guard.
- Other caller/schema max_steps/max_rounds, history truncation and
  candidate omission must be audited before declaring limits gone.

## Proposed contract revision for review

Prefer explicit optional finite budgets over Int.max sentinels.
Production DriveLoop Jev default may use nil step ceiling; explicit finite
caller budgets still supported. Shared TaskLoop should retain a finite
default for other callers if useful, but accept nil for progress-driven
Jev. RoundBudget remaining should represent unknown/unbounded honestly.
Audit every reader, test finite termination, unbounded >4-step completion,
stalls, cancellation, consent, stale references and goal evidence.

Do NOT automatically remove safety-related invalid/stale/refused guards.
No stopping solely because a useful task passed round4; no continuing
forever when nothing changes. Progress must reflect observed outcomes,
not just model confidence or dispatch success.

Required contract details from senior review:
- Nil remaining is not the last round. Finite zero/one remaining still
  use the final-round evidence correction behavior.
- Iteration and remaining-budget arithmetic handle nil. Result reports
  actual attempted rounds, including early wall-budget expiry, not the
  configured maximum. A round-exhaustion result requires a finite cap.
- Bind a parked text request to its question AND newly appended history;
  never consume a different/prior question's answer. Ask another field
  after an answered question; only unresolved questions block.
- The loop, not Jev, prevents repeated empty decisions even when an
  unrelated clock changes the screen. An idle-round guard resets on a
  verified effect, a real answer, or an observed advancing progress
  indicator. It does not cap useful actions or legitimate visible
  progress. Preserve existing cancellation/deny/stale/invalid guards.
- Preserve complete available action history instead of last six.
  Preserve empty (known blank) field values, distinguish unknown nil,
  and never disclose secure values. No arbitrary first12/24 context loss.
- Remove default candidate32/browser8 cutoffs while retaining explicit
  caller caps. Model/API physical context limits are not claimed absent;
  use progressive evidence/candidate acquisition where necessary.

Review returned conditional PASS, which is treated as NOT ACCEPTED
until these requirements are included and explicitly re-reviewed.

Review structural plan before editing frozen shapes. The same previously
approved read-only reviewer6c3591cc may be resumed for this ongoing repair;
do not dispatch more implementation workers. No writers in EyeTracking.
Any change to frozen interfaces needs CONTRACTS Decision Log and consumer
review. PROGRAM/P4 four-round descriptions and tests must be updated
truthfully under this explicit user revision, not left contradictory.

## Work order

1. Read current memory/PROGRAM/PLANS, raw cases and all budget consumers.
2. Reproduce concrete bugs BEFORE implementation; fresh immutable
   baseline and fresh unseen cases before prompt changes.
3. Review finite-or-progress-driven contract, implement minimal fixes.
4. Exercise real product front doors against ONLY owned synthetic
   fixtures, where possible faking only paid/model boundary. Do not
   reset user's browsers/tabs or send private desktop data to Jev.
5. Targeted then serialized full verification; record real remaining
   P4 proof gaps. Do not waive95% bar or flip acceptance yourself.
6. Independent repair/phase reviews as authorized; install only with
   fresh explicit app replacement approval; durable handoff.

All builds/tests via scripts/verification-lane.sh. Live desktop work
uses scripts/with-desktop-lock.py. No commit/push, no phase advancement
claim until its evidence exists.

## Continuation checkpoint 16:47

User has NOW explicitly approved Install And Test: after checks, replace
and restart ~/jarvis-local/Jev Voice.app through approved-install lane,
then real desktop checks in a temporary synthetic-only app. No browser
resets, personal documents or repeated Fn/mic qualification. Do not ask
for that approval again for this candidate. No install yet in this task.

Same senior reviewer6c3591cc gave terminal PASS to revised contract
BEFORE implementation. No new workers. Plan initial conditional verdict
was not treated as acceptance. No model API calls yet; grant still243.

Implemented first milestone, NOT complete task:
- DriveLoop maxRounds/elementCap/browserRefCap optional, defaults nil.
- Shared TaskLoop maxRounds optional default4; optional remaining budget.
- Actual round counts; new wallBudgetExhausted reason mapped to honest
  blocked output in DriveLoop, distinct from finite round exhaustion.
- Loop-owned maxNoProgressRounds8, resets on verified effect, nonempty
  answer, or new/increasing AXProgressIndicator high-water value.
  Clock/screen churn alone does not reset. Useful steps uncapped.
- Cancellation checked after decision and immediately before actuation
  (including after consent wait).
- JevDecider parked tuple request/historyCount/question; consumes only
  its matching newly appended answer. Previous answered question doesn't
  block a second field; unresolved prior ask still blocks.
- Full history, all nonsecure screen values including empty strings,
  all nonsecure observed labels/values. Removed12/24 row and120/240
  character truncations. Secure sanitization remains.
- DriveCandidates accepts optional caps; nil offers all snapshot
  controls/browser refs, explicit finite caller caps still work.
- JevIntegrationTests renamed budget test and now checks nil defaults.

Tests written BEFORE code:
6 new regression cases on old source FAIL with9 assertions:
`.agent/results/P4/jev-progress-before.log`.
After:9 tests PASS including >4 verified steps, full controls/history,
blank fields, distinct text holes, no answer cross-leak, wall0 reports0,
changing-screen empty-loop stop, >12 progressing wait rounds and cancel
after consent no dispatch. Log jev-progress-after.log.
Broader existing p4-jev lane:229 tests PASS, jev-progress-focused.log.
Existing secure-value redaction hypothesis was FALSE: added test
testTextQuestionDoesNotExposeSecureCurrentValue passes BEFORE any
privacy fix; jev-progress-privacy-before.log. No privacy bug claim.
Secure values were already masked before candidate generation.

Source changed: TaskLoop, DriveLoop, DriveCandidates, JevDecider.
Tests changed: DriveLoopTests, JevDeciderTests, TaskLoopTests,
JevIntegrationTests. Runner new p4-jev-progress-regressions/privacy.
No JevChooser/JevModels prompt/API changes yet. No full lane yet.
CONTRACTS/PROGRAM/P4 metadata need update for optional budgets/new enum
and changed ownership before final review. Old four-round language is
still present. Do not claim new source installed or reviewed yet.

Fresh real front-door proof fixture source created:
`.agent/results/P4/JevWorkflowFixture.swift`, AppKit native visible UI
for setup7+ steps, two-page form, and calculator. No build/run yet.
It atomically writes independent state JSON, not model claims.
Before running: require explicit --state path and refuse existing file
instead of fallback /tmp path; optional choices45 grid useful coverage.
Build and package through a new verification-lane scope, not raw build.
No fixture runner exists yet.

CRITICAL NEW FRONT-DOOR FINDING TO TRACE NEXT:
`CuaDriveServer.toolList` currently drive_until exposes ONLY goal/app.
`bench/lib/mcp_stdio.py:138` also forwards ONLY goal/app.
Need read CuaDriveServer around195-212 to see task constructor.
Likely discards caller values and declared success evidence, so a
correct strict TaskLoop cannot complete multistep agent tasks or obtain
supplied literals. Must not weaken completion proof to hide this.
Investigate additive optional values/success_contains in THIS two-tool
MCP facade and its task builder, with tests+senior review before
interface changes. Nine public realtime tools must stay unchanged.
Native proof needs caller-owned literals and meaningful postconditions,
plus app identity. PID/window optional pin only if really necessary;
do not broaden authority silently. This is likely a harness integration
bug, not model incapability.

Native bench implementation hints:
- Existing bench.lib.mcp_stdio.MCPStdio, require_api_key(), tool_text().
  Reuse, never print/persist Keychain key. Parent env -> child only.
- Native fixture needs packaged .app for target app/bundle lookup.
- Can call tools/call manually with declared optional args once wired.
- `JEV_CUA_SOCKET` explicit test override already supported. Pinned
  embedded `cua-driver serve --socket PATH --embedded --no-overlay`
  exists; serve help read. Do not use dangerous bypass or change grants.
  App-owned daemon may be lazy/not running, prior bench used standalone.
  If using externally managed daemon, disclose that proof scope rather
  than pretend it proves GUI daemon startup. Check current policy bool,
  never silently enable persistent user grant.
- All desktop work behind explicit JARVIS flags + with-desktop-lock.py.
- Baseline OLD installed signed candidate2 remains available for paired
  native before sample; current source changed but app NOT replaced.
  Old API may not accept postconditions/literals: preserve that failure.

Historical benchmark truth verified directly from raw JSON now:
bench/results/results-20261108.jsonl has160 rows. Correct bench5 batch
is ZERO-BASED rows123...152 (starts calc.compute run1 at
20:02:23.704Z; six tasks each5 trials; end20:04:22.754Z).
Exactly25 external end-state matches but ONLY16 strict successes.
Rows153+ include extra manual retries and must not pollute batch.
Initial19:35 time slice was a DIFFERENT30-row batch (10 strict), not5.
Update acceptance P4-5 evidence, leaving passes false. Cite raw range
and actual strict rule: verified && !is_error && status done/already.

Next model work remains:
Read current JevChooser around115-210: hard prefix3 refinement and
two-stage flow. Need remove omitted candidate capability limit; can
batch all independent candidate support judgments in one meaningful
followup (no blind repeats). Natural staged requests aren't a cost cap.
Keep support>=.9 and original probability floors; no forcing green.
Current Swift Question.noul instructions String only, API current docs
support criteria true/false. Add optional supported criteria shape only
after encoder tests and consumer audit; P3 callers unchanged.
New fresh positive/negative cases frozen before prompt treatment. Old
held-out now seen; old misses remain recorded, not relabeled.
No API threshold reductions or model swaps.

Live docs refreshed via urllib: llms.txt, primitives/noul.md, api.md,
concepts/state.md. Full fetched output at:
/var/folders/cb/x7hj29gx2jv7yvtw03220xsm0000gn/T/devin-overflows-501/shell-ace4fb-569c4ae33dee5a9b/content.txt
TypeSafe source truth instructions vs criteria and independent questions
confirmed; no documented API arbitrary option cap established yet.

## Continuation checkpoint 17:24

Remaining combined plan got terminal PASS from reviewer6c3591cc:
strict optional MCP values/success_contains/deny only, no pid/window
authority, public9 realtime tools unchanged; optional Noul criteria
wire-compatible with old calls; refiner all eligible actions, existing
support/probability floors retained; synthetic native fixture and
explicit externally-managed-daemon scope acceptable. Do not re-review
every step, execute this plan.

MCP gap CONFIRMED and FIXED after tests:
- Extracted original2-field decodeTask preserving behavior, then tests
  reproduced13 failed assertions (discarded literals/goal criteria/deny
  and accepting malformed fields).
- CuaDriveServer now shares taskInputSchema for drive_until AND
  suggest_action; values stringmap, success_contains and deny arrays.
  No extra keys accepted, no new pins, rejects mixed/wrong types and
  blank field labels/criteria/deny. Literal values including empty
  strings and surrounding spaces preserved exactly.
- callTool invokes same decoder. Goal/app legacy calls still valid;
  no completion evidence invented for them.
- TaskLoop.available-control-label-as-goal-proof bug reproduced1
  assertion. Fixed shared successEvidence: with structured elements,
  only read-only labels and actual values count, not actionable labels;
  uses rendered markdown only if there are no structured elements.
  Blank criteria were ALREADY filtered, negative control passed.
  Four front-door/proof tests now PASS. Logs jev-frontdoor-before.log
  (14 assertions failing total), jev-frontdoor-after.log (4 tests pass).
- Source decoder strictly matches published optional shape; review
  unknown-key rejection and empty-app handling as stricter invalid-input
  behavior, no valid legacy caller break.

Model refinement before-test now proves prefix3 discards valid fifth
candidate: JevAdaptiveTests.testRefinementCanReachCandidateOutsideFirstThree
FAIL nil vs e5. Recorded jev-refinement-before.log.
New testCallerLiteralComparisonKeepsUnknownDistinctFromMismatch expects
_candidate_details.t1.literal_matches_current_value true/false for
known value, absent for unknown nil. All3 known comparisons FAIL before
code. State is presently NOT IMPLEMENTED. Log jev-model-state-before.log.

SDK Noul criteria encoding feature IMPLEMENTED, AFTER test written:
Question.noul(instructions: String, criteria: [String:String]? = nil),
encoder optional criteria. Source consumer pattern only encode switch
changed, all existing callers compile and omit criteria. New encoder
test PASS; before source had extra-argument compilation failure,
jev-model-before.log. Source/JevVoiceCore/Models/JevModels.swift and
Tests/JevVoiceTests/JevModelsTests.swift ownership added.

IMPORTANT: JevChooser is STILL UNCHANGED. prefix3 is still present.
No production questions use Noul criteria yet. Next implement now.

Fresh new live harness:
Tests/JevVoiceAppTests/JevProgressLiveTests.swift,16 authored cases
(8dev/8evaluation),3 repeats, nil budget, actual JevDecider/JevChooser.
Uses existing JevAdaptiveLiveTests.Recorder with NEW ledger
jev-progress-grant.json (old243-call ledger untouched). User unlimited
synthetic approval covers it;512 is per-batch ledger, not product cap.
Do not overwrite old runs/grants. No desktop mutations in this harness.

Control1 raw:
jev-progress-control-1370C822-B068-442E-AC83-23D80E87988B.json
48rows,50 requests. Only DEV summary read:21/24 with3 mismatches on
"button-is-not-result". Harness label "Report generated" was ambiguous:
a click could inspect an existing report. Do NOT call these proven
unsafe actions or relabel raw rows. Development fixture ONLY corrected
to explicit "Generate report", criterion same; retained control1.
Re-frozen16-case source, reran control BEFORE any factory/state changes.
Control2 COMPLETE:
jev-progress-control-38315685-F7E3-4367-92D9-5CD6150C760E.json
log jev-progress-control-v2.log,48rows, test exit0. Source still frozen
at baseline factory. No evaluation outputs inspected. This is the
control to pair with candidate using SAME harness source/repeats.
Control2 used SDK optional-criteria encoder but factory passed nil;
legacy wire unchanged, encoder test proves it.
No API process/build is currently running (b9bdf3 completed).

Exact original45/48 misses finally read from CORRECT arm:
jev-adaptive-after-repeat-r2.json (NOT after-r2, that is41/48 revision).
- heldout-search-first trial0: goal enter supplied Search query thenGo.
  Correct t1 picked .65 initially and .78 on refinement, but support.71
  below.9 => abstain. Initial text_entry.67, applicability.72.
- heldout-next-then-finish trials0/1: correct Continue e2 picked, refined
  probabilities.89/.93, but support.64/.65 below.9 => abstain.
  Empty observed_content, no screen_values, generic controlled window.
Three missed OBSERVATIONS = two distinct tasks. No bad action/completion.
Do not call this proven intrinsic model limitation or lower thresholds.

NEXT CORE IMPLEMENTATION (code not written yet):
- Shared observation-field builder in DriveCandidates, so production
  JevDecider AND read-only DriveLoop.preview use same named state.
  Preview currently lacks _candidate_details and current_instruction,
  so factory cannot identify typing actions there; upstream integration
  gap, not new tool. Avoid duplicating a second metadata implementation.
- Existing private JevDecider.Candidate WRAPS draft property; use
  candidates.map(\\.draft) for shared helper. Metadata tool from draft
  kind.request, literal_available from task values lookup, and
  literal_matches_current_value only when current value is KNOWN
  and not protected. Never raw caller literals into API.
- Existing literalText lookup: label case-insensitive exact in values,
  fallback values["text"]. Move unchanged lookup to common helper,
  let decider delegate; pending answers still isolated in parked tuple.
- Fields: all nonsecure observed labels/values including blank,
  screen_values when current value known, supplied_field_labels,
  current_instruction, _candidate_details. Remove lingering metadata
  label120/value240/actions8 prefixes too. Common privacy predicate
  matches existing role+label contains secure/password masking.
- Merge extras so they cannot override observed facts/goals/options.
  StateJSON already protects goal/options.
- Factory primary can receive compact literal_state (label, available,
  exact match bool) without raw supplied text. Unknown stays unknown.
  Preserve full named metadata for meaningful followup.
- Factory add explicit positive/negative Noul criteria for applicability,
  completion, text entry and candidate operation fit, per docs.
  Judge NEXT operation, not whole workflow or permission. Code owns
  literal, execution, consent, target authority, verification.
- Remove .prefix(3) to support all eligible visible candidates in ONE
  followup. No arbitrary productive-round ceiling or omitted-control
  cap; no blind repeated same question and no threshold lowering.
- SDK encoder test alreadygreen; metadata/refiner test currentlyred;
  candidate fresh API same16/3 repeats after this source frozen.

Additional current changes:
- CONTRACTS main budget amended to optional RoundBudget + wall reason.
- PROGRAM3 old4-round references changed to progress-driven/explicit
  budgets, latencies unchanged.
- P4 ExecPlan owned paths includes new model/tests/program, plus combined
  approved Decision Log. Historical entries kept.
- Acceptance P4-2 check updated for new contract; existing pass evidence
  explicitly HISTORICAL awaiting revision review, no booleans flipped.
- P4-5 false evidence corrected to raw strict16/30,83% claim withdrawn.

Native fixture source extended with choices45 grid + independent
selection result. --state now REQUIRED and refuses existing file,
no /tmp default overwrite. Still NOT BUILT/RUN.
Need native builder/runner and verification-lane scopes. Plan:
Swift AppKit fixture .app in fresh owned temporary dir, ad-hoc signed,
bundle dev.jevvoice.workflow-fixture;8 positive cases maybe setup7/10,
choices45,2 distinct forms,3 calculator goals, with independent state
JSON verifier and screenshots of OWN window only.
Use real packaged Jev MCP binary, app identity (no hidden target pins),
provided literals/final criteria, explicit JEV_CUA_SOCKET to pinned
standard embedded daemon if necessary; no bypass approvals. Read
standingGrant bool, never enable persistent setting silently. Daemon
--pid-file own path, logs discard, owner process handles cleanup.
All under with-desktop-lock.py and explicit JARVIS flags.
Before/after same fixtures, source hash, repeats; strict success only
done/already && verified && !is_error, false_done independent.
Preserve pilot failures. Prefer signed staged release candidate proof
BEFORE final one approved installed-app replacement, so fixes can
happen without repeated reinstall prompts. Installed R2 remains baseline.
Read Makefile staging/signing recipes to stage copy outside synced
Documents; never claim debug binary is final production qualification.
Native builder/runner code NOT CREATED yet; no native actions yet.

All source/metadata edits focused; many pre-existing dirty worktree
changes preserved. No commit/push. Full Swift/tracker lane, reviewer,
native proof, approved install and actual P4 G4/G5 remain outstanding.

## Continuation checkpoint 17:55 (supersedes 17:24)

Core M2 NOW IMPLEMENTED:
- DriveCandidates.observationFields is shared by JevDecider AND
  DriveLoop.preview. Includes observed safe labels/values, caller label
  keys, literal availability and exact current-value comparison (nil
  remains unknown), complete candidate metadata. No120/240/8 truncation.
  Secure/password role+label masking shared. Preview sanitizes its
  elements before making descriptions too. No raw caller literal added.
- JevChooser now USES Noul true/false criteria for applicability, done,
  text entry and support. All eligible actions stay in ONE refinement,
  not just3 or only type actions. Probability floor and support.9
  unchanged; initial fast path still uses.7 applicability. Only2
  meaningful requests/observation, no blind rerolls.
- Compact literal_state primary; full metadata on refinement.
- Core/model3 new tests green, adaptive17 tests green, broad235 tests
  green. Logs jev-model-after.log, jev-adaptive-final-check.log,
  jev-progress-focused-final.log.
- Two mocks were upgraded for new question shape, not assertions:
  typing refinement now asks support for both focus/type plus Choice
  (old fake had an UNASKED Choice e1 ignored by old sole-type branch).
  Same t1/applicability assertions retained.
- Our new idle/progress fake had "Ready" markdown but omitted Ready
  static node from its structured elements. Added real Ready/Working
  AXStaticText to fixture; unchanged done14-round assertion now green.
  Actionable-button proof rejection was NOT relaxed.

Fresh API R3 outcomes, SAME16 authored cases/3 repeats:
CONTROL2:45/48,3 wrong expected-primitive matches,0 false Done,
  p50 91.8297085ms,p95 199.567375ms,55 requests.
candidate1:
jev-progress-candidate-41407EE4-BDF5-43E7-A9E9-CE36F7004A2F.json
44/48,3 wrong matches,0 false Done,p50 79.7993545,p95 138.978458,
46 requests. RED regression retained, no install.
Both harness source hash1d419d...42e093 identical.
All3 wrong matches on BOTH arms = ambiguous-left-wizard: two identical
Continue controls, no frames. Model infers first AX index is left.
This was evaluation data and is NOW SEEN. Do not call future reused
results blind heldout.
Candidate1 also abstained once on Focus Search without changing text:
primary Choice e1.88, app.47, type_entry.03; refined e1.97, support.85
below.9. Description "press Search" unclear; thresholds NOT lowered.

FIXES FOR THESE NOW WRITTEN, testing in flight:
- New testObservedBoundsAreKnownOrExplicitlyUnknown failed2 assertions
  first (jev-bounds-before.log), then implementation uses EXISTING
  DriveLoop.nativeAXScreenRect validation to include actual observed
  global top-left point bounds, explicit null for missing/invalid.
- Factory puts bounds in primary AND followup available_actions;
  target-fit criteria forbid inferring left/right/top/bottom from
  AX/option order when no bounds or explicit relational label exists.
  NO extra mandatory question/response field was introduced.
- Editable click descriptions explicitly mean focus WITHOUT changing
  text; type descriptions mean focus AND enter. Same descriptions used
  in ALL followup questions/options. Applicability criteria now give
  focus-only its proper positive case and make entry contrast conditional.
- This increases grounding information, does NOT add coordinate output
  authority, raw gaze, lower thresholds or new planner.

ACTIVE process997314:
verification lane grounding regression -> adaptive17 -> broad235 ->
fresh candidate API2 through SAME unchanged16-case harness.
Logs jev-bounds-after.log, jev-adaptive-final-v2.log,
jev-progress-focused-v2.log, jev-progress-candidate-v2.log.
Wait for completion/read artifact+score. DO NOT edit verification-lane.sh
while it is running: learned Bash file-offset trap below.
No other active process known. NO INSTALL YET.

New reproducible native tooling:
- jev-native-proof.py mode build/run (stdlib + existing bench MCPStdio,
  tool_text/classify, no new protocol implementation).
- p4-native-build lane built signed fixture, receipt
  jev-fixture-build-af66d45ce20c45769d3d7dbca90987c1.json.
  App/exe in receipt /var/folders/.../jev-p4-fixture-zrgsbx6u/.
  Source fixture unchanged since this receipt.
- p4-native-proof behind JARVIS_P4_NATIVE=approved, desktop lock.
  Eight positive cases: setup7/setup10, last of45 numbered Choices,
  Aster/Mira2-page literal profiles,3 calculator goals.3 repeats.
  Independent app-state verifier, bad verifier negative control,
  strict done/already && !error && independently verified, false Done.
  Photos only OWN window.8s caller diagnostic deadline then STANDARD
  notifications/cancelled to let parked asks clean normally, not kill
  blindly.20s RPC fallback. Same slug across all child connections.
  Explicit owned standard pinned daemon; no GUI-autospawn/Fn proof.
  Policy standingGrant is read only, not changed.
- p4-stage-candidate / jev-stage-candidate.py stages normal make stage
  bundle outside Documents, signs existing identity, strict verifies,
  source before/after hashes, pinned cached runtime check, NO install.
  NOT RUN YET. Do not run make app on synced-tree destination.

Native harness SETUP FAILURES retained:
native-before-d2b3541f6f36410f9be9e693352df48e/results.json24 rows:
ALL blocked before any Jev work, "No installed macOS app found for
bundle_id dev.jevvoice.workflow-fixture". Fake app was launched by
raw executable and not resolvable by pinned driver's installed-app
lookup.0/24 is NOT a model-reliability result. Processes cleaned.
I accidentally inserted a verification-lane case while that invocation
was inside Python: Bash old file offset then hit a spurious ;; at EOF.
bash -n current file PASS; script itself not malformed. Record wrapper
failure honestly; DO NOT edit executing lane again.
Next tried lsregister -f owned temp app (harness only), but
native-pilot-e47250a908d34a25ac869cd557d48848/results.json still same
app lookup failure. No actual actuation qualified. Kept.

LATEST NATIVE HARNESS CHANGE NOT RUN YET:
Use normal /usr/bin/open -n -W receipt.app --args kind/state/steps
instead of executing binary directly. wait_state gets actual app PID
from owned state JSON; verify /bin/ps comm matches receipt executable.
Cleanup SIGTERM only this known fixture PID + own open wrapper and MCP
child/daemon. No broad app kills. lsregister -f still present.
Next run SINGLE setup7 pilot through lane after997314 finishes.
If still app lookup failure, diagnose fixture enrollment, NOT product
confidence; do not bypass captured scope by adding hidden MCP pid pins.
May need provision ONLY owned fresh fixture bundle in ~/Applications
(parent exists, verified) or proper LaunchServices discovery. Nothing
personal may be reset/overwritten; no browser/doc access.
Source Cua clone is NOT at development/cua-source (path absent).
Pinned driver serve --help confirms --pid-file, --embedded,
--permission-mode standard, --grant existing-profile supported.
Native actual before/after must use SAME final working harness/source/
workload/repeats; prior setup-failed runs are diagnostics, not comparison.

Need finish: source/API2 verify, fix remaining real regressions if any,
native enrollment + REAL A/B, staged signed candidate, full all lane and
boundary probe, independent scoped/phase review, approved single final
install + direct signature/startup/readiness proof, generated truthful
HTML and handoff. No P4 flags flipped. P4-5/6 remain false; criterion5
strict old16/30 corrected, not83%. Native slice may be judge-accepted
but cannot be called original personal-browser bench or mic qualification.

### 17:57 update
997314 finished GREEN: bounds regression1, adaptive17, broad236, fresh
candidate API2 (same frozen harness):
jev-progress-candidate-41DB4199-F0A4-4495-A0A1-543896E0FE68.json
46/48, ZERO wrong primitive matches, ZERO false Done; p50 82.2713535ms,
p95 192.966334ms,50 requests. Two safe refusals, both trial2:
blank-note-before-save and rename-before-confirm. Do not call48/48.
Both spatial ambiguity and focus negative/positive cases now correct.
This16-case set is different from the original R2 24-case/2-trial set.
Do not pretend46/48 directly compares to old R2 45/48; valid comparison
is current control2 45/48 WITH3 wrong vs candidate2 46/48 WITHOUT wrong.
Case eval slice was reused/tuned, do not claim blind heldout accuracy.

375f40 NOW ACTIVE: normal LaunchServices open -n -W fixture setup7
pilot against installed OLD app (not candidate). Native runner updated
with actual app PID from owned state, ps executable identity check and
SIGTERM only owned fixture PID, then own open wrapper. No new install.
Read jev-native-open-pilot.log/result. If it STILL says "No installed
app", diagnose app enrollment, maybe fresh owned ~/Applications bundle.
Parent ~/Applications exists (verified), never overwrite other apps.

P4 current report still needs generation, native actual comparison,
staged candidate build, full all lane, independent final review and
approved install. No phase flags or deployment claims changed.

### 18:00 native blocker detail
375f40 finished: normal open launches own real app correctly (ps identity
passes), but STILL blocked APP_NOT_INSTALLED for same fake bundle id.
native-pilot-1972c6acc38c40f3b210cd50860bebb1/results.json kept.
No active processes now. Native enrollment, not Jev, is blocker.

FOUND actual vendored source read-only:
development/JevVoice/cua-source/libs/cua-driver/rust/crates/platform-macos/
src/tools/launch_app.rs134: APP_NOT_INSTALLED before attempting launch.
src/apps/mod.rs346..359 resolve_bundle_id_to_locator directly calls
NSWorkspace.URLForApplicationWithBundleIdentifier; returns None.
Name resolution only scans /Applications,/System/Applications (+Utilities)
and ~/Applications then falls back to this NSWorkspace lookup.
DO NOT modify/pin-swap driver. This is root fixture provisioning clue.
Need normal installed/discoverable owned temp bundle, e.g unique fresh
app inside ~/Applications (exists; never overwrite/delete others), and
preflight NSWorkspace lookup BEFORE launching owned daemon. Current
fixture lives in /var/folders/.../T; registration/open still doesn't make
driver lookup work. Can inspect OWN app Info.plist / Bundle.main identity.
Do not endlessly rerun all24 rows; one setup7 pilot until discovery works.

### 18:45 latest checkpoint (SOURCE work in progress)

Native provisioning FIXED: builder now creates ONLY fresh unique owned
bundle inside existing ~/Applications. New signed receipt
jev-fixture-build-c96108c5eb844df7965643742c76fb57.json,
app ~/Applications/Jev P4 Fixture 4194489ba45b423f9f68defa1e301484.app.
Source fixture Swift unchanged. Actual installed-old-app pilot reached
stage1 then honestly stuck, not APP_NOT_INSTALLED. Normal open launch,
ps identity and owned PID teardown work.

ACTUAL native before24 completed via f69dcb (no active native process):
native-before-d0db3f709c7e4d2785b5daca6838ebce/results.json.
Method frozen30s caller deadline except forms8s; same for both arms.
All source-owned, synthetic data, no personal browsers/docs/Fn.
Did not yet compute all metrics. Looks0strict, partial effects/
missing literals, cap/stale stops. This IS real native data, unlike
earlier enrollment failures. Processes clean.
Current native harness was COPIED BYTE-IDENTICALLY as immutable
jev-native-proof-frozen-primary.py. Use p4-native-frozen-proof lane
for final candidate PRIMARY24 comparison, so exact harness hash matches
before. Do not edit frozen file! Mutable jev-native-proof.py may later
gain optional goal-only mode for separate default-path checks.

IMPORTANT NEW BUG/APPROVED AMENDMENT:
TaskLoop hardening made successContains=[] impossible to complete,
so generic normal goal-only voice/MCP could act but never finish.
Senior d3665964 first correctly FAILed unauthorized/underspecified
semantic-goal proof plan. User then EXPLICITLY G1 approved via tool:
"Approve observed proof", high-confidence observed fact with code fresh
same-window/unchanged-context verification, supplied criteria authoritative.
Revised concrete plan got senior G2 terminal PASS. See
jev-semantic-completion-plan.md and actual appended Decision Log in
.agent/CONTRACTS.md, recorded BEFORE source code.

New JevObservedGoalTests.swift9 tests written BEFORE implementation:
production full factory/decider/TaskLoop goal-only action+outcome;
already true no mutation; button/secure fake evidence; button role with
MISSING AXPress metadata; changed Account A->B same proof text;
tick/context drift; forged fact ID; explicit/blank criteria precedence;
cancellation during targeted support. Before run failed4 assertions
as intended, jev-observed-goal-before.log (including2 goal-only done
positives and role-only button false-evidence bug, cancellation).

Implementation JUST WRITTEN, NOT YET VERIFIED:
- NEW Sources/JevVoice/Drive/ObservedGoalProof.swift:
  typed Sendable/Equatable TaskBrief-bound context/nodes/fact proof;
  TaskBrief now Equatable (additive). Context all safe AX nodes with
  role/label/value/frame/actions sorted, title; exclude ephemeral token/
  snapshotID, mask secure node label+value. Strong full context equality
  intentionally rejects unrelated ticking UI. Facts only known safe
  read-only labels/current meaningful values; no button/link availability
  even if actions=[]; no secure/blank values. Same-node equal label/value
  deduplicated. Different label/value both allowed. IDs code-enumerated.
  Scores check model EXACT jev-1.14.0, done>=.95,evidence>=.9,support>=.9.
  matches checks exact TaskBrief (includes literals/deny/etc), current
  context/fact; origin snapshotID checked at verify entry.
- ActuationRequest.verification:ObservedGoalProof?=nil additive;
  no DecideResult.done change. TaskLoop puts actually bound WindowRef
  in observation task even frontmost fallback. Per-run verifiedGoal
  local; semantic verify ALWAYS NEW source.axTree read regardless of
  settleReobserves=false, rejects drift, checks cancellation before/after.
  Done requires verified settle + literal evidence OR current matching
  verified proof. Tool mutation clears proof. No quiet/effects bypass.
  successEvidence uses shared fact collector, fixes empty-action
  button labels being mistaken as read-only outcome.
- JevChoice3 optional goal metadata IDs/probabilities added.
  JevChooser pops private opt-in/fact maps. Only enabled by JevDecider
  with empty criteria AND bound window. Goal-fact Choice added alongside
  primary only when actual facts exist; if done>=.95 and fact>=.9,
  one targeted goal_supported Noul>=.9, at most2requests total.
  No model text/scope/predicate accepted. Other factory callers default
  opt-out if private flag absent. P5/P7/P9 NOT auto-enabled.
- JevDecider merges code-owned proof choice state after extras. Resolves
  validated ID against SAME snapshot, mints typed proof, requests
  verifyState. Cached proof only returns done when history.last is
  successful verify and current whole context still matches. Clears
  cache at step0. Explicit code predicate fast path unchanged.
- Preview may only suggest completion, now says drive_until must verify.
  It does NOT mint semantic proof. Model metadata shared otherwise.
- Contract amendment added after G1/G2; no MCP/nine-tool, permission,
  actuation authority, literal ownership or driver pin change.

ACTIVE00874c running serialized p4-jev-observed-goal (compile+9 tests),
log jev-observed-goal-after.log. Read result. Likely compile/runtime
issues may need fix; do NOT claim green yet. No other active known.
All builds via verification-lane. Don't edit lane WHILE executing it!
Sources now include major new observed-proof code, no installed update.

Still to finish: new9 regression fixes/green, focused+full all lane,
fresh API sample (keep earlier46/48 and red44/48); boundary probe;
stage SIGNED normal release via p4-stage-candidate (not yet run);
PRIMARY native24 via frozen harness vs actual before24; separate default
goal-only native checks (need omit success_contains caller argument,
not fake response/criteria), independent scoped code+evidence G4 review,
approved final install once candidate proven, verify signature/PID/
tracker readiness honestly (timeout if any), generated truthful HTML/
handoff/phase judge. P4 flags5/6 still false. No install/phase closure.
