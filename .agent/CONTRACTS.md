# CONTRACTS — frozen interfaces (v0)

These are the seams between phases. They are **specifications of target
shapes**, not descriptions of current code — several have no
implementation yet (their owning phase creates it). Once a consumer
lands, changing a contract requires a Decision Log entry in the changing
phase **and** re-review of every consumer. Version tags ride inside each
shape so old fixtures fail loudly, not silently.

| Contract | Owning phase | Consumers | Status |
|---|---|---|---|
| `Decider` protocol | P4 (TaskLoop) | P5 SolDecider, P7 BrowserDecider, P9 skills | v0 |
| `CaptureSource` | P4 | P5, P7, P8 gaze hints | v0 |
| Realtime tool schemas | P3 | P5, P6, P7 executors behind the tools | v0 |
| `ScriptIntent` registry | P6 | P3 tool schema, P10 onboarding copy | v0 |
| `BrowserDriver` protocol | P7 | P5 fallback, P9 skills | v0 |
| `SkillProgram` JSON | P9 | P12 packaging (bundle format) | v0 |
| Bench task JSON | P1 | every phase's G5 slice, P13 release gate | v0 |
| `LatencyLedger` span names | P0 (existing) | all phases' G5 budgets | frozen |

---

## 1. `Decider` protocol (Swift)

One `TaskLoop` drives all UI automation; a `Decider` is the brain it
calls once per observe→decide round. Implemented by `JevDecider`
(AX-only, ≤4 rounds), `SolDecider` (pixels, effort ladder), and
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
         degradedAX, roundBudgetExhausted, domCannotGround
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

## 3. Realtime tool schemas (voice → executors)

The realtime session advertises exactly these tools. `response.create`
is gated on local miss (P3). Schemas are terse — token cost is latency.

| Tool | Purpose | Params (JSON Schema) |
|---|---|---|
| `run_script` | Deterministic app action, T1 lane | `{ "intent": string ∈ ScriptIntent.ids, "args": { string: string } }` |
| `browser_task` | Web task in a logged-in tab, TB lane | `{ "goal": string, "browser": "chrome"|"safari"|"frontmost" }` |
| `computer_task` | Multi-step UI task, T3/T4 lanes | `{ "goal": string, "app_hint"?: string, "gaze_target"?: {"x": int, "y": int} }` |
| `ask_about_screen` | Question about what's visible | `{ "question": string, "scope"?: "window"|"screen" }` |
| `web_lookup` | Factual lookup, no actuation | `{ "query": string }` |
| `inbox_brief` | Morning/day brief, T1 | `{ "span"?: "morning"|"day"|"unread" }` |
| `delegate_to_agent` | Hand off to a roster agent | `{ "agent": string, "task": string }` |
| `respond_to_task` | Answer a pending agent ask | `{ "task_id": string, "response": string }` |
| `answer` | Direct spoken reply, no action | `{ "text": string }` |

Each tool returns `{ "ok": bool, "summary": string, "error"?: string }`.
Images are never arguments or results — `ask_about_screen` captures
server-side at call time if the answering lane needs pixels.

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

The bench corpus in the test user. Every hero job and every release bar
maps to tasks of this shape:

```json
{
  "id": "inbox.read-latest",
  "hero_job": "inbox",
  "prompt": "Read me my latest email",
  "setup": "bench/reset/inbox.sh",
  "success": { "kind": "speaks_substring|ax_state|file_state|dom_state", "expect": "..." },
  "budget": { "p50_ms": 500, "tier": "T0" },
  "tags": ["one-shot"],
  "runs": 5
}
```

`setup` is a script that restores the environment (no real Mail/Messages
mutations leak). `success` kinds are closed-set — new kinds need a
contract revision.

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
