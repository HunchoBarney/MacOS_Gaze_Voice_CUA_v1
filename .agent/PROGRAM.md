# PROGRAM — Jev v1 Tester Megaplan

Source of truth for "done". Derived from the tester megaplan
(`~/.devin/plans/plan-dd7484c27c0b1db0.md`, historical). If this file and
the megaplan disagree, this file wins; amend it via a Decision Log entry.

Current delivery and versioned P0–P13 mapping: [SHIP-PLAN v2](SHIP-PLAN.md). Reuse choices:
[REUSE.md](REUSE.md). Competitive method: [COMPETITIVE.md](COMPETITIVE.md).
KAR-22 authorizes building across C1–C3 within the existing gates.
Historical acceptance and evidence remain intact. This is not authority
for a live session, a billed run, installation or release.

## Goal

Ship the complete private tester v1 as soon as its required behavior and
evidence pass. The former Nov 1–2 date is historical, not a current promise.
Deliver a Jev Voice that busy
founders prefer daily for four hero jobs:

1. **Inbox + messages by voice** (Mail or Gmail, Slack, Messages)
2. **Web tasks in my logged-in browser** (Chrome + Safari)
3. **Look + command anything** (gaze)
4. **Calendar, reminders, notes**

Built through a phased agentic harness: repo-local self-contained phase
plans, authorized milestone commits on `ship/v1-<phase>` branches, and
phase gates under [PLANS](PLANS.md), all reusing proven tech
(Cua, Jev decisions, OpenAI `gpt-6.1-terra` recovery, Chrome DevTools MCP, Safari
Apple-Events JS, onnxruntime-node Core ML, OpenAI Realtime,
Browser-Use speed techniques) and proven by a bench that races Codex
Computer Use and Browser Use.

## Locked decisions

| Decision | Answer |
|---|---|
| Persona | Busy founder / power user |
| Implementation reuse | Free open source before a new subsystem: existing code/platform APIs → maintained FOSS → minimum adapter or documented gap. Record exact versions/licenses and the reuse decision before custom implementation; REUSE.md owns the inventory. |
| Testers | User + 1–2 people, hand-installed, local signing identity |
| Vendors / keys | OpenAI + TypeSafe only; keys embedded at build time from Keychain; rotate after testing |
| Vision/reasoning model | Jev remains primary for semantic UI decisions; direct grounded operations need no model call. GPT-6.1 Terra via the user-authorized API is the recovery/planning/generation route when needed. Jev 1.14 image/Box remains experimental and default off until qualification. No automatic replacement-model tournament or deeper model escalation. |
| Voice brain | R10 landed OpenAI Realtime conversation, direct native controls and Jev/Cua for unfamiliar desktop work. Matching committed input transcription is the final authority. Local speech models are diagnostic only. R10 source/artifact review is not acceptance of a later candidate or a physical turn. |
| Manual control | Hands-free is optional: typing and pointer use take priority. No numbered grid or “show numbers” coaching. Use descriptions, a brief clarification or a fresh resolved gaze target; pause foreground work rather than commandeer input. |
| UI decision-making | One `TaskLoop`: direct typed operations, progress-driven `JevDecider`, and a P5 recovery adapter configured for Terra. `BrowserDecider` is DOM-first and uses direct/Jev decisions before Terra where applicable. The old planned `SolDecider` name is historical; review the adapter/consumer mapping at G2. No default round ceiling. |
| Screenshots | Realtime: never; pixels only when a decider needs them; one capture reused per step |
| Eye tracking | Core feature — copies the **visionOS input model**: eyes are the *targeting* mechanism only (the gazed element gets a hover-style highlight; a steady-state dot shows track confidence). Selection is always a *separate channel* — voice command, click, or key; gaze alone never actuates. Deciders receive the **resolved target identity** (AX element/window ref), never raw gaze coordinates. Dwell = accessibility opt-in, off by default; every gaze flow must also work without gaze (user directive 2026-10-19: "copy Apple") |
| Bench | Separate macOS test user; ≥5 runs on hero tasks; Wilson CI; head-to-head vs Codex Computer Use + Browser Use; mandatory matched Wispr Flow accuracy/insertion comparison and per-category scorecard per COMPETITIVE.md |
| Hardware floor | 8 GB M1 |
| Commits | When authorized, per milestone on `ship/v1-<phase>` branches in worktrees; **user controls merges**. A phase plan is not permission to stage, commit or publish. |
| Check-in cadence | G1 phase-plan approval every phase; G6 hands-on for UX phases; merge + RC reviews |
| Coordination | PLANS §§3–6: one owner per outcome; bounded readers within approved scope; pilot two disjoint, isolated writers against a verified common base. One integration/build owner and one physical operator. |
| Agent roles | Reviewer independence, fresh context and read-only scope matter; no fixed model family for engineering roles. Product model/provider decisions above are unchanged. |
| Uncommitted tree | The user owns inherited changes. A fresh checkout is not the dirty tree; compare the actual delta to its recorded baseline. |
| Permissions | All grants issued ONCE during onboarding — TCC (Screen Recording, Accessibility, Microphone) + Chrome remote-debugging toggle & Allow. No recurring prompts in product flows (user directive, 2026-10-19) |
| Browser attach | User's REAL logged-in Chrome is the primary surface (no profile fork); P7 driver holds one persistent browser-level ws connection → ≤1 Allow per Chrome launch; JevVoice-owned `--user-data-dir` profile is the documented zero-dialog alternative |

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

Voice: healthy duplex audio + confirmed Realtime session → server-detected
turn (or manual Fn commit) → matching final for this input item → one host
admission against the captured context. Insert literal text directly, use
native actions for grounded commands, or authorize the appropriate
dialogue/tool response. A partial, spoken reply or stale tool cannot act.
No screen pixels go to Realtime. The [R10 contract](results/P4/c1-r10-realtime-contract.md)
supersedes the old local-final startup design; [CONTRACTS](CONTRACTS.md)
retains the frozen tool and outcome boundaries.

Executors (lane budgets — routing picks the cheapest lane that can do
the job; the generalist lanes are fallbacks, not front doors): T0
FastLane ≤0.3 s; T1 script lane ≤1.5 s; T2 skill replay ≤2 s; T3
`TaskLoop`+`JevDecider` AX-first with experimental scoped-image fallback ≤4 s; TB `BrowserDecider` ≤15 s
typical; T4 Terra recovery adapter ≤60 s; **TC codex-CU agent lane** (Sky MCP
host via app-server, P2c): bounded single-app GUI tasks p50 ≤30 s —
measured p50 27.6 s, ~150–200k input tokens/task (75–88% cached).
TC is for open-ended GUI work T0–T3 can't express and background/batch
jobs; nothing a fast lane can do may route through TC. TC levers to
reach budget: slimmer AX-state payloads (Sky dumps 75–225KB/task),
persistent thread/session (warm-up 6–11 s amortized), act-don't-
re-perceive prompts, cheaper planner tier with escalation.
UX: ack ≤300 ms always; lanes ≥T3 stream progress; every T4/TC run is
interruptible. In-loop escalation Jev→Terra recovery
(2 low-confidence picks, stale/no-progress screen, invalid choice, degraded AX,
or an explicitly configured budget); Browser→Terra recovery when DOM/Jev cannot ground. Terra effort
is selected from measured quality/latency; low→medium→high can recover
verified stalls, but no automatic broader model ladder is introduced.

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

The dependency column retains final acceptance dependencies. For
implementation overlap, SHIP-PLAN permits a downstream phase to consume
an independently reviewed upstream contract/source milestone with affected
checks and an explicit hash-bound handoff, while upstream G5/G6 remains
open. This never grants upstream PASS or moves failed tasks between slices.
P12 packaging checks can start early; complete P12 acceptance depends on
P0–P11, and P13 depends on P12. Track names below are subsystem labels,
not checkout assignments. P11's existing off-by-default safety
requirement can be corrected in C1 before the rest of P11.

| # | Phase | Track | Depends on | Gate evidence (summary) |
|---|---|---|---|---|
| P0 | Harness setup: `.agent/` artifacts, CONTRACTS v0, verification scripts, worktree recipe, hooks, doc normalization, `AGENTS.md` rewrite | main | — | Judge PASS on artifacts; dry-run gate loop |
| P1 | Bench test user + harness + **baseline** | main | P0 | Suite runs unattended; baseline JSON + report |
| P2a | Spike: `onnxruntime-node` Core ML fps on tracker models | eyes | P1 | ≥15 fps on M1 → promote; else documented fallback |
| P2b | Spike: ChromeDevTools MCP vs Cua `browser_*` speed/robustness | agent | P1 | Driver pick recorded with numbers |
| P2c | Spike: Codex app-server computer-use headless feasibility | agent | P1 | promote/discard + evidence |
| P2d | Spike: SpeechAnalyzer vs Parakeet + live-partials fix | voice | P1 | latency/WER/RAM table; winner picked |
| P3 | Voice one-brain: one host-owned final, gated tool response and no speculative competing chooser. Apply the R10 provider mapping in SHIP-PLAN before interpreting legacy local-only checks. | voice | P2d | Zero double-dispatch (50 paraphrases); T0 ≤300 ms; no images on socket |
| P4 | `TaskLoop` refactor + `JevDecider` (recall v2 A/B, optional progress-driven budget, settle, agents via same loop, delete perception lane) + **session-label wedge fix** (P1 finding: reused `--agent` slugs wedge drive_until until daemon respawn — `CuaDriveServer.swift:205,209`, `DriveLoop.swift:264-322`) | agent | P1 | DriveLoop tests green on TaskLoop; Jev slice ≥95%/≤4 s; repeated same-slug `--mcp-stdio` calls stay live |
| P5 | SDK-backed `OpenAIResponsesClient` + Terra recovery adapter (legacy planned name `SolDecider`), actions→Cua, guarded batching, consent/safety, gaze hint, recording | agent | P4 | Complex slice ≥80%/≤60 s; red-team zero violations; Jev-only versus Jev-with-recovery policy comparison |
| P6 | Script lane (hero intents + `inbox_brief`, argv-only, read-back confirm, contacts/dates, `NSAppleEventsUsageDescription`) | voice | P3 | Per-intent ≥99%/≤1.5 s; injection tests; brief ≤5 s |
| P7 | `BrowserDecider` + drivers (ChromeDevToolsDriver, CuaBrowserDriver, SafariAppleEventsDriver) + `DOMSnapshot.js` + `extract` + settle | agent | P2b, P5 | Browser slice ≥90%/≤15 s; ≥2× Sol-pixel path |
| P8 | Eye core: Core ML inference, camera recovery, **visionOS gaze-target model** (element hover-highlight on look, steady-state confidence dot, no gaze-cursor), durable calibration + drift prompt | eyes | P2a | ≥15 fps; wake recovery ≤5 s; calibration checks |
| P9 | Skill compiler (store, compile from traces/recordings, validation, retirement, matching) | agent | P5, P7 | Repeat slice ≥95%/≤3 s; no unverified done |
| P10 | First run (privacy, permissions incl. Automation + browser toggles, calibration, 3 magic moments) + desirability (brief, undo, read-back, feedback, metrics) + settings consolidation | voice | P3, P6 | 3 moments ≤3 min; human G6 |
| P11 | Eye polish: fps-adaptive sampling floors, dwell (accessibility opt-in: off default, 1 s+look-away when on), geometry (≥60 pt / ≈2.5° min target spacing per visionOS guidance), resource budget + model pruning, gaze→deciders as **resolved-target hint** (never raw coords), smoke script | eyes | P8, P5 | Gaze slice ≥95%; tracker-smoke green |
| P12 | Packaging (strict bundle-tracker + node + onnxruntime + devtools-mcp + pruned models), embedded keys, spend caps, diagnostics, demo warm-start, tester guide | main | P0–P11 | Clean-Mac install; demo flow 10/10 |
| P13 | RC bench + head-to-head | main | P12 | Every release bar |

Historical cut order: Slack desktop AX → Jev image experiment →
low-value script intents → agent polish. The current plan retains all four
hero jobs; any feature cut needs an explicit decision. Retiring the Jev
image experiment must not remove the general screenshot fallback.

The [delivery roadmap](SHIP-PLAN.md) is the current order: quiet first-minute
conversation with optional Fn (C1), useful verified tasks alongside manual
work (C2), then portable tester install, production gaze and matched
qualification (C3). The DAG above is the acceptance order, not a sequence
of mandatory signed builds.

## Reuse map

| Need | Use |
|---|---|
| Mac actuation, AX+pixels, settle, zoom, recording | Cua Driver v0.38 (user-authorized upgrade, pinned and hash-verified) |
| Complex UI reasoning | Approved Terra API through an existing Swift Responses SDK; text/images and typed proposals, Cua/native execution. Reuse supported transport/caching; effort and speed tier are measured choices, not assumed cheapest/fastest settings. |
| Background Mac agent | Codex app-server + `Codex Computer Use.app` (Sky) MCP — **P2c PROMOTED** (console session): JevVoice client owns the per-app elicitation policy (exact bundle-id matching); locked/background-session unverified → jevbench test |
| Chrome DOM | Chrome DevTools MCP `--autoConnect` on bundled node; Cua `browser_*` fallback |
| Safari DOM | `do JavaScript` via Apple Events (needs "Allow JavaScript from Apple Events") |
| Browser speed | Browser-Use design: indexed compact DOM, on-demand screenshots, `extract(q)`, history-before-state, terse actions |
| Settled-step browsing | ABP pattern via CDP/`verify_state` |
| Skills | Cua recording + PreAct/SkillDroid/Webwright designs; we build locator re-binding + validation |
| App scripting | AppleScript dictionaries, `shortcuts run`, Cua `invoke_menu` |
| Speech | Realtime input transcription for the matched committed item; P2d's local bake-off is historical diagnostic evidence. |
| TTS | Realtime output by default; PocketTTS / AVSpeech only on the explicit diagnostic path. |
| Tracker inference | `onnxruntime-node` Core ML EP in Electron utility process; wasm last resort |
| Reference codebases | `browser-use`, `agent-browser-protocol`, `openai-cua-sample-app`, Agently decompile notes, Cua source — read-only; license check before copying |
| Bench sources | MacArena/macOSWorld tasks, cua-speedrun method, Online-Mind2Web-style web tasks |
| Not used | gpt-6-astra, Beam SDK, WebMCP, perception extension, Anthropic/Google |

## Release bars

- One-shots: p50 <0.5 s and ≥99%. Everyday hero tasks: p50 <5 s ≥95%.
  Replay: p50 <3 s ≥95%. Browser: p50 <15 s ≥90%. Novel complex:
  p50 <60 s ≥80%. **CU-agent lane (TC): bounded single-app tasks
  p50 ≤30 s with independent verification** (P2c baseline 27.6 s).
  Wilson lower bound ≥ bar −7.
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

## Aggressive interaction goals (2026-11-15)

The user rejected the earlier 0.5s/2s/5s interaction targets as too slow.
These are the current engineering goals, not achieved measurements or a
silent rewrite of existing acceptance files. Every candidate must show
the measured gap. An unmet goal must be addressed or presented explicitly
at the ship decision; an agent cannot quietly revert to the older target.
Any formal gate/population amendment requires review and a Decision Log.

| ID | Interaction and clock | Warm p50 goal | Warm p95 goal |
|---|---|---:|---:|
| S-FEEDBACK | Fn/input event → visible listening/working feedback | ≤30ms | ≤50ms |
| S-DICTATION | Fn release → complete exact insertion into the captured focused field | ≤50ms | ≤150ms |
| S-NATIVE | Fn release/typed submit → independently verified simple native effect | ≤100ms | ≤250ms |
| S-VISUAL | Task submission → independently verified single action requiring visual reasoning | ≤500ms | ≤1s |
| S-WORKFLOW | Fn release/typed submit → verified short local workflow, frozen 2–3-action population | ≤1s | ≤2s |

Dictation also records independent readback/verified completion separately;
native timing must not stop at a dispatch acknowledgment. Record speech-end
→ insertion alongside Fn-release → insertion so holding Fn longer cannot
manufacture a speed win. Provisional pill text is neither target insertion
nor completion. Preserve every final word, correction, negation and literal.
Do read-only preparation/incremental inference during speech, never execute
from a partial or require a pause before release.

S-VISUAL starts before routing/planning and includes observation, capture,
all model calls, actuation and verification; report full Fn-to-effect
separately for voice.
Cold start, app launch, page load and external service delay remain in
their end-to-end totals. Warm cases must be identified before the run, not
selected afterward. Report failures/timeouts and meaningful p95 sample
sizes. Feedback speed never replaces actual task speed.

The original one-shot/hero/browser/complex/replay/resource/statistical
release requirements above still apply. Per-phase scorecards and P13
explicitly report both those requirements and the stricter relevant goals.

## Competitive objective and routing (user direction, 2026-11-15)

Aim to lead every shipped category on correctness and p50/p95 useful
completion, with Wispr Flow as the primary dictation-quality comparator.
The old >=70% Codex wins / <=1.2x Browser Use bars are minimum release
gates, not evidence of leadership. COMPETITIVE.md defines the additional
matched accuracy, edit burden, critical-content and category scorecards.
No product or plan presently establishes that Jev is fastest.

Use direct native/script/replay actions when intent and targets are
grounded. Use Jev for needed semantic decisions over fresh scoped AX/DOM
or qualified visual state. Use Terra when the request needs generation,
longer planning, unsupported visual reasoning or recovery that Jev cannot
resolve within the task budget. Do not make Jev fail first on an obvious
generation request, or call Terra speculatively for every action.
Missing permissions, policy refusals and uncertain mutations require the
appropriate remedy/evidence; another model cannot grant authority.

The user explicitly authorized the Terra API route. Existing OpenAI key,
privacy and spend policy applies; documentation research makes no calls.
ChatGPT/Codex remains the existing optional background route and is not
a new authentication dependency for ordinary recovery. Terra does not
support audio/Realtime and is not the speech provider. No silent switch
between subscription and billed API on errors or quota exhaustion.

Retain the historical Sol-pixel comparison in P7 as a benchmark reference,
not a production model choice. Compare the configured Terra pixel path
additionally to isolate DOM gains; if the old baseline is no longer
applicable, version/review its amendment before new qualification.

## Non-goals

`gpt-6-astra` or model escalation beyond the approved Jev/Terra routes; Anthropic/Google; hosted
proxy; notarization/public release; auto-update; native tracker rewrite;
Beam SDK; WebMCP; perception extension; best-of-N answer shopping or
speculative mutations (bounded independent reads/Jev questions are allowed); desktop
code-as-action; new product agent features.

## Decision Log index

Decisions are recorded in the owning phase's ExecPlan (`Decision Log`
section) and appended here one line each.

| # | Date | Phase | Decision |
|---|---|---|---|
| SHIP-3 | 2026-11-17 | PROGRAM · KAR-22 | Build C1 quiet first use, C2 tasks that yield to manual input, C3 portable tester qualification. Retire the numbered grid and its coaching; retain gaze as local targeting with separate selection. [Delivery map v2](SHIP-PLAN.md) carries P0–P13, R10 and outstanding physical gates forward. No change to frozen contracts, phase scores, spend, data, live authority or release control. |
| COORD-1 | 2026-11-17 | PROGRAM | User approved the Capy coordination audit. PLANS supersedes the fixed named worktrees, permanent two-writer ceiling, unbounded readers, per-helper approval and fixed engineering model roles. Bounded bug proof is not phase acceptance. G1–G7, frozen contracts, scoped data/spend/live authority, historical evidence and user release control remain in force. No product run authorized. |
| C1-R10 | 2026-11-16 | P3/P4/P12 | User explicitly selected OpenAI realtime voice after local startup/empty-final failures. G2 reviewer87dfafed PASS on revised `results/P4/c1-r10-realtime-contract.md`: server VAD/input-final correlation, provider-independent turn admission, common conversation safety, default Realtime speech output; local ASR/VAD/TTS only explicit diagnostics. Native/Cua/Jev safety and separate-service controls remain. Consumer/source/artifact/live/human verification still required; no install/commit. |
| C1-R10-base | 2026-11-17 | P4/P12 | Recorded original daily app is absent; cause unknown. G2 reviewer859f3e7e PLAN PASS on `results/P4/c1-r10-packaging-base-amendment.md`: explicit final-r10-only retained-base flag, pinned verified R9-2 receipt/app/binary/signature/resources, original daily absence before/after, separate truthful historical-daily metadata. P12 enforces provenance and existing rollback controls. No daily restore/install/removal, no new Swift build, no source/live/phase acceptance implied. |
| SHIP-2 | 2026-11-15 | PROGRAM | User directed continued Jev+Cua with Terra when needed and explicitly allowed Terra API. Updated planned default-Sol/replacement search to Jev-first routing with measured Terra recovery; added mandatory Wispr quality comparison and per-category leadership scorecard. Existing accepted P0–P4 records and source unchanged; new work remains under phase gates. |
| SHIP-1 | 2026-11-15 | PROGRAM | User authorized updating plans/docs for faster delivery and FOSS-first implementation. Added SHIP-PLAN/REUSE, stricter unproven speed goals, source-readiness handoffs and P5–P13 drafts/default-fail criteria. Existing passes/evidence, production model/pricing and installed artifacts are unchanged; G1/G2 implementation and scoped spend/install decisions remain required. |
| D0 | 2026-10-18 | P0 | Harness created; PreToolUse per-subagent path scoping deferred (hook payloads carry no agent identity) → owned-paths enforced by `scripts/check-owned-paths.py` at G4/G7 instead |
| D1 | 2026-10-18 | P0 | P0 runs in the primary checkout on `ship/v1-p0`, not a worktree — doc normalization must edit files with uncommitted user changes a worktree can't see |
| D2 | 2026-10-18 | P0 | `research-notes.md` is the single kept dev doc; audits deleted outright — point-in-time findings already encoded in "Verified problems" |
| D3 | 2026-10-18 | P1 | Bench task JSON gains `inject` (default `"mcp_stdio"`), `requires` (`"local-safe"\|"test-user"\|"human"`), optional `app` hint; verifier kinds `app_frontmost`+`dom_state` made explicit |
| D4 | 2026-10-19 | P2a | `onnxruntime-node` + Core ML EP PROMOTED for eye inference (wasm ~2fps baseline beaten; ≥15 fps bar met) |
| D5 | 2026-10-19 | P2b | Browser driver = ChromeDevTools primary + Cua fallback; persistent browser-level ws connection (≤1 Allow/launch); real logged-in profile is primary, JevVoice-owned profile = zero-dialog option |
| D6 | 2026-10-19 | PROGRAM | Permissions: all grants ONCE during onboarding, no recurring prompts (user directive) — applies to TCC, Chrome consent, Sky per-app elicitations |
| D7 | 2026-10-19 | P2c | Codex app-server + Sky CU host PROMOTED (console session) as **TC lane** with p50 ≤30 s budget; client owns per-app elicitation policy; locked/background sessions → jevbench verification |
| D8 | 2026-10-19 | PROGRAM | Eye tracking adopts the **visionOS input model**: gaze = targeting only (hover-highlight + steady dot), selection via separate channel (voice/click), deciders get resolved-target identity not raw coords, dwell accessibility-only (user directive: "copy Apple") |
| D9 | 2026-11-10 | P4 | User approved provenance-first completion-evidence amendment: native entire-field/parent-document provenance and original local subject anchor first; only if signed matched evidence still underclaims, a distinct receipt-bound exact-replacement basis with three independent semantic gates, no lower thresholds or new permissions; plan `results/P4/jev-exact-value-goal-plan.md`, all observation/evidence consumers re-reviewed before admission |
| D9a | 2026-11-10 | P4 | User approved optional native role-only ancestry in existing observation/fact state; senior51fbb72e PLAN PASS; implemented with 313 checks and fresh6cc7d424 consumer SOURCE PASS; no extra AX/model call, inferred body flag, question/threshold change, pre-action intent or new authority; clear SDK/old ancestry, retain verified scope and fresh Node/Context equality; plan `results/P4/jev-native-context-plan.md`; signed interrupted/resumed command set 2/3 baseline and 2/3 candidate, no reliability gain or phase acceptance |
| D9b | 2026-11-10 | P4 | User explicitly selected Approve D9b; senior9702f261 PLANPASS accepts private loop-owned delivered-effect observation and fail-first seam contract; next existing native read must prove exact binding before factual context, never new completion/input authority; D9 .90 proposal/receipt/three .95 gates and general .95/.9/.9 unchanged; plan `results/P4/jev-delivered-effect-plan.md`; no extra AX/model call or public API/permission change; consumer re-review and signed qualification required |
| D13 | 2026-11-11 | P4 | User explicitly selected Approve Reviewed Amendment for `results/P4/jev-native-primary-kind-plan.md` SHA953f18c706bd11fcc503fd41ebc3f7cee28975cd88832c6323064e628aaa170b; one-file primary goal_kind instruction/exact_text criterion alignment only with an actual native readonly registry; no new fields/IDs/heads/RPCs or lower gates, verifier unchanged; fresh198f0140 source PASS after fail-first/native keeper mutation,337 consumer and73 harness checks; signed G5 remains required, no installation or phase acceptance |
| D14 | 2026-11-11 | P4 | User selected Approve D14 after tightened plan review4b3992f3 PASS; native-token TaskLoop dispatch may request existing advertised post_action_wait=none and session-only glide_duration_ms=120; per-generation capability cache and per-session preparation, no shared-default/visibility/style change, no new driver API/model call or weaker gate; CuaConnection.swift and DriverConnectionTests.swift ownership extension; cold/warm evidence separate, no install or phase PASS |
