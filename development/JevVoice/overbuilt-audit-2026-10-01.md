# Over-built audit — 2026-10-01

Prompted by: "it keeps asking permission, glitches out, too slow, I think it's
over-built. Look at open-source repos, figure out why our system is so
over-built and still not working. Assume nothing we are doing is correct."

Method: compared the stack against three open-source macOS/browser
computer-use systems that people actually run (macos-use/mac-use,
computer-use-mcp, cua-agent, browser-use), then measured our loop's real call
and question inventory against them.

## Verdict

The architecture inverts the correct split. We give a **small structured-choice
model** (Jev, a System One judgment model) the job a VLM agent is for —
per-step UI action selection — then wrap it in a hand-built verification
fortress (5,376 lines of ComputerControl; `CuaTaskAgent.swift` alone is 1,922
lines) to compensate. Every compensating layer adds model calls, driver calls,
and prompts — which is exactly where the slowness, the glitches, and the
permission spam come from.

The open-source systems work because they make the *opposite* choice in every
case: one capable model call per step, tools that return verification in their
response, and safety enforced by tool design instead of model judges.

## What the reference systems actually do

| | Ours | macos-use / mac-use / computer-use-mcp | cua-agent (upstream Cua) | browser-use |
|---|---|---|---|---|
| Model calls per action | **2** (choose + risk/windowEffect/repeatIntent) + 14–20-question `decide()` per utterance | **1** — the client LLM calls tools directly | **1** — `predict_step()` returns tool calls | **1** — one AgentOutput per step |
| Verification | Separate postcondition + re-match calls + `doneEvidence` judge | Tool **returns the AX tree diff** — dispatch IS verification | Next iteration's screenshot | Next step's state summary |
| DOM size control | Projection bolted on after max_tokens crashes | n/a (AX only) | n/a | **DOM distilled to ~150 ranked nodes before the model sees it** (~95% token cut, enforced upstream) |
| Risk safety | Jev judges risk tier per action + human confirm | Tool surface is the boundary (no send/delete tools exist) + client approval + InputGuard + Esc | Model's own tool choice + `safety_check` callback | Agent-level guardrails, not per-step judges |
| Focus stealing | `invoke_menu` needs focus → prompt per action | **Background-safe input ladder** (AX action → per-window → per-PID event) — never steals focus, so never asks | Same | n/a |
| Code size | ~9,161 lines Sources; ComputerControl 5,376 | one Swift MCP binary | agent.py + loop adapters | service.py + DOM pipeline |

The pattern is unmistakable: in every working system, **the dispatch response
carries the evidence** and **the tool boundary carries the safety**. We built
both as separate model-judged layers.

## Measured cost of one action in our loop

For a single click ("Press AXButton New Tab"), the loop runs:

- **decide()**: 1 Jev call answering **~14–20 questions** (operation, task,
  relationship, app, scope, visibility, contentMode, correctionMode,
  clarification, pendingQuestion, + span/literal/replacement boundary
  questions with group/offset variants) — answered *independently* then
  composed in code, which is where the clarify-deadlock and literal-clobbering
  bugs lived.
- **Per loop iteration**: `list_windows` + `get_window_state` (+`get_browser_state`,
  `browser_dialog` when bound) → **choose** (1 Jev call over a paged catalog)
  → **risk judge** (1 Jev call, up to 3 questions) → **re-match**
  (`list_windows` + `get_window_state` + browser re-observe) → dispatch →
  **postcondition** (`get_window_state`).
- Total for one click: **~2–3 Jev calls + ~8–12 driver calls**, all serial.
  Each driver call is ~0.3–1.2 s, each Jev call ~200–800 ms → **3–8 s per
  single action** before any model nondeterminism.

And every one of those model calls is a dice roll on jobs Jev is structurally
bad at. Confirmed glitches from live traces this session:

- `windowEffect`: asked to *predict* whether a click makes a window — said a
  tab creates a window → 30-poll spin (fixed by a bound, but the question
  shouldn't exist; reference systems just re-observe).
- `next` on a ~200-element catalog: picked an OCR region labeled "New Tab"
  that was a **tab title** — a tab-switch, not a create — because choosing by
  label text is all a blind structured-choice model can do.
- `doneEvidence`: claimed done on a pre-existing "New Tab" — needed a
  start-state delta injected to stop the false positive.
- `repeatIntent`: dead code under AX churn until effectIdentity was keyed
  semantically — one run dispatched click ×5.
- `browser state`: raw `semantic_v2` snapshots exceed Jev's token limit on any
  real page — we bolted on projections; browser-use never ships raw DOM.

## Why it keeps asking permission — the real inventory

Prompt sources, all reachable in one session:

1. **macOS itself re-prompts on every rebuild.** `make app` signs ad-hoc
   (`Signature=adhoc`, `TeamIdentifier=not set`). Each new binary invalidates
   Accessibility, Screen Recording, and Microphone TCC grants → System
   Settings prompts on *every new build*. This is likely the largest single
   source of "keeps asking" — and it is entirely a packaging problem, not an
   agent problem.
2. Browser DOM consent — now persisted after first approval, but the
   first-run prompt still fires.
3. `invoke_menu` focus — now persisted per-app, first-time per app still fires.
4. Isolated-profile prepare ("open a new isolated Chrome profile") — fires
   whenever a browser lacks a debug endpoint.
5. Risk-tier "confirmation" — per deletion/purchase.
6. `requiresApproval` actions — file upload, JS dialog accept, window frame.
7. Quit-app approval on launch cleanup.
8. `autoExecute` off → every command waits for review.

Reference systems need almost none of this because their tools can't do the
dangerous thing: no send tool exists, input never steals focus, and the MCP
client's native per-tool approval (or none, in trusted setups) covers the
rest. Our prompt volume is a *symptom* — we kept adding prompts where the
tool surface should have carried the boundary.

## The core wrong assumption

`CuaTaskAgent` assumes the per-step decision is unsafe unless three model
judgments and two state re-reads bracket every dispatch. That reads as rigor,
but it's compensation: a System One model choosing among 200 AX elements can't
be trusted, so we re-verify everything around it — and each verification is
*another* model call that can also fail or stall. The result is an agent that
is simultaneously slower and less reliable than the naive version.

The working alternative, demonstrated by everything above: **one decision, one
dispatch, verification in the response**. If the model is wrong, you see it in
the diff — not in a judge's opinion of the diff.

## What to do, ranked

1. **Fast lane for one-shots** (~80% of usage). "Open X" → `launch_app`.
   "New tab in Chrome" → `invoke_menu File→New Tab` or Cmd+T. "Type/say X" →
   `type_text_chars` with the literal span. Zero agent loop, zero risk judge —
   deterministic intent→tool map. Target <2 s.
2. **Thin the agent loop to one model call per step.** Merge choose+risk+
   windowEffect+doneEvidence into a single `predict_step`-style call (or a
   single Jev call with one choice + abstain/done). Drop the re-match pair by
   having dispatch tools return post-state. Cap observation to ~150 elements
   *before* the model.
3. **Kill the decide battery.** 14–20 independent questions composed in code
   is the clarify-deadlock generator. One `operation` + `app` + `literal`
   question, or intent classification in code for the fast lane.
4. **Sign stable.** A stable local signing identity (or signing once and not
   re-signing) stops macOS from invalidating TCC grants every build — the
   actual "keeps asking permission" fix at the OS level.
5. **Safety by tool surface, not by judge.** Remove the per-action risk judge
   for ordinary ops; keep the human gate only where the action itself is
   irreversible (send/delete/purchase), which the current `confirmation` tier
   already handles — but as a *code-level* tool flag, not a model call.
6. **Consider cua-agent or macos-use directly** for the agent loop. Both are
   MIT/open, solve the per-step-loop problem already, and would delete most of
   `ComputerControl` outright. `computer-use-mcp` alone removes the whole
   focus-permission class via its background input ladder.

## Honest residual

Even after this, Jev stays the wrong tool for per-step UI judgment — it's a
bounded structured-choice model, and the reference systems all put a VLM (or a
big LLM with tool-calling) in the loop. A reasoning model doesn't fix it
either (slower). The durable fix is the split: deterministic fast lane + one
call per step in the agent lane, with verification riding the dispatch
response instead of a separate model opinion.

---

## Round 2 — shipped changes and live evidence (2026-10-01)

The audit's top recommendations were implemented and verified the same day.

### 1. Per-action risk judge is now gated, not universal

`CuaTaskAgent.swift` previously asked Jev `risk`/`windowEffect`/`repeatIntent`
on **every** action — a second model call per step for clicks it could not
meaningfully judge. Now the call fires only when one of these holds:

- `scope == create` and the action can produce a top-level window
  (`windowEffect`)
- the effect repeats a driver-confirmed completion (`repeatIntent`)
- the goal/action hits the consequential keyword list
  (`requiresRiskJudgment`: delete, send, purchase, upload, submit, post,
  publish, confirm, move to trash, etc.)

When the call fires at all, `risk` always rides along — one call answers every
pending question, keeping test-mock compatibility.

Deterministic guards that cost zero model calls are unchanged: catalog
`requiresApproval` (upload, JS dialog accept, frame moves, isolated-profile
spawn), exact re-match, terminal stale-target refusal.

**Pinned contract discovered**: three tests assert `decisions == 1` for
literal/replacement extraction ("grouping must remain inside the executor's
first Jev decision"). Splitting `decide()` into a conditional second call was
rejected — it would be *slower* for literal ops and violates the contract.

### 2. Stable code signing — the TCC fix at the OS level

Root cause of "keeps asking permission": `make app` signed **adhoc**
(`Signature=adhoc`, no team ID verified via `codesign -dvv`). Every rebuild
produced a new cdhash → macOS invalidated Accessibility/Screen Recording/Mic
grants → OS-level re-prompts regardless of our UserDefaults standing grants.

Fix: created self-signed cert `Jev Voice Local Dev` (EKU codeSigning,
keyUsage digitalSignature, trusted via
`security add-trusted-cert -r trustRoot -p codeSign`). `Makefile` now prefers
the stable identity, falling back to adhoc only when absent.

Verified: `codesign -dvv "build/Jev Voice.app"` →
`Authority=Jev Voice Local Dev`, `Signature size=1674`.

**Still unproven**: whether TCC persists across the *next* rebuild — needs a
second rebuild→relaunch cycle observed. Confirmed only that the identity is
stable and real (not adhoc).

### 3. Live verification (`testChromeNewTabReproOptIn`, desktop lock)

```
consent prompt seen+approved: false        ← standing grant, silent prepare
browser_prepare ran, get_browser_state ×2
Jev next: Press AXButton New Tab           ← choose call
NO risk/windowEffect call in trace         ← gate worked
click ×1 → tabs 10→11
done: unproven → re-observe → proven       ← evidence gate still honest
status Completed, ~9.9s
```

Prior comparable runs: ~11.2s (with consent prompt), ~8.0s (clean bind).
The removed risk call is a real but modest win; the remaining latency is
driver reads (`list_windows`/`get_window_state` ×6) around dispatch.

### 4. Tests

- Focused (`CuaTaskAgentTests|CuaActionApprovalTests|CuaActionCatalogTests|
  CuaBrowserTests|CuaVoiceControllerTests`): **161/0**
- Full suite: **346/0, 41 skipped** — same count as the pre-change baseline.
- `testActionChoiceUsesFreshCuaObservationAfterTranscriptDecision` updated:
  `decisionCalls` 4→3, asserting the benign path dispatches from the choose
  call alone.
- `testNativeRefreshRejectsButtonWhoseMeaningChangesDuringRiskJudgment`
  renamed scenario moved to `...DuringDecision` — fixture mutation relocated
  from the risk branch (no longer fires for benign "Preview") to the choose
  branch; terminal stale-refusal contract preserved.

### Remaining honest gaps (not done)

- **Driver read amplification** is now the dominant per-step cost
  (`list_windows`+`get_window_state` before/after every dispatch). The
  dispatch response already returns post-state — reading it would delete 2-3
  calls per action. Not yet changed.
- **Fast lane for one-shots** (open X / new tab / type X → direct tool map,
  zero agent loop) — recommended in the audit, not implemented. Would cut
  the common case from ~9s to <2s.
- **OCR still a first-class loop branch** — audit recommended fallback-only.
- **`decide()` battery** (~14-20 questions per utterance) — kept single-call
  by contract; a different grouping question could reduce it later.

---

## Implementation round 2 — the three deferred items, shipped

2026-10-01, follow-up to the audit's "deliberately not done" list. All three
landed; one assumption in the audit turned out to be wrong and is corrected
below with evidence.

### 1. Fast lane — deterministic primitives, zero model calls

New file `Sources/JevVoice/ComputerControl/CuaFastLane.swift` (~330 lines)
implements the open-source shape — browser-use `initial_actions`, macos-use
direct tools, cua-agent plain tool calls: a request that *is* one known
primitive executes as a single tool call whose observed delta is the
evidence.

- Whole-phrase table only: `new tab`/`reopen closed tab`/`new window`/
  `next|previous tab`/`go back|forward`/`reload`/`hard reload`/`zoom`/
  `focus the address bar`, plus `type <payload>` with case/punctuation-exact
  payload preservation. Anything conversational, negated, multi-step,
  truncated, or carrying a destination preposition (`type X into this
  document`) falls through to the agent loop — nothing fuzzy.
- Keystrokes dispatch as `hotkey` with a **window-scoped target**
  (`{kind: window, pid, window_id}`) — the macos-use background-input
  primitive. Verified live on real Chrome: `delivery: background`,
  zero focus steal, tab created and selected.
- `type X` dispatches `type_text` **element-scoped** to the window's *single*
  unambiguous editable element (unique `AXTextArea/AXTextField/AXComboBox/
  AXSearchField/AXSecureTextField` with a token). Multiple fields → falls
  through to the agent loop which owns disambiguation. Destination
  prepositions inside the payload (`type X into Y`) → falls through — field
  selection is a targeting decision, not a guess.
- App resolution is deterministic: explicit qualifier (`in chrome`) →
  unique name/bundle match; unqualified keystroke → frontmost tabbable app
  else uniquely-running tabbable app; unqualified `type` → frontmost app.
  A stated qualifier that does not resolve to the chosen bundle fails the
  whole match — the loop owns it (`match(goal:bundle:appName:)`).
- Wired at two points in `CuaTaskAgent.swift`:
  - `decide()` intercept (~line 343): a **final** pending span that is
    exactly one primitive returns the same execute-decision the battery
    would produce — zero Jev calls. Non-final spans still hit the battery
    (a growing utterance may extend into a different request).
  - `run()` (~line 857): `CuaFastAction.match(goal:bundle:appName:)` gates
    the dispatch; `runFastLane` (~line 1881) executes it. Also keeps a fast
    browser command on the user's real profile — it bypasses the
    isolated-browser preparation branch.
- `runFastLane` returns `String?`: nil = nothing dispatched, agent loop
  owns it (no usable window / ambiguous editable). Once input is
  dispatched, the outcome is proven by delta or honestly refused — never
  silent partial. A stale pinned window refuses outright ("The pinned
  target window closed. No other window was substituted."), same contract
  as the loop.
- Evidence: `tabsDelta`/`windowDelta` poll the smallest observable delta
  (AXRadioButton count direct children of AXWindow — explicitly excluding
  `AXWebArea` descendants, which are *page* tabs on real Chrome, e.g.
  GroqCloud's Cost/Activity widget); `typedText` polls the element's value
  for the payload suffix; `.delivered` honestly reports driver delivery
  when no AX delta exists (secure fields, reload/zoom). 150ms polls,
  10-attempt bound.

### 2. Driver read amplification — what was actually true

The audit claimed "the dispatch response already carries post-state".
Checked against the pinned driver contract
(`libs/cua-driver/contract/manifest.json`): dispatch tools have **empty
`success_output_schema`** — `effect`/`delivery`/`escalation` fields only.
There is no post-state to consume; the audit's premise was wrong. The real
fix, shipped instead:

- **Parallel observation** (`run()` ~line 940): when a window is pinned,
  `list_windows` and `get_window_state` are independent reads fired
  concurrently via `async let` — the transport multiplexes JSON-RPC by id.
  Same at the pre-dispatch re-match (~line 1408): `get_window_state` and
  the browser-dialog check run concurrently.
- **Gated pre-dispatch `list_windows`** (~line 1397): the window-set churn
  check only matters for plans that can spawn windows or aim by
  coordinates/process scope — `invoke_menu`, `scope=create`, or actions
  without `element_token`. Element-token dispatches re-match on the fresh
  tree anyway; they skip the extra read.

Per-step driver calls (pinned window, element-token action): was
`list_windows` + `get_window_state` + `list_windows` + `get_window_state`
+ `browser_dialog` serial ≈ 5 round-trips; now 2 concurrent pairs + 1
skipped read ≈ 3 effective round-trips. Browser-dialog-shaped actions also
drop the unneeded `get_window_state`.

### 3. OCR is fallback-only

`inspectVisual` is offered only when the semantic catalog has nothing to
aim at — no dispatchable elements, or only the element-less
`type_chars_only` input sink (`actions.allSatisfy { type_chars_only }`,
~line 1188). Never while a DOM binding owns the window (its refs are the
complete vocabulary), never alongside real native actions. The existing
visual-click contract (bound capture, no retry on rejected click) is
unchanged — the Calculator-style element-less path still gets OCR.

### Verified live, real Chrome (desktop lock, `JARVIS_CUA_CHROME_TAB_TEST=1`)

`open a new tab in google chrome` end to end:

```
tabs 6 → 7 (AXRadioButton delta on the pinned window)
driver calls: start_session, list_apps, get_accessibility_tree,
              list_windows, get_window_state, bring_to_front,
              hotkey, get_window_state, end_session
Jev calls: 0        consent prompt: not shown (standing grant)
mutations: hotkey only — no click, no OCR, no DOM prepare
outcome: Completed — "Opened a new tab"
wall time: 6.36s including test-harness + session spin-up
```

Previous baseline for the identical test: ~9.9s with a DOM consent
prompt, a blocked-release round-trip, and a real click. The remaining
latency is session/test harness spin-up, not the dispatch path.

### Tests

- New in `CuaTaskAgentTests` (fast-lane section):
  `testFastLaneParsesOnlyWholePhraseKnownCommands` (incl. negation,
  multi-step, truncation, conversational-mention negatives),
  `testFastLaneTypePreservesTheLiteralPayload` (casing/punct/quotes,
  `type the word`, payload-internal prepositions),
  `testFinalFastSpanDecidesWithoutAJevCall`,
  `testNonFinalOrNonPrimitiveSpanStillUsesTheDecisionBattery`,
  `testFastLaneNewTabDispatchesWindowScopedHotkeyWithObservedDelta`
  (end-to-end run(): window-scoped hotkey args, zero judge calls, no
  clicks, `AXWebArea`-descendant radios excluded from the strip count),
  `testFastLaneTypeUsesTheSingleEditableElement` (element-scoped
  type_text, value-delta proof),
  `testFastLaneTypeFallsThroughWhenTheEditableTargetIsAmbiguous` (no
  blind text; the loop owns disambiguation),
  `testVisualInspectionIsNotOfferedAlongsideNativeActions`.
- Results: focused Cua suite **251/0** (34 opt-in skipped); full suite
  **354/0**, 41 skipped — up from 346 (8 new tests).
- Regressions found and fixed during this round: greedy type payload
  swallowing a destination phrase (`type X into this document` → now
  falls through); stale pinned window bypass (runFastLane now re-validates
  pin membership before dispatch); OCR gate counting the element-less
  keyboard sink as a "semantic action" (gated on `allSatisfy`).

### Honest remaining limits

- `type X` fast lane requires exactly one editable element — anything
  more complex routes to the loop (correct but slower).
- `.delivered` effects (reload/zoom/address-bar) honestly report delivery,
  not outcome — no AX delta exists to read.
- The audit's "dispatch response carries post-state" premise was false
  for this driver version (empty `success_output_schema`); if a future
  driver emits post-state, `runFastLane`'s poll is where to consume it.
- `scroll`-class one-shots are deliberately not in the table — axis/
  element targeting makes them non-degenerate; they stay in the loop.
- Keystroke lanes are limited to `tabbableBundles` (browsers + Finder);
  other apps' non-standard chords stay in the agent loop.

---

## Addendum — open-lane + hardening pass (same day, follow-up)

The audit's "`open X` → `launch_app`" primitive was still routing through the
Jev battery; this pass closes it and fixes the robustness holes the live run
exposed.

### "open X" is now a deterministic launch primitive

`CuaFastLane` gained `parseOpen` / `resolveOpenApp` / `launchCommand`:
`open|launch|start|show|switch to|bring up|focus|go to <app>` resolves to a
uniquely named installed app (or a generic browser word → implicit browser),
produces `scope: "launch"`, and `run()` fast-exits deterministically:

- fresh launch → `launch_app` → bounded first-window wait → `bring_to_front`
  verified → `"Opened X; verified its window in front."`
- already running → raise existing window or report `"Observed X running."`
- a model-chosen `launch` scope on a compound phrase cannot fast-exit —
  `launchCommand` requires the goal text itself to be a bare open-command
  naming that app, so "open Safari and search" still gets the full loop.
- The launch **receipt** is captured in the lane (same contract as the loop:
  `launchedPID` + exactly one observable window + non-empty element
  fingerprint) so `"undo that launch"` corrections still work — this was a
  real regression caught by `CuaVoiceControllerTests`, now covered by
  `captureLaunchReceipt`.

### Verified-under-lock robustness fixes (live findings)

While live-testing, the session screen locked (`CGSSessionScreenIsLocked=true`,
`workspace_frontmost_pid=442` loginwindow). The run surfaced three real gaps:

1. **Raise-as-gate was wrong.** `bring_to_front` returning
   `process_activated=false`/`partial` aborted the whole action. But a
   window-scoped `hotkey`/`type_text` is already provably targeted — the
   `window_id` IS the targeting; frontmostness is a UX nicety. Now a failed or
   uncertain raise becomes a caveat (`"X could not be brought to the front."`)
   appended to the verified result; cancellation still rethrows.
2. **Hidden tab strip.** A single-tab Chrome window has no `AXRadioButton`
   strip at all → pre-count 0, post ⌘T materializes the strip at 2. The
   `tabsDelta` check went `==` → `>=` so the 0→2 materialization verifies.
3. **Phantom window inflation.** Chrome reports ~11 window rows where ~10 are
   1×1 off-screen untitled phantoms that out-z-order the real window.
   `bestWindowID` already filtered correctly; `windowDelta` now counts only
   on-screen titled rows (`realWindowCount`) so phantom churn can't fake or
   mask a new-window delta.

The locked-screen live failure itself is environmental — no driver call can
inject input while `loginwindow` owns the session — and the honest Uncertain/
refusal statuses under lock are the correct contract.

### Results after this pass

- `CuaTaskAgentTests`: **77/0** (2 new open-lane tests).
- `CuaVoiceControllerTests`: **61/0** — launch-receipt retention, safe
  launch reversal, and manual-mode gating all hold with the lane active.
- Full suite: **356/0**, 41 skipped.
- Release build + `make app` signed `Authority=Jev Voice Local Dev`, relaunched.

### Live verification status

`testChromeNewTabReproOptIn` last ran green pre-lock (tabs 6→7, zero Jev calls,
no consent prompt). The two post-lock runs correctly refused/uncertain under a
locked session — a valid environmental outcome, not a regression. Rerun under
`scripts/with-desktop-lock.py` once the screen is unlocked to recertify.

---

## Round 4 — the serial decision pattern is gone (merged `doneEvidence`)

The remaining "call Jev → do something → call Jev" was the completion path:
`chooseActionOrControl` answered `next`, and when it returned `done`, a
**second serial Jev call** asked `doneEvidence` against the same observation.
That doubled the model latency of every terminal step.

### The merge

`chooseActionOrControl` now asks `doneEvidence` **inside the same judgment
call** as `next` (`CuaTaskAgent.swift` ~1747): every per-observation request
carries both questions, and the `done` branch reads the evidence answer from
the same response (`~1347`). A terminal step costs one model call.

- `doneEvidence` instructions state the contract inline: observed state proves
  the outcome; dispatched history proves only that a step ran;
  `mutation_dispatched`/`state_unchanged_since_start` ride in the state so
  "something was created" can't be satisfied by a pre-existing instance.
- Absent or unreadable evidence answer → unproven, never a pass.
- Rejected claim → history note + `continue` → the loop re-observes before
  any further judgment; a retry is always decided on fresh state, never a
  bare repeat against unchanged observation. Bounded at 2 claims → refused.
- Pagination (`nextPage`/`previousPage`/`backToTargets`) asks `doneEvidence`
  too but only the terminal page's answer is consumed — the answer must come
  from the same call that produced `done`.

### What stayed serial, deliberately

Post-selection calls fire only where the answer depends on the choice itself:

- `risk`/`windowEffect`/`repeatIntent` — classify the *selected* action; the
  call fires only for flagged goals, repeats, or create-scope (gated last
  round). Benign steps: zero extra calls.
- `source`/`draftQuality` — depend on generated content, inherently serial.
- App/scope (`~840`) and window (`~1085`) selection — once per task, only
  when deterministic resolution fails.

### Raise-verb semantics fix (caught by tests)

`testUnverifiedActivationCannotReportSuccess` exposed a bug from the
raise-as-caveat change: it was applied to the open lane wholesale, but for
raise-semantic verbs (`show`, `switch to`, `bring up`, `focus`, `go to`) the
verified raise **is** the request — an unverified activation must refuse, not
report success. `CuaFastAction.parseOpen` now returns the matched verb and
`openRequiresRaise` gates it: launch verbs (`open`/`launch`/`start`) are
satisfied by an observed running process (raise = caveat); raise verbs
require `activated && exact_window_effect.verified` or refuse, and a
windowless target refuses rather than reporting "Opened".

### Dead code removed

`provenDoneEvidence` test helper + all 22 call sites — the standalone
evidence-call shape no longer exists; mocks answer `doneEvidence` inside the
`next` branch. Every per-key judge mock now handles the merged question set.

### New regression tests (CuaTaskAgentTests, 79 total)

- `testProvenDoneClaimCostsOneJudgmentCall` — a proven done is exactly one
  `next`-bearing call; a standalone `doneEvidence` call can never occur.
- `testDoneClaimWithMissingEvidenceAnswerIsNotSuccess` — `done` with no
  evidence answer → unproven → bounded retry → blocked; zero dispatches.
- `testDoneClaimRejectedWhenObservedEvidenceDoesNotProveIt` (strengthened) —
  the retried judgment must see the rejection in history and a fresh
  `get_window_state` must precede it; no dispatch during rejection.

### Results

- `CuaTaskAgentTests`: **79/0**. `CuaForegroundTests`: **5/0**.
- Full suite: **358/0**, 41 skipped.
- `make app` signed `Authority=Jev Voice Local Dev`, relaunched (pid 71260).

### Live recertification — PASSED (unlocked desktop)

`testChromeNewTabReproOptIn` under `scripts/with-desktop-lock.py`:

```
REPRO tabs before: 8 → after: 9
calls: start_session, list_apps, get_accessibility_tree, list_windows,
       get_window_state, bring_to_front, hotkey, get_window_state, end_session
consent prompt seen+approved: false
outcome: Completed — "Opening a new tab"
Jev calls: 0 (deterministic lane)
total: 9.373s including session spin-up and harness
```

9 driver calls, zero model calls, no prompt, real tab created and counted.

---

## Third pass — broad-app correctness (post-review, same day)

The prior pass over-weighted the browser lane. Live non-browser testing
exposed three correctness gaps, all fixed:

### 1. "open X" reported success without the window in front

The raise-as-caveat softening let `open`/`launch`/`start` complete with
"could not be verified in front" — but the request *is* the app in front.
All open verbs now share the strict contract: `bring_to_front` must return
`activated && exact_window_effect.verified`, or the task refuses honestly.
One settle+retry (400ms) covers the just-launched-window race — the driver's
900ms internal verify can fire before a fresh window reaches layer-0.
Windowless targets stay legal for launch verbs (menu-bar apps observe
"running"); raise verbs still refuse windowless. (`run()` open lane, ~931.)

### 2. OCR gate was keyed on the wrong predicate — broke Calculator

Gate was "offered only when no semantic actions exist". Calculator has
buttons (semantic actions) but **no element exposes a readable `value`** —
the result lives only in the rendered display. Live trace: typed `7+7=`
correctly → `doneEvidence: unproven` → with OCR withheld, Jev guessed
"Press AXButton All Clear" and **destroyed the computed result** → blocked
→ Failed.

Gate is now "nothing semantic can carry the answer": offered when the
catalog is keyboard-sink-only **or** no element carries any non-empty
`value`/`title`/`description`/`label` content. Still never while a DOM
binding owns the window, still never on a dialog, still a choice Jev must
actively pick — but reachable when the outcome is unobservable otherwise.
(`run()` ~1255.)

### 3. The old OCR test was vacuous

`testVisualInspectionIsNotOfferedAlongsideNativeActions` asserted
"inspectVisual not in choices" — but its judge never answered the app-
resolution battery, so `run()` threw before the loop ever built a choice
list. `offeredChoices` stayed empty; the assertion passed on nothing.
This is the class of test the cleanup targets: rewritten as
`testVisualInspectionOfferedOnlyWhenNothingIsReadable` with a judge that
answers `app`/`scope`/`visibility`, reaching `next` — then asserts both
directions (offered for buttons-only, withheld when a value element
carries evidence).

### 4. `get_browser_state` refused every iteration on native apps

Non-browser windows burned one refused call per loop iteration (4 in the
Calculator trace). `browser_route_unavailable` is now memoized per window
id — a native window can't become a browser, and the release/rebind
contract is untouched (release paths set `browserConsentDenied`, not just
`browser = nil`).

### New fast-lane breadth (deterministic, non-browser)

`new window` (⌘N, window-count delta), `minimize window` (⌘M,
`is_on_screen` flip), `hide`/`hide this app` (⌘H, all-windows off-screen),
`enter/exit full screen` (⌃⌘F, bounds≈screen readback — refuses to dispatch
from the wrong side since the chord toggles), `press enter/escape/tab/
space/arrows/home/end/pageup/pagedown` (single-key, driver-confirmed
delivery). `press delete`/`backspace`, `close window`, `quit`, and any
send/submit phrase stay out of the lane — the risk battery owns them.

### Verification

- `CuaTaskAgentTests` 85/0, `CuaVoiceControllerTests` 61/0,
  `CuaForegroundTests` 5/0. Full suite **364/0** (41 skipped opt-ins).
- Live, unlocked desktop, under `with-desktop-lock.py`:
  - `testCalculatorThroughVoiceControllerOptIn` — **Completed**, 8.9s
    (verified frontmost; first run failed honestly as Uncertain when the
    user stole focus mid-verification — correct strict behavior).
  - `testNewTextEditDocumentThroughVoiceControllerOptIn` — **Completed**,
    34.6s: launch → File→New via `invoke_menu` → `doneEvidence: proven`
    → verified new window id (full loop, real Jev, no fast lane).
  - `testHiddenCalculatorThroughVoiceControllerOptIn` — hidden app →
    "Show Calculator" → unhide + verified frontmost, **2.2s**.
  - `testCalculatorMathReproOptIn` — **Completed**: `7+7=` typed, OCR
    read the display, `doneEvidence: proven`. The pre-fix run **Failed**
    after destroying the result with All Clear — the OCR gate fix is the
    diff between a completed task and a corrupted one.
  - `testChromeNewTabReproOptIn` — tabs 9→10, 9 driver calls, 0 Jev,
    Completed, 6.2s.

`make app` rebuilt, `Authority=Jev Voice Local Dev`, relaunched (pid 2143).

## 2026-10-02 — broad real-app matrix + deterministic app-verb lane

- New opt-in matrix `testBroadAppCommandMatrixOptIn`
  (`JARVIS_CUA_MATRIX_TEST=1`): 12 commands through the real runtime across
  Calculator, TextEdit, Notes, Music, Terminal, Finder, System Settings —
  open/raise/hide/show/minimize/quit, each verified by independent
  observation (NSWorkspace frontmost, driver window reads, process state).
- Exposed and fixed four generic defects, no app special-casing:
  - Windowless foreground `open` completed on "observed running" with zero
    visible effect → now activates the app and falls back to the honest
    running report only when the app never fronts (menu-bar agents).
  - `hide|minimize|quit <app>` misrouted to assistant-task ops ("Which
    assistant task do you mean?") → verb-first app parse +
    `Body.appControl` dispatch: `NSRunningApplication` hide/unhide,
    `invoke_menu` Window→Minimize, approve+`terminate()` for quit. Zero
    model calls for the whole verb family.
  - Driver `exact_window_effect.verified` is stricter than the user-visible
    outcome on some apps (Calculator) → open lane cross-checks workspace
    frontmost + on-screen window before refusing.
  - `invoke_menu` on a just-shown app raced menu construction → one
    settle+retry.
- Result: matrix 12/12 green, ~11s total, session counters
  1×start_session/1×set_agent_cursor_enabled/1×end_session, suite 371/0.
