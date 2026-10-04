# Integration assets — mini-Clicky build (coordinator-owned)

Verbatim wire contracts extracted from `Clicky_Decompile/mirror/` for the
integration phase. Lanes code against `JevContracts.swift`; THIS is the
runtime behavior the wiring must produce.

## Agent → app final-message blocks (parse from each turn's final message)

```
<SUMMARY>One plain sentence.</SUMMARY>
<NEXT_ACTIONS>
- Short action phrase
</NEXT_ACTIONS>
<DONE_TITLE>Short Noun Phrase</DONE_TITLE>
<ARTIFACTS>
- /absolute/path/to/deliverable.ext
</ARTIFACTS>
```

Rules: SUMMARY always (<200 chars, plain, result-first — spoken + card);
NEXT_ACTIONS 1–4, ≤40 chars, imperative (tapping sends it back verbatim);
DONE_TITLE always (2–5 words Title Case); ARTIFACTS only on deliverables
(abs paths/URLs, ≤8, never tmp/ or work files).

Other parsed blocks:
- `<ROUTINE>{"action":"create","every_minutes":N,"title":"…","task":"…"}</ROUTINE>`
  — every_minutes ≥ 2, first run immediate, runs while Mac awake + app open
  ("never exact-time delivery").
- `<COMPUTER_USE_REQUEST>one-or-two-sentence ask ending in ?</COMPUTER_USE_REQUEST>`
  — rendered as Allow/Not-now card; SUMMARY = the same ask, SPOKEN.

## Voice routing ops (companion tool-call surface)

- `sessions_spawn {agent_slug? | new_agent{name, role, description,
  first_message}, message}` — task passed is the user's own brief as a
  first-person ask, never setup instructions.
- `sessions_send {agent_slug, message}` — bare follow-ups ("do it", "make it
  shorter") route to the agent currently in context.
- `sessions_answer_request {agent_slug, decision}` — exactly one pending ask
  → bare "yes"/"no" resolves it.
- `agent_memory {agent_slug}` — read findings without waking the agent.
- Founding: roster check first — if an existing agent covers it, offer
  send-vs-new instead of founding a twin. (Clicky enforces a two-question
  minimum; our lite version allows one clarifying turn then founds.)

## Agent system prompt (ClickyModelInstructions-lite, embedded constant)

Draft — becomes `AgentInstructions.swift` at integration:

```
You are {NAME}, a persistent agent inside Jev Voice on the user's Mac.

WORKSPACE (only write here):
- {WORKSPACE}/output/ — deliverables the user sees. Never tmp/ or work files.
- {WORKSPACE}/tmp/ — scratch.
- {WORKSPACE}/AGENTS.md — your memory. Maintain "## Standing preferences"
  (durable user prefs) and "## Notes" (dated findings). Update it whenever
  you learn something worth keeping.

TOOLS: computer-use drives the Mac (observe + act), jev-use is the fast
lane for clicking/typing inside one window (drive_until for multi-step UI
goals; it hands back when guessing or when no elements exist — then use
computer-use directly or ask).

CONSENT: input tools are REFUSED until the user approves this turn. When you
need to click/type/press, end your turn with a
<COMPUTER_USE_REQUEST>one-or-two-sentence ask ending in ?</COMPUTER_USE_REQUEST>
block — the user is asked (by voice + card) and your next turn will be
prefixed "[Computer use approved for this turn]" when granted. Approvals
are per-turn; ask again next turn. Never ask to confirm things the user
already asked for — the request IS the approval. Only re-confirm deletes,
sends, and purchases.

HARD RULES:
- Never run `open`, AppleScript, osascript, or Control-click trickery to
  drive the GUI — use computer-use/jev-use tools.
- All input is background-delivered: act on the target app/window without
  stealing the user's focus or cursor.
- Deliverables go to output/ — tell the user where via ARTIFACTS.

FINAL MESSAGE every turn ends with the block contract:
<SUMMARY>one plain sentence <200 chars, result-first</SUMMARY>
<DONE_TITLE>2–5 words Title Case</DONE_TITLE>
<NEXT_ACTIONS>- up to 4 offers, ≤40 chars, imperative</NEXT_ACTIONS>
<ARTIFACTS>- abs paths, ≤8, deliverables only</ARTIFACTS>
Plus <ROUTINE>…</ROUTINE> when the user asked for a cadence, or
<COMPUTER_USE_REQUEST>…</COMPUTER_USE_REQUEST> when you need input consent.

ROUTINES: emit <ROUTINE>{"action":"create","every_minutes":N,"title":"…",
"task":"…"}</ROUTINE> in the final block. every_minutes ≥ 2. The task must
be self-contained and never restate the cadence. Routines run while the
Mac is awake and Jev Voice is open — say that honestly.
```

## Consent plumbing sequence (their recipe, our types)

1. Agent turn hits gated input tool → `ComputerUseGate` refuses with
   `blocked_by_consent` JSON-RPC error (per agent+turn key).
2. Agent ends turn with `<COMPUTER_USE_REQUEST>ask?</COMPUTER_USE_REQUEST>`.
3. Runtime parses marker → creates `ConsentRequest{agentSlug,turnID,
   summary=ask}` → card + `SpeechSynthesizing.speak(ask)`.
4. Resolution: Allow button OR voice "yes" (bare yes → sole pending).
5. Gate.approve(request) → next turn message is prefixed
   `[Computer use approved for this turn]` → input calls now forward.
6. Deny/Not-now → next turn prefixed `[Computer use denied]` → agent
   explains/adapts without input.

## Delegation op → runtime mapping (companion)

- `delegate{agentSlug}` → AgentStore lookup → CodexRuntimeBridge
  .send(turn: message) on that agent's latest thread.
- `delegate{newAgent…}` → found: slug-gen (kebab name), AgentWorkspace
  scaffold, config.toml write, first turn = user's brief first-person.
- `agentMemory{slug}` → read workspace AGENTS.md Notes + output/ listing —
  summarised by planner, spoken. Never spawns a turn.
- Pending consent + bare yes/no → `sessions_answer_request` equivalent.

## Per-agent cursor identity wiring

- AgentCursor{agentSlug,label=name,colorHex=AgentCursor.palette(slug)}.
- Cursor registry: slug → active AgentCursor; overlay shows colored label
  chip at action target while that agent acts. Voice direct path uses the
  default teal "Jev" identity.
- Driver-drawn cursor is global (single) — per-agent identity needs our own
  overlay window per active agent; keep driver cursor for direct path only.
