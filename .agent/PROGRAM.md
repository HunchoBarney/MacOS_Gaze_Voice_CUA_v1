# PROGRAM — Jev v1 Tester Megaplan

Source of truth for "done". Derived from the tester megaplan
(`~/.devin/plans/plan-dd7484c27c0b1db0.md`, historical). If this file and
the megaplan disagree, this file wins; amend it via a Decision Log entry.

## Goal

Ship by ~Nov 1–2 (slip rather than miss bars) a Jev Voice that busy
founders prefer daily for four hero jobs:

1. **Inbox + messages by voice** (Mail or Gmail, Slack, Messages)
2. **Web tasks in my logged-in browser** (Chrome + Safari)
3. **Look + command anything** (gaze)
4. **Calendar, reminders, notes**

Built through a phased agentic harness: repo-local self-contained phase
plans, per-milestone commits on `ship/v1-<phase>` branches, an enforced
gate loop, at most two write tracks in parallel, all reusing proven tech
(Cua, OpenAI `gpt-6.1-sol` computer use, Chrome DevTools MCP, Safari
Apple-Events JS, onnxruntime-node Core ML, SpeechAnalyzer/Parakeet,
Browser-Use speed techniques) and proven by a bench that races Codex
Computer Use and Browser Use.

## Locked decisions

| Decision | Answer |
|---|---|
| Persona | Busy founder / power user |
| Testers | User + 1–2 people, hand-installed, local signing identity |
| Vendors / keys | OpenAI + TypeSafe only; keys embedded at build time from Keychain; rotate after testing |
| Vision/reasoning model | `gpt-6.1-sol` only; escalation = effort low → medium → high, never a model switch |
| Voice brain | Local first, realtime on miss |
| UI decision-making | One `TaskLoop`: `JevDecider` (≤4 rounds) → `SolDecider`; `BrowserDecider` (DOM-first, Sol) for tabs |
| Screenshots | Realtime: never; pixels only when a decider needs them; one capture reused per step |
| Eye tracking | Core feature; highlight always, dot when steady, dwell off by default |
| Bench | Separate macOS test user; ≥5 runs on hero tasks; Wilson CI; head-to-head vs Codex Computer Use + Browser Use |
| Hardware floor | 8 GB M1 |
| Commits | Per milestone on `ship/v1-<phase>` branches in worktrees; **user merges** |
| Check-in cadence | G1 phase-plan approval every phase; G6 hands-on for UX phases; merge + RC reviews |
| Parallelism | ≤2 write tracks, isolated worktrees, disjoint owned paths; read-only agents unbounded |
| Agent models | Implementer `opus`; judge `gpt` (fresh context, skeptical, read-only); research/explore `swe` |
| Uncommitted tree | User owns existing uncommitted changes; phases build on the working tree |

## Verified problems this program fixes (Oct 16–17 evidence)

- **Speed:** Fn release → action 1.2–2.8 s; release → transcript final
  0.44–1.6 s; first partial arrives only after release.
- **Voice correctness:** local router and realtime both act on the same
  utterance; 4 s text-match dedupe misses paraphrases → double-dispatch.
  Three transcribers loaded (gpt-4o-transcribe + Parakeet EOU 214 MB +
  Ultra 603 MB). Per-turn screenshots flow to realtime.
- **Computer use:** Jev chooser blind (no screenshot), 16 lexical
  candidates, no planner, unsigned/slow perception lane, no success
  measurement.
- **Browser:** no DOM-first lane; Safari unsupported
  (`browser_route_unavailable`).
- **Eye tracking:** wasm ≈2 fps (366 ms/frame benchmarked); WebGPU can
  wedge silently in Electron; no camera recovery; dot hidden/inaccurate;
  calibrations silently invalidated; dwell on.
- **Product:** no `NSAppleEventsUsageDescription`; experimental toggles
  in Settings; checklist-only onboarding; no feedback capture.
- **Process:** green tests ≠ working product (twice); parallel writers
  broke each other; a 6× inference regression shipped unmeasured;
  self-assessment over-credits.

## Target architecture (summary)

Voice: `Fn down → local ASR (live partials) + realtime buffer (no
response yet) + hold-time warm-up → Fn up → local final ≤200 ms →
deterministic parse → hit: execute + clear buffer; miss: commit +
response.create → one typed tool call` (realtime tool schemas in
`.agent/CONTRACTS.md`).

Executors: T0 FastLane ≤0.3 s; T1 script lane ≤1.5 s; T2 skill replay
≤2 s; T3 `TaskLoop`+`JevDecider` AX-only ≤4 s; TB `BrowserDecider`
≤15 s typical; T4 `SolDecider` ≤60 s. In-loop escalation Jev→Sol
(2 low-confidence picks, stale screen, invalid choice, degraded AX,
4 rounds); Browser→Sol pixels when DOM can't ground; Sol effort
low→medium→high on failed verification/stall.

Observation: AX-only default; screenshot on demand; prefetch while the
model thinks; `verify_state` settle; per-step spans
(observe/model/act/settle/output tokens). Prompts: stable
instructions/tools/history first, state last; terse actions.

## Desirability layer

First run = 3 real magic moments ≤3 min (read my emails · look+"open
this" · add an event). Daily hook: morning brief ≤5 s. Trust: read-back
confirms for send/book/delete, "undo that" for reversible actions,
honest "couldn't" + remedy. Feels instant: ack ≤300 ms, narration >2 s,
never steals focus. Feedback: "that was wrong"/capsule flag → redacted
trace; local tester metrics (days active/7, tasks/day, per-job success,
flags, time-saved).

## Phase DAG

| # | Phase | Track | Depends on | Gate evidence (summary) |
|---|---|---|---|---|
| P0 | Harness setup: `.agent/` artifacts, CONTRACTS v0, verification scripts, worktree recipe, hooks, doc normalization, `AGENTS.md` rewrite | main | — | Judge PASS on artifacts; dry-run gate loop |
| P1 | Bench test user + harness + **baseline** | main | P0 | Suite runs unattended; baseline JSON + report |
| P2a | Spike: `onnxruntime-node` Core ML fps on tracker models | eyes | P1 | ≥15 fps on M1 → promote; else documented fallback |
| P2b | Spike: ChromeDevTools MCP vs Cua `browser_*` speed/robustness | agent | P1 | Driver pick recorded with numbers |
| P2c | Spike: Codex app-server computer-use headless feasibility | agent | P1 | promote/discard + evidence |
| P2d | Spike: SpeechAnalyzer vs Parakeet + live-partials fix | voice | P1 | latency/WER/RAM table; winner picked |
| P3 | Voice one-brain (gated `response.create`, claim-ledger deletion, hold warm-up, realtime tools rewrite, delete gpt-4o/-mini + IntentClassifier/LocalChooser + CommandSpotter) | voice | P2d | Zero double-dispatch (50 paraphrases); T0 ≤300 ms; no images on socket |
| P4 | `TaskLoop` refactor + `JevDecider` (recall v2 A/B, 4-round budget, settle, agents via same loop, delete perception lane) + **session-label wedge fix** (P1 finding: reused `--agent` slugs wedge drive_until until daemon respawn — `CuaDriveServer.swift:205,209`, `DriveLoop.swift:264-322`) | agent | P1 | DriveLoop tests green on TaskLoop; Jev slice ≥95%/≤4 s; repeated same-slug `--mcp-stdio` calls stay live |
| P5 | `OpenAIResponsesClient` + `SolDecider` (actions→Cua, batching, consent-at-risk, `pending_safety_checks`→user, effort ladder, gaze hint, recording) | agent | P4 | Complex slice ≥80%/≤60 s; red-team zero violations |
| P6 | Script lane (hero intents + `inbox_brief`, argv-only, read-back confirm, contacts/dates, `NSAppleEventsUsageDescription`) | voice | P3 | Per-intent ≥99%/≤1.5 s; injection tests; brief ≤5 s |
| P7 | `BrowserDecider` + drivers (ChromeDevToolsDriver, CuaBrowserDriver, SafariAppleEventsDriver) + `DOMSnapshot.js` + `extract` + settle | agent | P2b, P5 | Browser slice ≥90%/≤15 s; ≥2× Sol-pixel path |
| P8 | Eye core: Core ML inference, camera recovery, visible steady dot, durable calibration + drift prompt | eyes | P2a | ≥15 fps; wake recovery ≤5 s; calibration checks |
| P9 | Skill compiler (store, compile from traces/recordings, validation, retirement, matching) | agent | P5, P7 | Repeat slice ≥95%/≤3 s; no unverified done |
| P10 | First run (privacy, permissions incl. Automation + browser toggles, calibration, 3 magic moments) + desirability (brief, undo, read-back, feedback, metrics) + settings consolidation | voice | P3, P6 | 3 moments ≤3 min; human G6 |
| P11 | Eye polish: fps-adaptive sampling floors, dwell (off default, 1 s+look-away when on), geometry, resource budget + model pruning, gaze→deciders, smoke script | eyes | P8, P5 | Gaze slice ≥95%; tracker-smoke green |
| P12 | Packaging (strict bundle-tracker + node + onnxruntime + devtools-mcp + pruned models), embedded keys, spend caps, diagnostics, demo warm-start, tester guide | main | all | Clean-Mac install; demo flow 10/10 |
| P13 | RC bench + head-to-head | main | P12 | Every release bar |

Cut order if the date slips: Slack desktop AX → Jev image experiment →
low-value script intents → agent polish.

## Reuse map

| Need | Use |
|---|---|
| Mac actuation, AX+pixels, settle, zoom, recording | Cua Driver v0.34 (pinned, hash-verified) |
| Complex UI reasoning | OpenAI Responses `computer` tool on `gpt-6.1-sol` (WebSocket, caching, effort, Ultrafast flag) |
| Background Mac agent (spike) | Codex app-server Computer Use — unverified, 1-day spike |
| Chrome DOM | Chrome DevTools MCP `--autoConnect` on bundled node; Cua `browser_*` fallback |
| Safari DOM | `do JavaScript` via Apple Events (needs "Allow JavaScript from Apple Events") |
| Browser speed | Browser-Use design: indexed compact DOM, on-demand screenshots, `extract(q)`, history-before-state, terse actions |
| Settled-step browsing | ABP pattern via CDP/`verify_state` |
| Skills | Cua recording + PreAct/SkillDroid/Webwright designs; we build locator re-binding + validation |
| App scripting | AppleScript dictionaries, `shortcuts run`, Cua `invoke_menu` |
| Speech | Parakeet vs SpeechAnalyzer bake-off; one transcript of record |
| TTS | PocketTTS / AVSpeech |
| Tracker inference | `onnxruntime-node` Core ML EP in Electron utility process; wasm last resort |
| Reference codebases | `browser-use`, `agent-browser-protocol`, `openai-cua-sample-app`, Agently decompile notes, Cua source — read-only; license check before copying |
| Bench sources | MacArena/macOSWorld tasks, cua-speedrun method, Online-Mind2Web-style web tasks |
| Not used | gpt-6-astra, Beam SDK, WebMCP, perception extension, Anthropic/Google |

## Release bars

- One-shots: p50 <0.5 s and ≥99%. Everyday hero tasks: p50 <5 s ≥95%.
  Replay: p50 <3 s ≥95%. Browser: p50 <15 s ≥90%. Novel complex:
  p50 <60 s ≥80%. Wilson lower bound ≥ bar −7.
- Head-to-head: faster than Codex Computer Use on ≥70% shared subset at
  equal-or-better success; browser subset within 1.2× of Browser Use or
  faster.
- Zero double-dispatch, zero false "Done", zero deny-list violations;
  safety checks never auto-acknowledged.
- Eye: ≥15 fps (M1 8 GB), calibration ≥80% first try, wake recovery
  ≤5 s, dwell off by default.
- Resources: steady RSS ≤2.5 GB, idle CPU ≤10%.
- First run → 3 moments ≤3 min; demo 10/10; all suites green; every
  phase's acceptance.json PASS with evidence.

## Non-goals

`gpt-6-astra` or other model escalation; Anthropic/Google; hosted
proxy; notarization/public release; auto-update; native tracker rewrite;
Beam SDK; WebMCP; perception extension; best-of-N/speculation; desktop
code-as-action; new agent features; >2 parallel write tracks.

## Decision Log index

Decisions are recorded in the owning phase's ExecPlan (`Decision Log`
section) and appended here one line each.

| # | Date | Phase | Decision |
|---|---|---|---|
| D0 | 2026-10-18 | P0 | Harness created; PreToolUse per-subagent path scoping deferred (hook payloads carry no agent identity) → owned-paths enforced by `scripts/check-owned-paths.py` at G4/G7 instead |
| D1 | 2026-10-18 | P0 | P0 runs in the primary checkout on `ship/v1-p0`, not a worktree — doc normalization must edit files with uncommitted user changes a worktree can't see |
| D2 | 2026-10-18 | P0 | `research-notes.md` is the single kept dev doc; audits deleted outright — point-in-time findings already encoded in "Verified problems" |
| D3 | 2026-10-18 | P1 | Bench task JSON gains `inject` (default `"mcp_stdio"`), `requires` (`"local-safe"\|"test-user"\|"human"`), optional `app` hint; verifier kinds `app_frontmost`+`dom_state` made explicit |
