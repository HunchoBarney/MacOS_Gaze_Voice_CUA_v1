# HeyClicky decompile vs Jev Voice — comparison audit

Date: 2026-10-03. Source: `/Users/karanvirkang/Code/Clicky_Decompile`
(HeyClicky 1.0.53, build 64, decompiled DMG + 18 mirror docs + extracted
prompts/skills). Compared against `Sources/` of this repo. Per instruction:
assume their choices are more correct unless the code proves otherwise.

**Headline correction first**: the open-source `farzaa/clicky` repo is not
the product. Production HeyClicky is a ~85MB SwiftUI app + a vendored
Codex-CLI agent runtime (206MB/arch) + embedded `cua-driver` 0.28.2 +
TypeSafe Jev fast lane + a backend (`api.heyclicky.com`) doing auth,
session mint, billing, and server-side tools. It is 3 products in one:
voice companion, agent platform, computer-use engine.

We overlap them on ~35% of the stack (Cua + Jev). They are strictly ahead
on voice UX, consent UX, screenshots, onboarding, memory, integrations,
and packaging. We are ahead on local-only operation, honest-outcome rigor,
and total code simplicity for the control path.

## The architectural mirror

| Layer | HeyClicky | Jev Voice (ours) | Verdict |
|---|---|---|---|
| Voice capture | OpenAI Realtime (gpt-realtime), duplex AEC, barge-in, always-on via triple-tap ctrl | Apple SpeechAnalyzer, on-device, Fn hold-to-talk | They: conversational + hands-free. Ours: private, offline. Both valid; theirs matches the product better |
| STT | Deepgram streaming (+Apple fallback, correction learner) | SpeechAnalyzer only | Ours private; theirs has a learned dictionary — big for jargon/names |
| Brain (planning) | GPT-6/5.6 class LLM via their proxy | Jev (System One classifier) doing planning via 19-question battery | **Theirs — the core lesson** |
| Brain (per-step) | Jev `suggest_action`/`drive_until` (~250ms/step, one judgment) | Jev per-step judge (lanes + done + postcondition + risk) | Same model, same idea; theirs is a smaller contract |
| Executor | `cua-driver` 0.28.2 embedded, `computer-use` MCP | `cua-driver` 0.32.0 external app, direct MCP | Ours is the newer pin; theirs embeds it for TCC attribution |
| Consent | Per-turn natural-language ask → Allow card → bare voice "yes" resolves | Per-action risk gate + standing grants, button-only | **Theirs** — voice-answerable |
| Agent layer | Full Codex CLI per "Clicky" (filesystem, shell, MCP, memory, routines) | None — Jev decides everything | Out of scope for us today |
| Integrations | Composio MCP (Gmail/Notion/Linear/…) | None | Out of scope for v1 |
| Screen awareness | Screenshot every voice turn; tree+PNG every snapshot; annotation overlay | `include_screenshot:false` everywhere — the loop is blind | **Theirs** |
| Memory | Per-agent `AGENTS.md` + server `/user_memory` | In-memory dialogue only | Theirs (but skip for v1) |
| Distribution | DMG + Sparkle updates + notarized-ish direct download | `make app` zip | Theirs |
| TCC story | Driver embedded → one permission story (HeyClicky) | CuaDriver.app separate → two permission stories | **Theirs** — matters for friends |

## The single biggest lesson: they never ask Jev to plan

Their split: **a general LLM plans; Jev picks pixels.** `drive_until` is
one typed judgment per step: `{element_token, kind ∈ {press|type|none},
confidence, done, blocked}` over a *projected* list of
named/enabled/interactive elements — ~250ms, ~0.5s/step, no LLM turn per
click. The LLM handles `blocked`/`needs_text`/low-confidence handoffs,
menus, text composition, and multi-window orchestration.

We ask Jev to do both jobs. `CuaTaskAgent.decide()`'s 19-question battery
(operation, app, scope, content mode, literal ranges, relationships,
prerequisites, review scope, insertion style, punctuation mode, launch
receipts…) is Jev doing planner work it wasn't designed for — and most
of `CuaDialogueState` + `CuaVoiceRuntime` exists to compensate. This is
the real root of the "overbuilt" feeling: not too much code, a wrong
assignment of cognition.

Their exact contract worth mirroring (`drive_until` params):

```
goal:            ONE literal sentence naming the end state
values:          {"field label": "text"}   ← Jev picks fields, never writes text
deny:            ["Send","Delete","Pay"]   ← label substrings never pressable,
                  enforced in code before asking AND on the answer
success_contains: ["…"]                    ← caller-supplied deterministic done-check
max_steps:       bounded, returns history for resume
statuses:        done · handed_back{low_confidence|no_candidate|
                 no_interactive_elements|untrusted_answer} ·
                 blocked(login wall/dialog/permission) · needs_text ·
                 blocked_by_consent · max_steps
```

What that buys over our per-step judge:

1. **`values` kills a whole failure class.** Our model emits literal
   text (`textPayload`, `punctuationMode`, `insertionStyle` questions
   exist to babysit it). Their loop never lets the model write text —
   the caller maps field labels to strings. Delete-able machinery for us
   if we adopt it.
2. **`deny` in code beats our keyword risk gate.** Their list is
   enforced on the element *label*, twice. Our `riskDescription` matches
   keywords in the goal — and provably misses "Press cmd+q" (live this
   week: the gate caught "Press delete" only because the word survived).
3. **`confidence` is load-bearing.** <0.5 = "guessing, hand it back".
   Ours: `JevSelection.read` validates confidence ∈ [0,1] then ignores it;
   `confidenceThreshold` is dead config. They convert model uncertainty
   into an escalation signal; we don't.
4. **Degrade path.** "Jev rate-limited → decide this step yourself" —
   the LLM substitutes. Ours: Jev down = everything down (this morning's
   URLSession cancel killed the entire pipeline).
5. **`needs_text` + `no_interactive_elements` statuses** give the
   planner actionable next moves — screenshot → pixel click. Ours can't
   escalate past AX at all.

## Where theirs is provably better (and cheap to adopt)

1. **Consent is one natural-language ask per turn, answerable by voice.**
   `<COMPUTER_USE_REQUEST>I need to take over your screen for a minute
   to open Notes and type — mind?</…>` → Allow/Not-now card →
   `sessions_answer_request` resolves a bare "yes". Ours pops Confirm/
   Cancel buttons a voice-only user cannot click. This is *the* fix for
   our stated customer.
2. **Browser work = a NEW window of the default browser**, driven by
   generic window tools:
   `launch_app(creates_new_application_instance: true,
   additional_arguments: ["--new-window", url])`. Logged-in profile for
   free, one window per task, user's own windows are read-only. Their
   prompt literally hides `browser_*` tools from the agent. Our
   `browser_prepare` + `existing-profile` grant + `CuaDaemonControl` +
   CDP lanes is strictly more capable for "drive my current tab" but
   costs a standing-grant subsystem. Their pattern covers ~90% of
   browser asks with 0% of the machinery.
3. **Every input call carries `delivery_mode:"background"`** — enforced
   by a daemon-side Rego policy (`default allow=false`; `scope=desktop`
   refused; cmd+L / tab-switch chords / cmd+shift+G blocked as
   focus-steals). Ours sends `delivery_mode` only on the fast-lane type;
   loop lanes send none. Even where foreground is our product intent,
   background *delivery* is harmless — send it everywhere except
   `appControl` focus.
4. **`get_window_state` returns tree + screenshot together**; they
   reason over both ("the tree says what's clickable; the screenshot
   says which one"). Pixel clicks `{pid,window_id,x,y}` are the second
   escalation rung — posts to the pid, never moves the real cursor.
   Our loop snapshots with `include_screenshot:false` and dead-ends on
   AX-invisible controls (Electron apps).
5. **`set_value` tool** for sliders/fields — also their documented
   workaround for the minimized-window keyboard-commit no-op. We don't
   expose it.
6. **`launch_app` as the canonical entry**: idempotent, returns
   `pid` + `windows[]` (upstream added the windows array; the SKILL
   says "always start with launch_app — no list_apps hop"). We still
   do `list_apps` → `launch_app` → `list_windows` — a call we can
   usually collapse.
7. **Driver honesty fields are the first verification.** Every action
   returns `path`/`verified`/`effect`(`confirmed|unverifiable|
   suspected_noop`)/`escalation`. Their loop re-snapshots only when the
   action didn't self-verify → saves a driver call per step. We always
   re-observe — more conservative but ~1 extra round-trip ×N steps. We
   don't read `escalation` at all.
8. **`actions` list advisory — "try the click first"**, pivot on the
   returned AX error. My earlier fix restricts click offers to
   press-advertising roles; their evidence: Chrome omnibox `AXMenuItem`
   accepts `AXPress` without advertising it. We're over-conservative —
   better: offer interactive elements broadly, treat per-element
   AXPress refusal as a localized fault (retire *that element*, not
   the lane family... except the `same_pid_keyboard_ambiguity` case
   which IS a pid-level fact — that fix stays).
9. **Always-on mode** (triple-tap ctrl) + barge-in + spoken answers.
   For motor-impaired users hold-Fn is a barrier; a latch is table
   stakes. Confirmed in production, not just their marketing.
10. **Dictation is its own hotkey + pipeline** (`fn+ctrl`): everything
    spoken is text by construction — no intent classification at all —
    plus a correction learner and focus-context injection. Our dictate
    path runs utterances through intent parsing; separating it deletes
    the literal-parsing edge cases *and* makes dictation bulletproof.
11. **Embedded driver → TCC attributes to the app.** One permission
    story ("Allow HeyClicky to control your Mac") vs our two (Jev Voice
    + CuaDriver.app). For shipping to friends this is the difference
    between 2 prompts and 4.
12. **30+ sound effects + voice previews + hatching animations.** The
    polish layer. `agent_needs_you.wav`, done-chimes, error sounds —
    all cheap `NSSound`.
13. **Screen annotation** (`[TARGET:x,y,r:label]` protocol +
    `ElementLocationDetector`) — they draw arrows on the user's screen
    for guided help. The "walk me through it" mode for disabled users.
14. **Onboarding interview → starter cast** — famously praised. Our
    onboarding is a manual "Test Cua + Jev" button.

## Where ours is equal or genuinely better (don't copy)

1. **Honest outcome taxonomy.** Our
   verified/partial/uncertain/blocked/failed + "delivery ≠ proven" is
   stricter than their effect-field + model-judgment reporting. Their
   big model papers over ambiguity; ours refuses to. Keep it.
2. **No blind mutation retries, cancellation preserves uncertainty,
   generation tokens, stale-response rejection** — more rigorous than
   their documented behavior. Keep.
3. **On-device STT, no account, no backend, no telemetry.** Their audio
   streams to OpenAI via their proxy; a friend can run ours with a
   TypeSafe key. Massive distribution + privacy advantage for a
   small-team product.
4. **Simple commands are faster.** Transcript → Jev → act ≈ <1s for
   "open Spotify". Their path: realtime turn → tool call → agent
   turn → … seconds. Our fast lanes beat theirs for one-shot verbs.
5. **Interaction-scoped cancel** (Escape kills only this capture's
   work; question survives for next hold). Their supersede model is
   comparable, not better.
6. **`invoke_menu`/`bring_to_front`/foreground delivery exist for us.**
   Their no-foreground contract is for background agents; our product
   is a *control* surface — the user watches. Foreground on demand is
   correct for us. (Menus: their AXMenuBar caveat stands — menu
   actions go DISABLED on non-key apps, so a menu lane is
   frontmost-only by nature.)
7. **Our test suite (306 tests)** vs their ~2 stub test files. The
   ledger/coordinator races we test are the code that bites.

## What they proved about the parts we got wrong

- **Confidence is a signal, not a metric.** Wire it or delete the
  field. Their <0.5 → hand-back is the pattern.
- **The deny list must be in code**, on element labels, not in goal
  keywords. Move risk from prompt-matching to label-matching, checked
  pre-offer and post-answer.
- **Let the caller own text.** `values{field: text}` removes literal-
  text emission from the model contract.
- **Screenshots are not optional.** `include_screenshot:false` made
  our loop blind to same-label elements and AX-poor apps.
- **Approvals need a voice route.** Bare yes/no → pending request.
- **One permission story.** Embed the driver or accept onboarding drag.

## Recommended adoption order (for "Clicky but more", disabled users)

**Phase 1 — correctness, zero new machinery:**
1. `delivery_mode:"background"` on all element/window-scoped lanes
   (keep `appControl` focus as the explicit foreground path).
2. Deny-list in code on offered element labels (replace/augment
   keyword risk gate): Send, Delete, Pay, Empty Trash, purchase verbs —
   checked pre-offer and on the model's pick. Also gate cmd+q/cmd+w.
3. Read driver honesty fields (`effect`/`verified`/`escalation`) —
   skip re-observe on `confirmed`, escalate on `suspected_noop`.
4. Confidence floor: Jev confidence < ~0.5 → clarify/hand-back, not
   action. Wire `confidenceThreshold` or delete it.
5. `JevClient` request timeout (~20s).
6. Pixel-click + `set_value` + `browser_dialog` lanes; include
   screenshot when candidates < threshold or AX empty.
7. Collapse `list_apps`→`launch_app`→`list_windows` to `launch_app`
   windows array where upstream returns it.

**Phase 2 — the voice product:**
8. Spoken feedback + spoken clarifications (AVSpeechSynthesizer; their
   `<SUMMARY>`-when-not-looking pattern).
9. Latch mode (tap Fn on/off) + triple-tap always-on later.
10. Voice-answerable approvals/clarifications (bare yes/no, numbered
    options) through the existing answer path.
11. Dedicated dictation hotkey: everything spoken = text, focus-context
    injection, no intent parsing.
12. Per-turn natural-language consent ask replacing per-action buttons.

**Phase 3 — capability:**
13. New-window browser pattern as the default; keep existing-profile
    CDP only for "drive my current tab" asks.
14. `invoke_menu` lane scoped to frontmost/just-focused targets.
15. Screenshot-aware higher-model turns (their `send_to_higher_model`)
    using the already-configured text provider — this is also the
    "what's on my screen / help me" mode.
16. Embedded driver (one permission story) + onboarding checklist +
    Sparkle.
17. Screen annotation for guided help (we already have element frames).

**Phase 4 — later:** persistent agents/memory, routines, integrations
(Composio), skills-as-data, TTS personas.

## The one-line version

HeyClicky puts a big model in charge and Jev in the fast lane; we put
Jev in charge and built scaffolding to hold it up. The fixes are not
"more Jev questions" — they are: give Jev the contract it was designed
for (element+kind+confidence+done+deny), give planning/text/ambiguity to
a language model (BYOK provider we already ship), and give the user a
voice that talks back.
