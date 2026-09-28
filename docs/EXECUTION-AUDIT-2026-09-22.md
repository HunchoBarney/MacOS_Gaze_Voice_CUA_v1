# Jarvis execution and documentation audit — 2026-09-22

> **Pre-implementation snapshot.** This audit records the baseline and findings
> before the scoped implementation. Its statements that no live tests or changes
> existed are historical. For current implementation status and evidence, see
> [the replacement record](EXECUTION-SIMPLIFICATION-REPLACEMENTS.md) and
> [the scoped evidence ledger](voice-ui/EVIDENCE.md).

## Scope and evidence

This is an audit, not an implementation or acceptance report. It reviews the active
README, architecture/development/storage/handoff/cleanup documents, the voice
specification, plan, execution instructions and evidence, the simplification plan
and replacement record, relevant Swift execution code, and the installed Driver's
read-only `list-tools` inventory. The plan in `cua-jev-understanding` is byte-for-byte
identical to this workspace's plan. `HISTORY.md` was checked for authority only;
its old requirements are explicitly inactive. All local Markdown link targets in
the reviewed documents exist. No live desktop test, app launch, or mutation was
performed for this audit. The working tree was clean before this report.

The user's clarified product goal is **several visible Jarvis runtime agents
working concurrently**, with background execution where the OS and target allow,
fast decisions, broad computer control, and accurate observed outcomes. Cua
provides sessions, per-session cursor feedback, targets, actions, observations and
some verification. A session label does not confer decision authority or isolate
global focus, clipboard, or a user's edits. The host still owns goals, permissions,
task dependencies, conflict coordination, and truthful completion.

## Findings, in priority order

### P0 — The current loop can insert incorrect text twice

The latest recorded TextEdit trial inserted `copper lantern beside the`, then
inserted `copper lantern beside the window` into the renamed field, producing a
57-character value. The independent assertion rejected it; model `done` was not
accepted as proof (`voice-ui/EVIDENCE.md`, native-text-window-repaired-live).
`CuaTaskAgent` suppresses repeats by action description. A field label change
changes that description, so the same intended insertion becomes a new candidate.
`JevSpeechIntent.textPayload` also has recorded failures on unquoted queries and
literal content. These are observed defects, not hypothetical risks.

**Change:** define an effect identity from task, original target, operation and
source speech span; freeze the exact literal payload before dispatch. Distinguish
an intentional second effect from recovery of an uncertain first effect. Check the
addressed field's final value before claiming success. Do not retire the existing
replay protection until changed-label and uncertain-effect cases pass. Keep the
failed samples in the evidence ledger.

### P0 — Jev sees only a small fraction of Driver's usable action surface

The installed pinned Driver advertises 58 tools through read-only `list-tools`.
`CuaActionCatalog` currently offers native menu, AX click/custom action, text and
scroll, plus browser type/click/scroll. It does not construct actions for, for
example, browser navigation, dialogs, downloads/uploads, native key combinations,
drag, value setting, or several pointer actions. Some of the 58 tools are setup,
diagnostics, or dangerous operations and should never be ordinary candidates.
The active spec's broad coverage requirement and A13 are therefore open.

**Change:** make an explicit capability inventory with four dispositions for every
advertised tool: ordinary grounded action, action requiring exact authorization,
setup/diagnostic only, or intentionally unsupported with a reason. Build typed
candidates for needed action families using observed targets and arguments. Avoid
a blanket 58-tool prompt or an opaque generic tool executor. Prove a representative
native and browser action from each included family, including refusal paths.

### P0 — Cua sessions and cursors do not supply multi-agent coordination

`CuaVoiceRuntime` already creates task IDs and named Driver sessions, displays task
rows, and routes Stop/Stop All. `CuaWorkQueue` allows three active app leases but
only one task per bundle ID; the lease lasts across the whole agent run, including
model waits and observations. Two tasks in different windows of the same app cannot
make progress together through this queue. The three-task limit is therefore a
limit on admitted app leases, not proof of three concurrent agents on the screen.
Driver serializes individual native input calls, not multi-step transactions.
These facts match the open P3/A6/A7 gates.

**Change:** retain one small task registry and one conflict arbiter in Jarvis. First
measure where tasks wait. Then claim resources for the shortest safe sequence:
exact window/tab/document when independently addressable; app-global menus,
clipboard, OS focus and user-active target as broader resources. Keep independent
observation and Jev calls concurrent. Show queued, working, waiting-for-focus and
uncertain states in Activity, tied to the same session label as Cua's cursor.
Verify two same-app windows and a third user-edited window before weakening leases.

### P0 — General computer control is currently app-scoped and step-limited

`CuaTaskAgent.run` chooses one installed app at the start, acquires its lease and
runs at most 16 passes through its observe/decide loop. These are not 16 action
dispatches: waiting for a new window, visual inspection, generation and submenu
listing can each consume a pass without a final action. The exhaustion message
calls this an "action limit," which is misleading. It can choose among windows
within that app, but it
does not retarget a single task across apps after completing a subgoal. The current
loop can therefore handle many bounded app tasks but does not implement a general
multi-app request such as gathering data in one app and drafting it in another.
The model also receives at most 220 native elements in normal window snapshots;
the code only refreshes once when the element list is empty and does not use an
incompleteness signal to expand a nonempty truncated tree. This limits context.

**Change:** define a task as a goal with ordered, observable subgoals and target
handoff, while keeping one action-selection loop. Use a bounded continuation when
the app must change; acquire the next resource only when needed. Surface a request
for clarification when destination or authority is ambiguous. Detect incomplete
observations and expand or inspect the exact target before concluding absence.
Do not build an unrestricted plan executor or add another reasoning service by
default.

### P0 — Completion and authorization need independent checks

The loop offers Jev `done` based on observed state and history, but ordinary
actions do not all have a task-specific deterministic postcondition. The
`CuaStateVerification` adapter is test-only and has no production caller. The
recorded failed native trial demonstrates why a model completion judgment is not
enough. The `risk` choice also asks Jev to distinguish ordinary, deletion/purchase,
explicit send and blocked operations. There is no general deterministic policy
that can prove the intended recipient/content or exact destructive target from
that model answer alone. This is an identified risk; no unintended send or
deletion was observed in this audit.

**Change:** represent each intended effect and its evidence explicitly. Let Cua
verify narrow predicates where supported; use readback or a fixture/application
oracle for the full task outcome. Require exact observed recipient/item/content
and matching user authorization before high-impact dispatch, with a refusal when
those facts cannot be established. Keep uncertain, partial, cancelled and failed
outcomes separate from success. No retry after an uncertain mutation until state
has been inspected.

### P1 — Current latency architecture conflicts with the two-second target

An ordinary request can make sequential Jev calls for speech boundary/kind,
task routing, app/scope/visibility, next action, risk/window effect, payload and
final completion, plus Driver observation and readback. The recorded candidate
browser and native trials took about 12.6 and 20.7 seconds respectively. These
are specific fixture/task durations, not a measured spoken-command p95. The S8
two-second warm action-start target remains unproven and should not be claimed.

**Change:** record a per-task critical path before refactoring. Batch independent
choices that share one snapshot, cache stable app inventory/target information,
avoid repeating unaltered judgments, and move read-only observation ahead of
resource acquisition where safe. Preserve the action-start and verified-result
timings separately. A faster incorrect dispatch does not count as improvement.

### P1 — The simplification plan is an investigation plan, not a current build plan

The 375-line simplification plan still has unchecked steps 1–3 even though its
status and replacement record say the baseline, replacement map and provisional
Swift boundary were completed. Its step 4 native proof is still failing, while
step 6 has accumulated candidate Driver patches. The replacement record combines
decision history, work logs, proof gaps and next actions; the 475-line evidence
ledger repeats many of those details. A new agent must reconstruct the present
state from multiple long files. The opening sentence of the replacement record
also calls the latest point a `2026-09-22 checkpoint`, which will age quickly.

**Change:** make the simplification plan a short, current execution contract:
goal, protected behavior, selected boundary, one open-gate table, next ordered
slice, deletion rule and completion rule. Mark completed investigation decisions
as completed, with links to dated evidence. Keep experiments and full logs in the
evidence ledger; keep the replacement map as a concise current contract table.
Avoid copying results into three active places.

### P1 — The product contract and implementation sequence pull in different directions

`SPEC.md` and `PLAN.md` correctly say broad Driver capability coverage and
resource-aware concurrency are required. The scoped simplification plan says
to keep this task narrow and not resume P0–P5. Its first proof set covers TextEdit,
browser search, scroll, target change, cancellation and timeout, but omits a
representative capability-inventory check and real concurrent-task progress.
If followed literally, it could finish as a smaller single-app executor while the
user's actual runtime-agent goal remains unsatisfied. The plan does say the broader
gates remain open, so this is a scope gap, not a direct textual contradiction.

**Change:** decide whether the next implementation task is only simplification or
the broader product capability. For either path, show the two outcomes separately:
"execution machinery simplified" and "multi-agent general control accepted".
Include at least one same-app concurrent/background proof before claiming the
former improves the user's stated goal. Do not close P0–P5 from scoped proofs.

### P2 — Setup and handoff docs are mostly accurate but historical

`README.md`, `ARCHITECTURE.md`, `DEVELOPMENT.md`, and the Conductor settings agree
on the current two-module Swift package and workspace-local setup. The local
storage document correctly warns that `development/` holds unique ignored source
and assets. `HANDOFF.md` and `CLEANUP.md` describe older dated packages and should
remain labeled snapshots, not current installation advice. The active spec's
installed-path requirement, the readme's development bundle and the staged
candidate packages refer to different artifacts; a current-state table should
name which one is installed, which is staged, and which is only a test build.
The Cua source checkout's broken Git metadata and local candidate patches are
material recovery risks already documented in `ThirdParty/Cua/README.md`.

## A smaller target architecture

1. **Voice boundary:** Apple capture and transcript revisions emit a complete
   request with immutable source-span/payload identity. Keep Fn/UI/configuration.
2. **Task registry:** task ID, goal, dependencies, target, authorization, effect
   ledger, status and cancellation. One place owns user-visible task state.
3. **Per-task loop:** observe exact target → construct typed candidates from
   supported Driver capabilities → one grounded Jev choice → validate identity
   and authorization → dispatch through Cua → verify effect → continue, clarify
   or finish. No second desktop planner.
4. **Conflict arbiter:** gate only resources that can interfere. Driver handles
   call-level input serialization and cursor/session lifecycle; Jarvis handles
   multi-step ownership and user focus.
5. **Optional generation:** configured provider returns prose/advice as data.
   The same target, authority and outcome checks govern any insertion or send.

This describes ownership, not a request to create five new frameworks. Prefer
shrinking the existing types after proofs. Count total custom Swift, Cua patches,
process/packaging dependencies and latency, not file count alone.

## Recommended sequence and proof gates

The product priority was clarified after this audit: **expand Jev's grounded Cua
action choices first**. This reorders the engineering work without accepting the
existing text/replay failure or weakening its production protection.

| Order | Work | Required proof before deletion or promotion |
| --- | --- | --- |
| 1 | Inventory and expose needed Driver actions | Advertised-tool disposition table; bounded Jev choices retaining exact Cua targets/arguments; representative native/browser live effects/refusals |
| 2 | Repair payload and effect identity | Exact native/browser text; changed-label repeat, intentional repeat and unknown outcome distinguished; no duplicate insertion |
| 3 | Define goal outcome and policy contracts | Contradictory state blocks completion; exact send/delete target and authority; partial/uncertain results retained |
| 4 | Enable cross-app task continuation | Same task retains goal and destination across two apps; no stale target or accidental focus switch |
| 5 | Narrow leases using measured conflicts | Two agents act in separate windows while the user edits a third; global focus/menu/clipboard conflicts wait visibly |
| 6 | Measure and simplify | Matched baseline/candidate task success, action-start/result latency, model/Driver calls, full dependency and code burden |
| 7 | Promote one path and package | Focused suites, `make test`, signed package, launched installed app, rollback and physical Fn checks where required by the relevant gate |

The next engineering slice should be **order 1**. The current native failure still
blocks production promotion and deletion of its protections. The next
documentation slice should replace the stale checkboxes/status duplication with
one current open-gate table. Live checks remain opt-in and use the shared desktop
lock. This audit makes no claim of physical Fn, installed-package or broad app
acceptance.

## External contract cross-check

The current public [Cua interface contracts](https://cua.ai/docs/reference/cua-driver/contracts)
describe public session names as labels, with target and authorization separate.
Its [process model](https://cua.ai/docs/reference/cua-driver/process-model)
describes call-level native input serialization. Its [known limits](https://cua.ai/docs/reference/cua-driver/limits)
document target and app cases where background work is unavailable, including
foreground-dependent canvas apps and unsupported typed browser routes. The
[jev-use guide](https://cua.ai/docs/how-to-guides/driver/jev-use) says its chooser
selects an ID while the host constructs actions and verifies postconditions.
These changing online contracts informed this audit; implementation decisions
must be checked against the installed pinned Driver. Conductor's
[parallel-agent guide](https://www.conductor.build/docs/concepts/parallel-agents)
concerns coding workspaces, not the Jarvis runtime-agent feature.
