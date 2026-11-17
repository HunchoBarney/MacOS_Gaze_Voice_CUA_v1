## Shipping-plan review queue (2026-11-15)

C1-R10 supersedes local-only speech authority for the normal voice path.
The user explicitly chose OpenAI Realtime; revised G2 contract
`results/P4/c1-r10-realtime-contract.md` passed reviewer87dfafed.
An authoritative final is either explicit legacy local ASR or the current
Realtime input item's completed transcription, matched to its committed
item, connection, epoch, turn and onset context. Partials, assistant
transcripts, model tool arguments and unknown/stale items cannot supply
it. Existing critical-value, target, ask, cancellation, exactly-once and
outcome checks stay binding. Default readiness bypasses local ASR/VAD/TTS.
Nine-tool v1 shapes stay; local-only wording and source-specific tests
change with explicit provenance. Required consumers: VoiceController,
RealtimeVoiceLane/Client, LocalSpeechSession/VoiceTurnGate,
VoiceResponseAuthority, ConversationSession/Context, dictation delivery,
task feedback, evidence/qualification, settings/onboarding and P12 speech
resource declarations. G4 must review their actual implementation, then
signed/live/human gates; this decision alone is not implementation proof.

Latest user direction retains Jev/Cua and explicitly permits Terra API
recovery. P5's planned `RecoveryDecider` replaces the unimplemented
Sol-specific adapter name; frozen protocol shapes below are unchanged.
G2 must review P4/P5/P7/P9/P11 consumers, routing, API tool support,
cancellation and result provenance before implementation. Neither model
gains independent input/permission authority. Dictation context bias and
formatting require the P3 ASR/literal contract review; comparative scoring
does not relax exact-content requirements.

The user authorized planning/documentation updates. Existing interfaces
and numerical gates below remain binding. This queue identifies changes
that need G2 and consumer review before source implementation; it does
not amend a public schema or authorize input/model/provider changes.

| Owning phase | Review before implementation | Consumers/evidence |
|---|---|---|
| P3 | Streaming finalization and direct exact insertion preserve final-utterance authority, captured focus and single delivery; new ledger fields are append-only | VoiceController, LocalSpeechSession, RealtimeVoiceLane, DictationDelivery, FocusedTextTarget, FastLaneExecutor, voice evidence/physical qualification |
| P4 | D120 scroll authorization equivalence; D121 exact/hidden requirements cannot be discharged by a correlated kind judgment; typed proof provenance and observation reuse | TaskLoop, DriveLoop, JevDecider/JevVisualDecision, VisualGoalProof, native observation, chooser, voice/preview consumers and signed oracles |
| P5/P7 | Jev-first decisions and SDK-backed Terra API recovery share executor/consent/verification; no generated authority or self-written probability substitution | Decider/CaptureSource, RecoveryDecider, BrowserDecider, coordinator, Cua and safety/event adapters |
| P6 | ScriptIntent argv/confirmation contract supports packaged native helpers/OS runners without a developer toolchain; typed account/contact/date binding | Script registry/executor, realtime schemas, coordinator, CuaPolicy, onboarding and result verifiers |
| P5/P6/P9/P13 | Bench §7 currently allows only mcp_stdio; any new normal-product injector and oracle shape requires a versioned extension | bench/run.py, mcp_stdio/results/verifiers, selftest, corpus, report and phase G5 artifacts; no private-method call labeled as Fn proof |
| P8/P11 | Existing tracker host/IPC compatibility, runtime readiness, calibration provenance and resolved-target freshness; default dwell off is already required | TrackerHost/TrackerContract tests, Electron utility/IPC, GazeService/feed, DwellClick, deciders and onboarding |
| P9 | Skill locator/parameter validity, retirement and final proof; historical point fallback cannot bypass fresh validated grounding | SkillProgram, compiler/store/replay, native/browser executor, consent and result consumers |

See `.agent/SHIP-PLAN.md` and `.agent/REUSE.md` for delivery/reuse decisions.
An implementation-readiness handoff records exact reviewed source and
contract versions; it never implies upstream phase acceptance.

### D16 Private Explicit Candidate Decisions

User go-ahead on2026-11-12 follows the researched first decision-flow
refactor. Concrete contract: .agent/results/P4/jev-explicit-decision-plan.md.
Independent511e9c51 PLAN PASS / CONTRACT ACCEPT before code.

Primary per-candidate support uses the existing>=.90 gate and unchanged
raw action selection/applicability gates. Primary goal support is batched
per fact; completion>=.95, selected fact>=.90, its support>=.90 and fresh
native verification remain. Focused goal recovery is retained.

An optional private task/window/source-step-bound semantic proposal can
travel to visual grounding. It grants no authority and carries no stale
AX token for actuation. Operation, literal and key substitution fail;
set_value must never become insertion. Bound visual presence>=.95 joins
the existing second-stage per-pixel/per-native checks; all other identity,
location, policy, subject, freshness, deny and outcome gates remain.
No caller-provided proposal metadata. Generic image-only capability remains.

Source re-review must cover all observation/choice/voice/preview/proof
consumers. No driver, native-read, model/pricing, numeric-floor, public API
or installed-app change. D15's historical request identity evidence remains
historical: this amendment intentionally changes question composition.

### D13 Private Native Primary Category

User explicitly selected "Approve Reviewed Amendment" on2026-11-11
for results/P4/jev-native-primary-kind-plan.md, SHA256
953f18c706bd11fcc503fd41ebc3f7cee28975cd88832c6323064e628aaa170b.
Independent d0179f71 PLAN PASS and diagnostic SOURCE PASS.
Only JevVisualDecision.swift primary goal_kind instruction and
exact_text criterion may change, only with an actual native registry.
Describe the existing exact native readonly output basis, not proof
of goal satisfaction. No new definition/evidence fields before fresh
admission. Default/no-registry question strings/IDs remain unchanged.
All other primitives, thresholds, scope/fact/support/fresh-read,
subject, literal, hidden-state and authorization guards remain.
No added calls, permission, model or driver changes. Fresh337 suite,
owned-native keeper mutation, G4 and isolated G5 required. No install
or P4 acceptance is authorized.

### D12 Private Native Step Validity

User explicitly selected "Approve Reviewed Amendment" on2026-11-11
for results/P4/jev-native-step-validity-plan.md, SHA256
2f512638df0132802b075725f0916a0264043c2da8ad4266d546be7cf9b1d8be.
Independent d0179f71 PLAN PASS and diagnostic SOURCE PASS.
This authorizes the one-file JevChooser.swift delta and isolated
testing, not installation or P4 acceptance.

The existing refinement Noul judges one valid primitive of currently
unfinished work, not uniqueness or preference. Only preparation implied
by the requested end state is eligible; exact-control, subject,
constraint, no-repeat, literal and unrelated-data boundaries remain.
No new head or RPC. Support stays>=.90, the separate Choice's action
floor stays unchanged, and every visual/native outcome gate remains.
Use platform sorted-key encoding only at the two existing goal-fact
JSON-string criteria sites. Preserve string bytes and array order.
G2 includes account/document/entity-switch refusals. Re-review all
authority/voice/preview consumers; require fresh G4 and isolated G5.

### D11 Private Derived UI Semantics

User explicitly approved the reviewed two-file semantics amendment on
2026-11-11 via "Approve Reviewed Amendment". Plan:
results/P4/jev-native-derived-semantics-plan.md, SHA256
f73ab81935747a86ddef41c40c58d937be5afea67b6477b3ee43b087c232a121.
Independent d1a8446d PLAN PASS. This authorizes implementation and
isolated signed testing, not installation or P4 acceptance.

Clarify D10's private scope/selection/support: the selected native value
is the completed output, not its input/expression. Numeric operands alone
are not textual editing. All text editing/transformation/comparison,
including output not provided verbatim, remains excluded.

Only after actual freshValue admission may the verifier add explanatory
kind/subject definitions and clarify same_subject's ordinary requested
value changes versus immutable account/document/entity identity.
Definitions describe a claim, never establish goal satisfaction.
Invalid/absent fresh native evidence retains the old question/state.

All primitive shapes, raw-score thresholds and D10 hard guards remain.
Six original verifier questions remain verbatim; same_subject remains
Noul >=.95. No dropped gate, synthesized score, relaxed native context,
driver/schema/model/permission/round/extra-RPC change. Literal and legacy
paths stay unchanged. Every named consumer requires fresh source review.

### D10 Private Native UI Outcome Evidence

User explicitly approved the reviewed native UI outcome proof extension
on 2026-11-11. Plan: results/P4/jev-native-ui-outcome-plan.md,
SHAe76c52e3; independent73dc42f7 PLAN PASS after seven repairs.
This authorizes implementation and isolated signed tests, not installation
or P4 acceptance.

Add nil-default AXElement.nativeReadOnlyValue, separately producer-sealed
from editable field provenance, and optional VisualGoalProof.nativeOutcome.
Only actual readonly native CFString, independently owned PID/window,
complete bound read, CF identity and native read generation can qualify.
Clear SDK/cached metadata. No NSNumber/label/placeholder conversion.

An immutable code-owned registry feeds speculative scope/selection/
per-candidate support in the existing image request. Derived scope,
selected candidate and that candidate's whole-goal support each >=.95.
No caller/history literal or literal/hidden/mixed/unknown scope.
Fresh verification preserves all existing gates and additionally requires
same unique CF identity/owner/role/document/hierarchy/raw UTF8 bytes,
new native read/capture/generation, and fresh scope/support/literal checks.
Keep hasNativeExactEvidence unchanged. Positive exact_required still
demands exact native evidence. No invented old score or input authority.

No public schema, driver, permission, threshold, model, extra per-action
RPC or round-limit change. Every named consumer requires fresh G4 review.
P4 remains FAIL/open until complete independent release evidence passes.

### D9b Private Delivered Replacement Observation

User explicitly approved `results/P4/jev-delivered-effect-plan.md`.
Fresh senior9702f261 PLANPASS accepts its G2 production-seam test contract.
This is not phase acceptance. D9's strong proposal, receipt and exact
basis are unchanged; general completion remains .95/.9/.9 plus fresh
native readback.

The loop may retain a private factual pending record for an actual
stamped nonvisual set_value with dispatched AND verified outcome.
Promote only against the next already-scheduled native observation
proving complete unique nonsecure original-document/CF-field/fact/index/
role/frame/hierarchy/caller-byte binding and full native value equality.
Initial matching value, failed/undispatched/unverified/denied/cancelled
calls create no record. Clear on later input or any mismatching binding.

Factual executed_replacement can enter ordinary chooser state without
an exact receipt. It creates no _exact_replacement binding, replacement
questions/votes or exact basis. It never grants input permission or
declares completion. No CF handle/document fingerprint serialization,
extra AX/model request, new question, new done basis or public API change.
Nil/default observation slots preserve voice/control/read-only preview.
All consumers require re-review before signed admission.

### D9 Private Exact Replacement Evidence

Conditional Stage B reached after native provenance is demonstrably
present but signed matched633 strict1/3 still underclaims (native3/3).
G1 Full Plan approved; G2 contract29ea7ac6 PASS. Not phase acceptance.

Native field identity is an optional private retained AXUIElement/
CFEqual handle on AXElement, cleared with untrusted SDK/old metadata and
only assigned by verified native owner/window/unique role-frame merge.
Not serialized/logged, no registry or focus stealing. It is separate
from Node/Context equality to preserve existing general proof behavior.

Actual set_value may carry a code-owned immutable proposal binding
caller task/value UTF8 bytes/source key, exact field/value fact/index,
native original document, snapshot, candidate and strong pinned action
selection. Loop revalidates the actual stamped request. Only actual
dispatched AND verified operation creates file-private-constructor
immutable receipt with loop UUID. Any subsequent input invalidates it.

Eligible exact readback requires exactly one nonsecure editable native
field, same task/original native document/CF field/fact, complete context
and full value equals actual authorized caller literal in UTF8 bytes.
Chooser asks independent scope/target/literal-intent Noul gates together
in the same existing primary request. Each pinned finite >=.95; no
joint score. Code binds votes to receipt/snapshot/fact, not model IDs.
Available broad completion/support<.3 or malformed is conflicting.
Strong new gates do not fabricate old completion/confidence; general
action uncertainty is an unused branch, never new input permission.
No extra request to obtain a preferred broad answer.

ObservedGoalProof tags basis general or exactReplacement. General
.95/.9/.9 rules unchanged. Exact stores three raw gates and actual
optional broad values separately; general numeric score fields nil,
not invented. Loop fresh native read must validate same full context,
original document, actual CF field, caller bytes and evidence origin
before Done. No actual-operation receipt means no exact basis,
including initially matching/already-satisfied cases. Caller/voice/
preview defaults remain nil; no public MCP/provider/driver change.

### D9a Optional Native Ancestor Roles

User approved `results/P4/jev-native-context-plan.md`; senior51fbb72e
PLAN PASS. Implementation and consumer review are complete: 313 focused
checks pass, fresh6cc7d424 SOURCE PASS. This is not phase acceptance.

Private native observation may retain optional root-to-parent role-only
ancestry on AXElement and native field values, populated during the
existing native walk without additional AX or model calls. This is an
observed chain, not canonical parent identity or an inferred body flag.
No labels, text, paths, tokens, handles, new app setup or permissions.
Clear SDK/previous ancestry on every merge. Only a verified complete
bound native root supplies it; editable fields retain existing unique
field/frame/CF identity mapping, read-only rows originate in that walk.
Unknown, malformed, foreign or secure ancestry remains nil.

Expose ancestry only as UI evidence in existing fact JSON. Include it
in Node/Context equality so post-judgment hierarchy changes invalidate
fresh proof. Preserve nil/default callers, all D9 gates, receipts,
original document/field identity, literal equality and readback.
No question, provider, action filter, threshold or public MCP change.
Do not move intent judgments before execution. Information loss is
confirmed in source; causal improvement requires signed evidence.

Consumers re-reviewed: native collect/merge, AXElement and
AXSnapshot conversions, fact/context, chooser/decider, TaskLoop proof
verification, voice, computer-control and read-only preview callers.
The signed pilot succeeds, but the interrupted/resumed command set is
2/3 strict for both retained baseline and candidate, with exact native
values in all six. No reliability gain is established. P4 stays FAIL/open.
# CONTRACTS — frozen interfaces (v0)

These are the seams between phases. They are **specifications of target
shapes**, not descriptions of current code — several have no
implementation yet (their owning phase creates it). Once a consumer
lands, changing a contract requires a Decision Log entry in the changing
phase **and** re-review of every consumer. Version tags ride inside each
shape so old fixtures fail loudly, not silently.

| Contract | Owning phase | Consumers | Status |
|---|---|---|---|
| `Decider` protocol | P4 (TaskLoop) | P5 RecoveryDecider (previously planned SolDecider), P7 BrowserDecider, P9 skills | v0 |
| `CaptureSource` | P4 | P5, P7, P8 gaze hints | v0 |
| Realtime tool schemas | P3 | P5, P6, P7 executors; P11 resolved-target hint | v1 (P3 G1 contract approved; implementation pending) |
| `ScriptIntent` registry | P6 | P3 tool schema, P10 onboarding copy | v0 |
| `BrowserDriver` protocol | P7 | P5 fallback, P9 skills | v0 |
| `SkillProgram` JSON | P9 | P12 packaging (bundle format) | v0 |
| Bench task JSON | P1 | every phase's G5 slice, P13 release gate | v0 |
| `LatencyLedger` span names | P0 (existing) | all phases' G5 budgets | frozen |

---

## 1. `Decider` protocol (Swift)

P3 semantic-assist amendment (user-approved, instruction-as-consent for app focus): final
unrecognized requests use TypeSafe (enabled by default, with an opt-out) to
select a bounded app-focus proposal over observed identities. This grants no execution authority.
Existing local routes/refusals/asks are not overridden. Code retains current
turn ownership, uses one joint observed-app Choice, validates target
freshness before typed app-focus execution. No arbitrary generated goals,
coordinates or uncalibrated automatic mode. Public realtime tools remain v1.
The explicit low-risk focus instruction is consent; no duplicate approval ask
is parked. Uncertain targets clarify rather than ask permission again.
Binding details: `.agent/results/P3/semantic-contract.md`; future consumers
must not treat a semantic prediction/confidence as a permission token.

P3 explicit focus syntax (G2 `84eee5d7`): an explicit `switch to` or
`bring ... to front` frame may resolve one trailing `s` only when its
base exactly names one observed, locally openable app identity. Existing
exact and whole-token matches, including ambiguity, take priority.
No bare-name expansion, phonetic/subsequence/bundle match, per-app alias,
literal rewrite or ASR hint is granted. Captured asks, multi-target
requests and negation do not gain this syntax. Raw finals stay unchanged;
admission and execution share the same captured-context interpretation.
No realtime schema, target authority or future-phase interface changes.

P3 captured-window binding (Decision 30): the internal voice task factory
carries optional pinnedWindowID. Current normal local type/hotkey/scroll
commands forward the released turn's captured window; app-open, remote,
stale and cancelled admissions do not infer a pin. The packaged audit also
rechecks its owned AXDocument/text area and requires consistency with any
captured pin. Focused typing retains native field/window identity for queued
dispatch, not atomic Fn-down field capture. This adds no model-controlled
argument or public realtime schema. Diagnostic cancellation uses the
capture-only seam and explicit owned work, not global stop.

One `TaskLoop` drives all UI automation; a `Decider` is the brain it
calls once per observe→decide round. Implemented by `JevDecider`
(AX-first, progress-driven rounds), planned `RecoveryDecider`
(Terra API; legacy planned name SolDecider), and
`BrowserDecider` (DOM-first). The loop — never the decider — owns
actuation, settle, budgets, and consent routing.

```swift
/// What the loop hands the decider each round.
struct TaskObservation: Sendable {
    var stepIndex: Int                    // 0-based round number
    var axSnapshot: AXSnapshot?           // nil when degraded
    var domSnapshot: DOMSnapshot?         // browsers only; nil elsewhere
    var screenshot: CapturedImage?        // nil unless the decider asked
    var task: TaskBrief                   // goal, constraints, gaze hint
    var history: [RoundRecord]            // prior picks + settle results
    var budget: RoundBudget               // rounds/ms remaining
}

struct RoundBudget: Sendable {
    var roundsRemaining: Int?             // nil = no round ceiling
    var millisecondsRemaining: Int?
}

/// What the decider returns — exactly one of these per round.
enum DecideResult: Sendable {
    case act(ActuationRequest)            // loop executes + settles
    case askUser(question: String, choices: [String])
    case escalate(reason: EscalationReason) // Jev→Sol / DOM→pixels
    case done(summary: String)            // only after verify_state
    case blocked(reason: BlockedReason)   // consent, deny-list, safety
}

protocol Decider: Sendable {
    /// Pixels are opt-in: the loop captures only when this returns true.
    var wantsScreenshot: Bool { get }
    func nextStep(_ observation: TaskObservation) async throws -> DecideResult
}

enum EscalationReason: String, Sendable {
    case lowConfidenceTwice, staleScreen, invalidChoice,
         degradedAX, roundBudgetExhausted, wallBudgetExhausted, domCannotGround
}
```

Rules for implementers: `done` is a claim the loop must be able to
verify — a decider that reports `done` without a preceding successful
`verify_state` settle is a defect (see "zero false Done" bar). Deciders
never execute actions themselves.

## 2. `CaptureSource`

The single seam for observing the screen. Backed by the pinned Cua
driver in production; fakes satisfy the same protocol in tests.

```swift
protocol CaptureSource: Sendable {
    func frontmostWindow() async throws -> WindowRef
    func axTree(of window: WindowRef,
                depth: AXDepth) async throws -> AXSnapshot
    /// Expensive — call only when the acting decider set wantsScreenshot.
    /// One capture per step; the loop reuses it for verify_state.
    func screenshot(of window: WindowRef?,
                    region: CGRect?) async throws -> CapturedImage
    func domSnapshot(of window: WindowRef) async throws -> DOMSnapshot // browsers
    /// Screen is quiet long enough to trust the observation.
    func settled(within timeout: Duration) async -> Bool
}
```

Screenshot policy is contractual: realtime voice never receives pixels;
a `Decider` gets at most one capture per step, reused for
pre/post-settle comparison.

## 3. Realtime tool schemas v1 (voice → executors)

The realtime session advertises exactly these tools. `response.create`
is gated on local miss (P3). Schemas are terse — token cost is latency.
P3's G1-approved v1 amendment is specified completely in
`.agent/results/P3/implementation-contract.md` sections 3-4. Catalog
version is a local constant/context note, not a new vendor API field.
Every object rejects unknown fields. Strings <=4000 UTF-8 bytes;
identities/names <=200, summary <=300; maps/arrays <=16 elements.
UUIDs, integer ranges and enums are validated before executor admission.

| Tool | Purpose | Params (JSON Schema) |
|---|---|---|
| `run_script` | Deterministic app action, T1 lane | `{ "intent": string ∈ ScriptIntent.ids, "args": { string: string } }` |
| `browser_task` | Web task in a logged-in tab, TB lane | `{ "goal": string, "browser": "chrome"|"safari"|"frontmost" }` |
| `computer_task` | Multi-step UI task, T3/T4 lanes | `{ "goal": string, "app_hint"?: string, "gaze_target"?: {"target_id": string, "window_id"?: nonnegative_int} }` |
| `ask_about_screen` | Question about what's visible | `{ "question": string, "scope"?: "window"|"screen" }` |
| `web_lookup` | Factual lookup, no actuation | `{ "query": string }` |
| `inbox_brief` | Morning/day brief, T1 | `{ "span"?: "morning"|"day"|"unread" }` |
| `delegate_to_agent` | Existing or explicitly created roster agent | `{ "task": string, "agent"?: string, "create"?: {"name": string, "role": string, "description"?: string} }` -- exactly one of agent/create |
| `respond_to_task` | Answer one current ask instance | `{ "task_id": UUID_string, "ask_id": UUID_string, "response": string }` |
| `answer` | Direct spoken reply, no action | `{ "text": string }` |

Each tool returns all fields:
`{ "schema_version": 1, "ok": bool,
"status": "accepted"|"completed"|"clarification"|"blocked"|"failed"|"unavailable"|"refused",
"summary": string, "task_id": UUID_string|null, "agent_id": string|null,
"error": string|null }`.
`accepted` is started/admitted, never verified done. Only independent
executor evidence allows action `completed`; direct informational answer
delivery can complete without claiming an external effect. Blocked,
failed, unavailable, refused or clarification results have ok=false.
Async task/agent identities are exposed when available, never invented.
Images are never arguments or results — `ask_about_screen` captures
server-side at call time if the answering lane needs pixels.

P3 capability matrix: computer_task uses existing coordinator admission;
an explicit resolved-target argument returns unavailable:resolved_target
until the P11 resolver/executor binding exists. It is never discarded
and replaced with an unscoped generic goal.
respond_to_task uses exact task+ask nonce and existing explicit consent
policy; delegate_to_agent preserves explicit create/existing-agent
behavior; answer is speech/display only. run_script, browser_task,
ask_about_screen, web_lookup, inbox_brief return named unavailable
capability errors until their approved executors exist. Do not invent
a model endpoint or execute arbitrary args to make a tool appear present.
Typed and spoken requests use the same whole-final authority checks.
Outcome-only model responses never gain executor authority.

P3 reviews this amendment for P5/P6/P7/P11 consumers in its Decision Log.
Resolved gaze IDs belong to the captured turn context; unknown IDs or
raw x/y inputs fail closed. Backend physical actuation coordinates are
not model-facing gaze data.

## 4. `ScriptIntent` registry shape

The deterministic lane's catalog. One registry file
(`Sources/JevVoice/Scripts/` location fixed in P6 ExecPlan); every entry:

```json
{
  "id": "calendar.add_event",
  "title": "Add calendar event",
  "phrases": ["add an event", "schedule ..."],
  "argv": ["scripts/intents/calendar_add_event.swift", "--title", "{title}", "--when", "{when}"],
  "args": { "title": "string", "when": "ISO8601 | natural date" },
  "confirm": "readback",        // "none" | "readback" | "explicit"
  "reversible": true,
  "deny": ["delete", "send", "purchase"]
}
```

`confirm: readback` is mandatory for send/book/delete classes. Argv-only
invocation — no intent reaches a shell string.

## 5. `BrowserDriver` protocol

DOM-first browser control. Three drivers behind it:
`ChromeDevToolsDriver` (CDP via devtools MCP on the real profile),
`SafariAppleEventsDriver` (`do JavaScript`), `CuaBrowserDriver`
(fallback). Selected per task; DOM can't ground → escalate to pixels.

```swift
protocol BrowserDriver: Sendable {
    var name: String { get }                    // "chrome-devtools" etc
    func tabs() async throws -> [BrowserTab]
    func snapshotDOM(tab: BrowserTab,
                     viewportOnly: Bool) async throws -> DOMSnapshot
    /// Indexed elements; actions address elements by their snapshot index.
    func act(tab: BrowserTab, _ action: BrowserAction) async throws
    /// Natural-language answer from the page without shipping pixels.
    func extract(tab: BrowserTab, query: String) async throws -> String
    func screenshot(tab: BrowserTab) async throws -> CapturedImage
    func settled(tab: BrowserTab,
                 within timeout: Duration) async -> Bool
}

struct DOMSnapshot: Sendable {
    var url: String; var title: String
    /// Compact indexed form — Browser-Use style: "[12] <button> Save".
    var indexedText: String
    var elements: [DOMElement]  // index → role, name, bbox, href?
}
enum BrowserAction: Sendable {
    case click(index: Int), type(index: Int, text: String),
         key(String), scroll(dx: Int, dy: Int),
         navigate(url: String), back
}
```

## 6. `SkillProgram` JSON

Compiled from Cua recordings / successful traces. Validation replays it
against a settle-checked dry run before it joins the replay lane.

```json
{
  "version": 1,
  "id": "gmail.archive-thread",
  "name": "Archive the open Gmail thread",
  "trigger": { "phrases": ["archive this"], "apps": ["com.google.Chrome"], "url_glob": "*mail.google.com*" },
  "params": {},
  "steps": [
    { "action": "click", "locator": { "ax_role": "AXButton", "ax_name": "Archive", "dom_index": 12, "point": [812, 340] } }
  ],
  "verify": { "ax_exists": "Toast 'Conversation archived'" },
  "created_from": "recording|trace",
  "stats": { "runs": 0, "successes": 0, "retired": false }
}
```

Locator is a fallback chain: semantic (AX/DOM) first, point last. A
skill auto-retires after consecutive failures (threshold set in P9).

## 7. Bench task JSON

The bench corpus. Every hero job and every release bar maps to tasks of
this shape:

```json
{
  "id": "inbox.read-latest",
  "hero_job": "inbox",
  "prompt": "Read me my latest email",
  "app": "Mail",
  "inject": "mcp_stdio",
  "requires": "test-user",
  "setup": "bench/reset/inbox.sh",
  "success": { "kind": "ax_state", "expect": { "app": "Mail", "check": "running" } },
  "budget": { "p50_ms": 4000, "tier": "T3" },
  "tags": ["one-shot"],
  "runs": 5
}
```

Field semantics (amended — D3):

- `inject` (default `"mcp_stdio"`) — how the prompt reaches the app; the
  only supported value is `"mcp_stdio"` (`drive_until` over the app's
  `--mcp-stdio` surface, `goal`=prompt, `app`=hint). New injectors are a
  contract revision.
- `requires` — `"local-safe" | "test-user" | "human"`: which account the
  task may run in. `local-safe` never names a mutating app; `human`
  tasks are recorded for coverage and never injected.
- `app` (optional) — app hint passed as `drive_until`'s `app` argument.
- `setup` (optional) — script that restores the environment (no real
  Mail/Messages mutations leak).
- `success.kind` is a closed set —
  `speaks_substring | file_state | ax_state | app_frontmost |
  dom_state`; new kinds need a contract revision. Expect shapes:
  - `speaks_substring`: `{ "text": "<substring>" }` — case-insensitive
    substring of the result text.
  - `file_state`: `{ "path": "...", "must": "exists|contains|absent",
    "text": "..." }` (`text` required only for `contains`).
  - `ax_state`: `{ "app": "...", "check": "running|not_running|
    frontmost" }` or `{ "app": "...", "queries": ["<AX get-expression>",
    ...], "contains": "<substr>" }` — System Events, queries tried in
    order.
  - `app_frontmost`: `{ "app": "..." }` — frontmost process name equals.
  - `dom_state`: `{ "browser": "Safari" | "Google Chrome",
    "text": "..." }` — front window URL contains text.

## 8. `LatencyLedger` span names (frozen — append-only)

Existing span keys (`Sources/JevVoice/Support/LatencyLedger.swift`,
`spanKeys`) are frozen; new keys are appended, never renamed or
repurposed.

Existing: `fn_hold_ms`, `release_to_commit_ms`, `commit_to_transcript_ms`,
`transcript_to_dispatch_ms`, `dispatch_to_effect_ms`,
`eyes_land_to_effect_ms`, `fn_to_effect_ms`, `round_decide_ms`,
`round_dispatch_ms`.

Marks: `fnDown`, `fnRelease`, `commit`, `transcriptFinal`, `dispatch`,
`effect`, `eyesLand`. Origins: `hold`, `typed`, `gaze`, `task`.

Reserved for P4/P5 per-step spans (the loop writes these; names claim
the namespace now so reports never collide): `step_observe_ms`,
`step_model_ms`, `step_act_ms`, `step_settle_ms`, `step_output_tokens`.

## Decision Log: P3 Physical Front Door (2026-11-06)

The user approves qualifying the normal Fn/pill app rather than the
isolated local CLI. G2 independent review `1cd10ec1` returns PASS.
The amendment in `.agent/results/P3/implementation-contract.md` preserves
the 27-hold population, local-autonomy score, safety and latency bars;
semantic recovery and final task success are measured separately.
The new physical artifact is a bound `normal_app_voice_physical` report,
referenced by `normal-live.json`. Historical CLI/typed artifacts cannot
satisfy it. Consumers changed/re-reviewed at G4: P3 verifier, its private
protocol/report modules and P3 acceptance/phase documents. No nine-tool
schema, frozen span, public product default or P4 implementation changes.

## Decision Log: P3 Native Literal Insertion (2026-11-06)

The user requests dictation-like typing speed without losing safeguards.
G2 reviewer `9ba67dd7` approves the retained-field native insertion contract
in `normal-voice-qualification/SPEED-CLOSEOUT.md`. Append internal trace stages
`nativeTextInsertionBegin`, `nativeTextInsertionEnd`, `nativeTextInsertionFailed`;
record actual platform issuance/return uptime, Work and turn identity.
Keep `dispatches` driver-only; append `native_text_insertions` and include
actual native attempts in the aggregate known-mutation count. No existing
LatencyLedger name, nine-tool schema or P4 interface changes.
G4 re-reviews every producer/consumer: retained target, direct literal loop,
coordinator/controller, command trace, turn recorder, witness classifier,
private scorer, signed audit and focused tests. Never call a native attempt
a driver receipt or retry an attempted/uncertain setter through the SDK.

G2 amendment reviewer `9ba67dd7` approves replacing only the direct native
captured-literal inventory read with fresh native focused field/window plus
independent CoreGraphics on-screen exact-owner proof. The retained window's
actual AX title still enters the same deny corpus. Native metadata is an
internal observation, never a driver response/span. Unknown evidence uses
the existing SDK inventory and the same retained field, not a recaptured
replacement. Browser, named/display/deictic targets and other actions retain
the original observation path. Public schema and span names do not change.

## Decision Log: P3 Independent Foreground Sampling (2026-11-07)

G2 senior review `7ca2002d` passes the narrow observer repair contract.
WindowServer IPC inside CGWindowListCopyWindowInfo blocks the existing
25 ms sampling queue in real signed-app profiles. Append a private
`foreground` witness kind containing fresh actual PID, bundle and uptime,
not a visible-window assertion. Keep one bounded independent window query
in flight; full window rows retain actual completion timestamps and require
coherent foreground identity around the query. Never reuse cached windows
or manufacture periodic timestamps. Stop drains both producers then the
existing writer, with all current capacity limits unchanged.

The private scorer includes foreground rows for continuity and wrong-app
history, but only complete `window` rows can prove an effect. The existing
200 ms gap, post-settlement observation, exact window owner/dimensions,
lineage and safety rules remain. Re-review the observer, private scorer,
report loader, their tests and verification wiring at G4. No public tool,
span, typing, ASR, policy, tracker or P4 interface changes.

## Decision Log: P3 Native Restore Evidence (2026-11-07)

G2 review `3fa3df6b` passes the private restore-trace repair. One real normal
Fn task completed in Calculator, but unhideApp and activateRestoredApp
emitted indistinguishable native activation spans. Preserve that old
ambiguous qualification failure rather than relabeling it.

Private witness protocol version 3 distinguishes nativeUnhideBegin/End/Failed.
Native calls and their safety/lease/cancellation behavior remain unchanged.
The scorer counts unhide at issuance, permits one ordered unhide/activation
pair, and still rejects repeated kinds, reversed order, unknown/foreign
mutations, and actuation in controls. Fresh physical verification rejects
legacy witness versions. Re-review all trace consumers and tests at G4.
No public nine-tool, driver receipt, ASR, policy, typing, tracker, or P4
contract changes. The detailed private contract is
`results/P3/normal-voice-qualification/NATIVE-RESTORE-TRACE-CONTRACT.md`.

## Decision Log: P4 Jev Judgment Repair (2026-11-08)

The frozen Decider/TaskLoop, consent, CaptureSource and nine-tool shapes
are unchanged. Internal JevChoice metadata and the Core readDistribution
API are additive; readDetailed remains unchanged for the P3 semantic
router. No voice/ASR or provider-routing contract is changed.

The production verifiedOrAlreadySatisfied policy now labels a verified
effect-free goal rather than bypassing verification. Both done policies
require verified settle plus CURRENT declared goal evidence. Empty or
blank criteria and screen quietness cannot prove completion. Decider and
loop use the same AX/markdown evidence checker. Known explicit
postconditions bypass inference but still request the loop's verifyState.

Consumer audit: DriveLoop forwards its existing successContains,
preserves captured authority and default four-round budget; browser
actuation fixtures now check actual goal evidence and reject unverified
DOM-event completion; TaskLoop/session tests prove both already and done
with evidence. Full Swift and tracker lane is green (see P4 report).
P5/P7 deciders must supply meaningful postconditions or stop honestly;
they may not restore acknowledgement-only or quiet-screen completion.
Fresh independent G4 review is still pending; this is not its verdict.

## Decision Log: P4 Observed Goal Verification (2026-11-08)

User G1 explicitly selected "Approve observed proof"; senior d3665964
revised G2 verdict PASS. This amendment extends the literal-only rule
above. Absence of declared criteria is never itself proof. Supplied
criteria, including invalid/blank ones, cannot be overridden.

`ActuationRequest` gains the additive internal field
`verification: ObservedGoalProof? = nil`. `DecideResult.done` is unchanged.
ObservedGoalProof binds exact task, captured WindowRef, source snapshotID,
typed normalized full observed context, an actual safe fact's identity,
model identity and three probabilities. No model-authored text, predicate,
scope, permission or executable code is accepted.

Only the pinned Jev path may opt in. Model completion must be >=.95,
observed fact selection >=.9 and a single targeted support Noul >=.9.
This fits the existing two requests per observation. Explicit predicates
retain the existing code-only fast path and thresholds.

TaskLoop exposes the actually bound window in the observation task.
Semantic verifyState always performs a fresh same-window AX read even
when ordinary settleReobserves=false. Require exact typed equality of
safe window title and every captured element's index, role, label, value,
bounds and actions, excluding only ephemeral snapshot IDs/tokens.
Secure data is masked; available button/link labels cannot be outcome
facts. Proof membership, source snapshot, task, scope and probability
floors are code-checked. Done rechecks the CURRENT context and fact.
Any subject/account/document/window/context drift invalidates proof.
Unrelated ticking UI also invalidates it: conservative failure requires
a new judgment or caller-owned predicate, not a silent weaker match.
No previous-effect or quiet-screen shortcut is restored.

Preview may expose fact candidates and an unverified suggestion only;
it cannot mint usable task completion outside TaskLoop. P5/P7/P9 remain
literal-predicate/nil-verification consumers until separately reviewed.
Consumer audit required: TaskLoop, JevDecider, JevChooser,
DriveCandidates, DriveLoop/preview and CaptureSource read transports.
No public MCP/nine-tool, mutation, consent, literal or driver-pin change.
Fresh source review and native proof remain required; this is not G4/G5.

## Decision Log: P4 Contextual Jev Next Actions (2026-11-08)

User approved additional unlimited synthetic Jev requests, contextual
multi-step next-action selection, one read-only repair reviewer, and
installation after validation/review. The exhausted 30-call grant stays
unchanged. New grant has separate finite batch accounting.

No frozen TaskLoop, CaptureSource, consent, nine-tool, P3 voice/ASR or
planner-provider shape changes. Four TaskLoop rounds remain locked.
JevChoice has additive request/evidence metadata. readDistribution has
a source-compatible default-true unique-winner parameter; only the
primary contextual chooser requests tie inspection for refinement.
readDetailed and the strict default still protect existing consumers.

Choice can name the next unfinished step in a familiar sequence, not
only an action that finishes the whole goal. A separate text-entry Noul
routes typing versus focusing; literal text stays code-owned. Text
actions include focus; focus alone cannot replace an entry instruction.
Field values no longer contaminate the field-name literal lookup.
The unchanged label+value policy corpus still reaches deny/consent gates.

At most one focused follow-up request per observation, <=3 candidates.
It must return valid exact-subset probabilities plus specific action
support >=0.9 and satisfy the unchanged original action-set floor.
No blind repeats, voting, confidence averaging or floor reduction.
Primary and refinement evidence are distinct; a deterministic sole
target's 1-of-1 selection is not semantic certainty. Completion still
requires current declared evidence and loop verification.

Consumers reviewed: DriveLoop/JevDecider, DriveCandidates, TaskLoop,
Core selection and existing P3 reader, browser/typing integration tests.
Scoped fresh read-only reviewer `6c3591cc` PASS, full lane green.
This is not a jarvis-judge phase verdict and does not close P4-5/P4-6.
Recorded limitations: three safe synthetic abstentions remain, and
the pre-existing text-hole guard permits only one question per task.

### 2026-11-08: native captured-window observation completeness

Approved integration repair remains inside the existing captured PID/window
authority. Senior G2 d3665964 PASS, including this additive internal shape:
`AXSnapshot.goalContextComplete: Bool = true`. Existing trusted/simulated
sources retain their defaults; production DriveCaptureSource always uses the
native display reader and sets false on unavailable, timeout, partial walk,
identity mismatch, cancellation or truncated context. Valid driver controls
may still guide actions, but ObservedGoalProof creation, fresh verification
and final current-evidence checks must all require complete context.
Native read injection is a trusted test seam only, never MCP input. No
public RPC schema, driver pin, mutation authority or P5/P7/P9 opt-in changes.
TaskLoop, DriveCaptureSource/preview, JevDecider, DriveCandidates and
ObservedGoalProof are the consumers reviewed for this addition.

### 2026-11-08: observed post-action progress is not completion

Native desktop proof reproduced the eight-round idle guard stopping a
changing wizard: ordinary pinned-driver AX clicks correctly return
unverifiable, not confirmed. G2 d3665964 PASS for additive internal
TaskLoop.Config.observedPostActionProgress=false. DriveLoop alone opts in.
Only a fresh changed typed snapshot of the same bound WindowRef immediately
after this loop's actual dispatch resets idle accounting. It never adds
verifiedEffects, verified settles or completion evidence. Unchanged-screen,
cancellation, wall/explicit-round limits and all permission gates remain.
P5/P7/P9 do not opt in. AlreadySatisfied means no actuation in this run,
not merely no driver-confirmed effects; final goal verification is unchanged.
Consumers reviewed: TaskLoop, DriveLoop, JevDecider, existing done policies,
progress/stale guards and DriveLoop regression fixtures. Original frozen
desktop workload/results remain preserved; verifier corrections are separate.

The same consumer review approved internal `ActOutcome.dispatched=true`.
The trusted adapter explicitly marks known skipped/stale admissions,
read-only clipboard and context-only tab selection false. History records
this fact instead of assuming every adapter return mutated the UI.
Verified effects still require both dispatched and verified; verified
settles retain their existing meaning. DriveResult.dispatchedEffect keeps
its existing verified-effects meaning and is not inflated by this repair.

### 2026-11-08: focused observed-goal uncertainty refinement

Native goal-only trace dce5 reproduced under-claim after successful Finish:
complete native context, four terminal facts, zero reader failures, but
broad completion probability .48/.38 and no applicable action. Existing
fact support was unreachable below .95. G2 d3665964 PASS for an eligible
goal-only evidence refinement, not a lower threshold or repeated vote.
Keep the high-primary path unchanged. For complete bound observed context
with actual facts and uncertain completion/no applicable action, judge
each fact and whole-goal completion independently on full observed subject
context without next-action choices. Require final completion >=.95,
selected support >=.9, and actual unique fact Choice probability >=.9.
Reuse a qualified original fact Choice or ask a new Choice over every
supported fact plus none; never invent a deterministic certainty.
Fresh same-window unchanged-context proof verification remains mandatory.
Internal JevChoice adds optional primaryCompletionProbability and
refinedCompletionProbability; completionProbability changes to refined
only on qualified proof. Preserve request counts/latency across failed
goal refinement and any later action refinement. Consumers reviewed:
JevChooser, JevDecider, ObservedGoalProof, preview and live recorders.
No explicit-criteria opt-in, partial context, new tools, permissions,
policy change, slower planner or P5/P7/P9 opt-in.
G4 found a pre-existing alias drift gap in the high-primary path:
support must match the first actual response model, not the configured
alias. New high/low-alias checks precede the fix; high check reproduced
false proof before correction (jev-alias-drift-before.log).

## Decision Log: P4 Exact Agent Window Target (2026-11-09)

User explicitly approved Add Exact-Window Scope in the real-app
qualification session. This overrides the earlier no-new-target-pins
restriction only for an optional window_id in drive_until/suggest_action.
The ID narrows the existing requested app; it cannot name a PID, mint
element authority, widen permission, bypass consent or substitute a sibling
window. Decode positive exact UInt32 window identities only. Existing
callers remain unchanged.

Explicit MCP window tasks fail closed before effects when the app/window
is missing or ownership disagrees. Preview honors the same exact window.
Global media/clipboard and app-wide fast paths cannot escape this scope.
Native traffic lights resolve and press the exact AXWindow, not the
app's focused sibling. Existing injected test callbacks remain trusted.
Semantic completion keeps the existing same-window, full-context and
probability checks. No new tool name, provider, driver pin or threshold.

Consumer review: shared MCP schema/decoder, DriveLoop run/preview,
candidate generation/extras, host WindowControls, TaskLoop window stamping
and verification, JevDecider. Public DriveTask/TaskBrief/Decider interfaces
remain unchanged. Fresh G4 review/native proof remain pending.

## Decision Log: Experimental Jev Window Images (2026-11-09)

User approved the general AX-plus-image fallback and independent G2/G4
reviews. G2 b0eba62d final PASS, no findings; approved plan and record:
`.agent/results/P4/jev-vision-plan.md`, `jev-vision-g2-review.md`.

Permit default-preserving typed Box/assets transport and combined,
exact-window AX/image observation. Text requests omit assets and the
image opt-in header. Images are requested only when the acting decider
needs them, never sent to realtime, and never whole-desktop captures.
Do not revive the removed perception lane or add app-enablement recipes.

Box edges must be finite, normalized, ordered and nondegenerate.
Nullable confidence stays unknown, not fabricated certainty. Presence,
location, authorization and completion are distinct. Preserve all
literal, deny, consent, cancellation and exact-window authority.
Visual input requires the original read-transport capture_id unchanged
on the act transport, with matching task/window/session/generation and
validated coordinate transform. Missing/stale/foreign captures refuse.

Fresh visual outcome proof cannot be replaced by a click, offered
control, quiet screen, animation or generic image-hash difference.
Existing exact-text/file/AX oracles are not weakened. Images do not
prove hidden backend outcomes. Public tools and gaze targeting remain
unchanged. No default round ceiling, slower per-action model, lower
threshold, driver upgrade, new grant or automatic installation.

Consumers: Core model/client/selection, TaskLoop/CaptureSource/Decider,
JevChooser/JevDecider, DriveLoop run/preview, observed/visual goal proof,
recorders and voice coordinator; future P5/P7 callers retain default
behavior. Implementation and fresh G4/G5 proof remain required.

### P4 Internal Image Evidence Implementation (2026-11-09)

Under the approved image amendment, the additive optional internal fields
are ActuationRequest.visualTarget/visualVerification and
TaskObservation.visualGoal/visualAnchor. TaskLoop's verifyVisual callback
defaults nil, preserving existing callers. This changes no public
drive_until/suggest_action or permission schema.

Image verifyState is a pending claim, not a verified settle. The next
round makes one combined fresh capture; Loop-owned verification requires
a different capture ID/generation, same original task/window/session and
original visual subject anchor. Only a matching verified current frame
may satisfy Done. A failed/uncertain subject check stops the task before
further decisions or input; it cannot rebind the task to new evidence.
Exact bytes and hidden/persisted state still require independent native
oracles. A same-step screenshot is reused, never recaptured for the model.

### P4 Captured Native Accessibility Extension (2026-11-09)

User selected extending the driver, NOT stripping capture_id for a
native-token branch. G1 approved; G2 PASS0360df2a implementation contract
in jev-vision-captured-ax-g2-review.md. Require native accessibility token
and original CID, common-runtime snapshot association and atomic original
session/window/generation/single-use checks; preserve old callers.
Native SDK/generated/platform consumers must be re-reviewed and verified.
App scoped transport carries actual wire public label/socket/proxy UUID
and observed per-label lifecycle epoch; start/end attempts invalidate
captured scope. Raw scoped mutation never rebinds/retries. Optional
VisualProgressProof/record visualCaptureID gives idle credit only for
actual prior action + fresh meaningful same-subject evidence, never Done.
Default nil preserves future callers; signed-bundle image opt-in defaults
off. These implementation fields require fresh consumer G4, not acceptance.

Re-review all consumers listed above, including the new typed goal proof
and Loop callback lifecycle. Focused G3 is green; fresh G4/G5 and
production wiring remain pending. This entry neither enables the
experimental path nor changes phase acceptance or the installed driver.

### P4 Native Value Evidence Amendment (2026-11-10, G1 Approved)

User selected Approve Full Plan for
results/P4/jev-exact-value-goal-plan.md; senior29ea7ac6 PLAN PASS after
required constraints were incorporated. PROGRAM D9. Not implemented.

Provenance first: optional private observation metadata may attest a
complete native entire-field value, actual generic parent-document
association, and a local-only opaque original AXDocument subject anchor
captured before input. No raw document path/id is sent to model/logs.
SDK display strings cannot receive this attestation. Unknown provenance
stays unknown. Existing whole-goal evidence gates remain unchanged.
Try signed pilot/matched evidence with provenance before adding a basis.

Only if this still underclaims, an explicitly tagged exact-replacement
basis may be added. Require an immutable loop-owned actual replacement
receipt, native full-value equality to the actual authorized caller
literal, exact PID/window/field/fact, original document anchor and fresh
context/readback. Same primary batch supplies separate semantic scope,
target and literal-intent gates each >=.95; no manufactured joint/min/
product completion probability. Available broad negative <.3 conflicts.
Reject compound/downstream/insertion/repeat/status/ambiguous/secure/
partial/stale/foreign-model cases. Missing/unprovable original document
anchor disables the new basis. Preserve general proof/initial already
satisfied path. No string-equality-only or unexecuted-candidate shortcut.

Consumers requiring review: AXSnapshot/AXElement, NativeWindowObservation,
DriveCaptureSource, ObservedGoalProof, JevChoice/JevChooser/JevDecider,
TaskLoop capture/verification and computer-control/voice/preview callers.
Default unknown/nil preserves existing callers. Do not weaken focused
dictation binding or steal focus. No public MCP/schema/permissions,
driver/provider/model changes, app recipe, action filtering, default
round ceiling or slower per-action model. Fresh G2/G3/G4 and actual signed
proof required; P4 FAIL/open, installed app unchanged.

## Decision Log: D14 Native Dispatch Pacing (2026-11-11)

G1: user explicitly selected Approve D14 after plan review4b3992f3 PASS.
The reviewed plan is results/P4/jev-native-dispatch-latency-plan.md.
Only the existing native-token default TaskLoop actuation branch may request
the driver's existing post_action_wait=none preference. CuaConnection must
gate it on the exact tool's advertised schema and retain legacy arguments
when unsupported. Only that explicit loop request may trigger session-owned
glide_duration_ms=120 preparation. No shared-default cursor, visibility,
path/style/effects, permissions, Jev heads or thresholds change.

One canonical schema cache per transport generation also owns captured-input
capability discovery. Old captured-input capability state cannot survive a
disconnect/rebind. Preparation is once per owned session epoch/generation,
including definite failed attempts. Definite cosmetic refusal is not a
failed task; uncertain/closed transport cannot authorize input or replay.
Cancellation is checked again before dispatch. Captured/visual, browser,
media, window-control, keys, fast-lane and no-token operations keep their
previous preferences. Fresh observation and independent completion remain
mandatory; deferred window reports are never evidence of no change.

Consumers to re-review: CuaConnection/callScoped, CuaDriveServer transport
binding, VoiceTaskCoordinator/CuaConnectionPool, DriveLoop TaskLoop and
fast-lane/browser/scoped paths. Use existing public driver API only, no
driver-byte change. Production/test ownership extends to CuaConnection.swift
and DriverConnectionTests.swift. First-goal timing includes preparation;
warm pilots are separate and every goal counts. P4-5/P4-6 remain false.

## Decision Log: C1 native primitive support (2026-11-15)

R1-D G2 PASS3241c688. A high operation Choice cannot override low independent
step-validity support for keys, scroll, menus or system operations. The
existing0.9 support bar applies to every offered primitive. The support
question identifies control, window, viewport and system scopes explicitly,
including scroll direction/region. No model, threshold or public DTO changes.
JevChooser, JevDecider, TaskLoop/native/visual consumers require recheck.
Before control: c1-r1-d-before.log has25 failures; pre-D bytes are in
results/P4/c1-r1-d-before-a642ec40. Source/G4 and live acceptance remain
separate; this decision does not change acceptance flags.

## Decision Log: C1 continuous input admission (2026-11-15)

Under approved c1-r2-contract.md, LocalSpeechSession can defer dispatch for a
real recorded utterance. Its default manual path is unchanged. New
VoiceTurnGate.consume spends an admitted local/remote input exactly once;
cancellation and completion invalidate further consumption. This completes
input admission, never claims a task effect. Current conversation epoch,
independent semantic support, fresh target and consequence checks remain
required. Core speech, voice/native/task consumers are rechecked by c1-r2:
c1-r2-semantic-first.log297 executed/5 skipped/0 failures. No acceptance flip.

## Decision Log: C1 bounded native scroll routing

R7 G2 PASS42753e08 approves c1-r7-native-scroll-contract.md. Internal
WindowScrollRequest carries original text, captured application/window,
direction and the existing1/3line amount. It is not a permission or outcome.
ConversationDecision, VoiceController, VoiceTaskCoordinator.Work and
DriveLoop.runWindowScroll preserve and recheck that binding. Generic repeat
does not inherit it. No public DriveTask/MCP or TaskLoop proof DTO changes.

WindowOnly admits only a fully parsed single bounded scroll without extra
caller values, postconditions or preceding user context. It retains original
pin/consent/deny checks and requires a unique observed owner/window row.
Natural scrolls additionally require independent whole-goal support alongside
existing semantic gates. Nonbounded goals remain intact in the generic path.
Native viewport identity, region, freshness, direction and stable independent
readback still decide completion. Cancellation is checked after asynchronous
authorization; an uncertain action is never retried through a generic loop.

Consumers: DriveLoop/FastLaneExecutor, CuaDriveServer windowOnly caller,
VoiceSemanticRouter/ConversationDecision, VoiceController/ConversationSession,
VoiceTaskCoordinator, native/gaze/continuation and existing chooser/task tests.
G3/G4 and exact signed-app proof remain pending. The live before semantic probe
also exposed existing question-meaning gaps; those need a separate bounded
repair, not lower thresholds. No acceptance flag changes.

## Decision Log: C1 R7 conversation amendment

c1-r7-conversation-amendment.md received G2 PASS42753e08 before production
edits. Two red controls in c1-r7-conversation-before.json reproduced bounded
more becoming ongoing and an end condition entering the continuation branch.

WindowScrollRequest now optionally carries an existing native viewport.
Only code supplies that identity; the semantic reference judgment cannot
construct a viewport. The existing private verified executor receives the
anchor and retains region/document/position/freshness/direction and cancellation
checks. The semantic decoder separates single/ongoing duration, requires the
whole-instruction continuation support, and binds references to current native
memory. All .90 thresholds and execution permissions remain.

Internal Work and DriveLoop.Config carry allowParsedScroll(default true).
Generic conversation.task results set it false, including recursive repeat,
so a full-goal fallback cannot re-enter the legacy text scroll parser. Other
fast lanes retain their existing behavior. Independently interpreted typed
follow-ups retain their current original words through both repeat handlers.
Generic repeat does not inherit typed intent.

Consumers are the same native/conversation/coordinator/Cua paths listed above.
The request factory exposes actual1/3line defaults, describes intended scope
separately from permission, and asks single/ongoing and native-reference
judgments in the existing batch. G3, actual-provider factory/decoder evidence,
fresh G4 and signed real-app proof are pending. No acceptance flag changes.

Two additional before controls (c1-r7-context-before.json/log,2tests/6failed
assertions) exposed extra previousContext and contradictory transcriptHint
being ignored by the typed route. Native requests now reject extra task
context; the coordinator only accepts a duplicate exact transcript hint.
For a typed scroll it builds the bound spec directly, preserving its original
words and optional native anchor, and omits generic gaze/text-routing context.
It does not reclassify that interpreted instruction through the lexical cancel
router. The existing native gaze/viewport/target/cancellation checks remain.
The fresh generic and ongoing paths retain their existing context handling.

### 2026-11-16 C1 R8 native controls and default conversation

User authorization: C1 completion plus the later explicit always-on, native
routine-control and natural-language direction. G2 b30bbce0 PASS against
`results/P4/c1-r8-native-first-contract.md`; no release acceptance is implied.
No public MCP DTO, provider/driver/model pin or consent policy changes.

Native scrolling requires a freshly observed viewport before input. The native
adapter discovers supported scrollbar actions or validated increment/decrement
buttons, including the platform's named arrow subroles. It never guesses child
indices. Unsupported-before-input, sent and uncertain-after-attempt are separate
outcomes. Only unsupported-before-input may reach the existing bound driver
route; targetless input is removed. Independent viewport readback still owns
success, including continuity, document, direction, freshness and edge checks.

ConversationSession assembles a full utterance, applies existing risk policy,
then attempts local admission before semantic interpretation. This uses the same
epoch, captured scope, pending-question identity and consumed admission as the
semantic path. Unknown/constrained wording keeps its original goal through Jev;
semantic task fallback still cannot re-enter the old scroll parser. Local
follow-ups require a verified native subject, and bounded movement differs from
ongoing scrolling. Speech onset cancels the owned repeating foreground scroll
while preserving incoming audio and the verified reference.

Hands-free defaults on only when its preference is absent; explicit off and
pause remain authoritative. Startup readiness/permission failures remain visible.
Pause survives relaunch and prevents background microphone preparation.
Consumer paths: Config, VoiceController, ConversationSession, existing optional
Fn flow, onboarding and their existing suites. General dialogue, streaming ASR
and multilingual end-to-end qualification remain required broader work.

The exact existing ConversationVAD runtime manifest/hash and validator are
promoted into scripts/bundle-conversation-vad.py for canonical staging; C1's
manifest helper imports the same implementation. No asset version changes and
external ASR release blockers remain. Both normal staging and the final-r8
candidate use it. Native/voice G3, G4, signed real-app and physical acceptance
remain separate gates.

### C1 R10 retained packaging base (2026-11-17)

The recorded daily app is absent; its historical hash is not evidence it
still exists. G2 reviewer859f3e7e approved
`results/P4/c1-r10-packaging-base-amendment.md` within the existing isolated
candidate authorization. Only explicit final-r10 retained-base staging
may clone the pinned verified R9-2 candidate while the original daily
path is completely absent. Preserve the original daily guard for every
ordinary stage. Never install or restore daily in this path.

Receipts and P12 manifests bind last_verified_candidate role, exact
R9-2 path/executable, pinned base receipt digest, and historical daily
path/hash/missing status. Validate every resource, Info, signature,
entitlement/requirement and source snapshot before/after clone. Existing
native inputs and release2 binary stay frozen; only packaging snapshot
changes. Stage helper, P12 validator/tests and normal-launch consumer
are reviewed together. Artifact/live/human gates still required.
