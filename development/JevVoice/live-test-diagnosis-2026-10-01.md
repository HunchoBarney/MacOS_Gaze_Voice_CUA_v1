# Live-test diagnosis and architecture report — 2026-10-01

Investigation requested after repeated live-test failures ("didn't do the job
correctly and also was super slow"). Read-only: no source, pin, credential or
installed-app changes. Evidence sources: the deleted `docs/` tree recovered
from git history (`a93f7d1` removed it; recovered to `/tmp/jarvis-docs/docs/` —
`voice-ui/EVIDENCE.md` is the 1,717-line ledger), current source, `git log`,
and current TypeSafe/Cua documentation. Simulated, recorded-audio, packaged and
physical results are kept separate throughout.

## Bottom line

The architecture is directionally right (it is the same pattern as TypeSafe's
official `jev-use` Cua recipe) but the implementation over-delivers on safety
machinery and under-delivers on the hot path. Jev is not the main problem —
project evals measured ~90–95% valid decisions. Most live failures were the
runtime miscomposing good decisions, Cua Driver contract gaps, and serial
round-trips stacking up. There is no "Julia" model; `jev-1.13.0` is the only
System One model TypeSafe ships. A reasoning model in the hot loop makes
one-shots slower, not better — it belongs in an escalation lane for multi-step
work.

## 1. Verified live failures → root causes

| What was observed | Evidence | Root cause |
| --- | --- | --- |
| "Open Google and search weather in Yuba City" died mid-task | Activity: `launch_app` returned at 2,285 ms then repeated `list_windows` until the 32-action bound; dependents inherited the failed prerequisite | Launched window never observable inside the poll window; tied to the pinned launch watchdog's ~8 s foreground-restore conflict (`native-settled-live.log` passed only with a 9 s diagnostic wait) |
| "Pinned target window closed" ×3 on follow-ups | physical trial sheet, `physical-activity-initial.png` | A remembered window ID passed into a new task as authority; absent from the app's current window list → refusal. Fixed in the 2026-09-30 dialogue rework — never run live |
| "Speech didn't finish in time", empty transcript | packaged Activity on the perception-integration build | Quick-release holds produce no transcript — recognition deadline races short holds; recorded audio passes the same 2 s deadline, physical quick taps do not |
| `invoke_menu` refused | `jarvis-menu-diagnostic.log`, `element_outside_target_window` | Upstream `invoke_menu` unconditionally calls `focus_exact_window`; background menu invocation is a Driver limitation, not a model error |
| Scroll reported complete after one effect, then clicked wrong element | `scroll-installed-live-2026-09-23.log` | Pinned Driver cannot verify scroll effect; Jev `done` was accepted → false completion. Guard now refuses — but the workflow still cannot succeed on the pin |
| Text inserted twice (57 chars vs expected) | `native-text-window-repaired-live.log` | Replay suppression keyed on action description; the field label changed between steps → suppression missed → duplicate mutation |
| All 30 warm trials failed | `jarvis-warm-30.log` | Screen locked — `loginwindow` foreground, every activation refused. Not a code bug, but the app failed silently instead of reporting "screen is locked" |
| Mic preparation loop (324/min) | `.context/simplification/audio-configuration.log` | Config-observer regression introduced by the simplification extraction; fixed in `459df5e` |
| Draft generation died mid-task | `jarvis-cua-groq-summary-429-1753.log` + repeats | Groq HTTP 429 — provider rate limit ends the task instead of honoring retry-after |
| Permissions re-prompted on rebuild | multiple samples; `SecurityAgent` blocking `SecItemCopyMatching` | Ad-hoc re-signing changes the binary each build → macOS invalidates Mic/Accessibility grants; also blocked startup on a Keychain prompt |
| "Open something" borrowed Calculator as target | `jarvis-ambiguous-before.log` → `jarvis-target-catalog-live.log` | Jev read vague request too literally against context; fixed by clarifying the app-target question |

## 2. Latency budget — where the time goes

Measured stage timings from the evidence ledger:

| Stage | Measured |
| --- | --- |
| Fn → overlay | ~32–44 ms |
| Mic ready / first audio (warm) | 36–153 ms after the ready-mic rework (was 219–957 ms) |
| Speech finalization on release | 60–270 ms |
| Transcript → handoff decision (warm) | median ~136–153 ms |
| Single Jev call | ~200–800 ms |
| `start_session` + `list_apps` refresh | 2 Driver calls per task |
| Per `run()` iteration | observe (1–3 Driver calls @ 0.3–1.2 s) → choose (1 Jev) → risk + windowEffect + repeatIntent (1 Jev) → dispatch (1 Driver) → postcondition observe |
| `launch_app` | ~2.3 s |
| `get_window_state` / `invoke_menu` / `bring_to_front` | ~1.2 / 0.44 / 0.7 s |
| Visual perception parse (OCR/icons) | **3.1–22.5 s per parse**; corpus median ~7–9 s cold |

"Open Calculator" ≈ 3–4 serial Jev round-trips + 5–8 Driver calls → ~2 s warm,
5–10 s cold/real. Measured physical one-shot: ~10 s. Comparator dictation apps
insert text 123 ms–1.1 s after recording ends (independent bench: Talkify
123 ms, superwhisper 216 ms, Wispr Flow 587 ms, Aqua Voice 630 ms, MacWhisper
1,149 ms).

The slowness is structural: each loop iteration pays model latency +
observation latency + postcondition latency serially, and the cold path adds
app-inventory scan (median 862 ms), session setup, and the launch watchdog's
window-visibility stall.

## 3. The model question

- **No "Julia" model exists.** TypeSafe's catalog contains exactly one model:
  `jev-1.13.0`; aliases `jev-latest` and `jev-preview` both resolve to it.
  `GET /v1/models` returns only the aliases.
- **Jev is working within its documented limits.** Project evals: dev 38/40
  valid, held-out 27/30 valid, 0 critical. The documented `jev-1.13`
  jaggedness (literal reading, indirection, accuracy decay on large noisy
  state, no counting/math) matches the real misses observed.
- **Reasoning model in the loop:** upstream `cua-agent` does this — Claude /
  OpenAI / Gemini VLMs driving tools per step, each a full LLM call with
  screenshot context (~1–5 s+ per step). Slower and costlier than a ~300 ms
  bounded Jev choice for one-shots. For multi-step *planning*, a reasoning
  model is more capable than chained Jev choices — the right place for it is
  plan/escalation, not per-step grounding.
- **Official `jev-use` reference** (Cua docs; needs Driver ≥ 0.23.2): per step,
  send goal + compact observation + candidate action IDs + `reobserve` +
  `abstain` as **one choice question**; Driver tool names/args never reach the
  model. Current `decide()` asks 9–19 questions in one call (`operation`,
  `task`, `relationship`, `app`, `scope`, `visibility`, `contentMode`,
  `correctionMode`, `clarification`, span/literal/replacement boundaries,
  grouped variants…) answered independently then composed in code. The
  coordination report's finding E — independent answers combined as if they
  were a coordinated plan — is where several confirmed bugs lived.

## 4. Complexity audit

The simplification effort made the code bigger:

- `ComputerControl` + core `Models`: 17 files / 1,883 lines → 19 files /
  **3,150 lines (+67%)**
- Total production: 6,708 → 7,975 lines; tests +2,821 lines
- 2026-09-30 added `CuaDialogueState` — intents/attempts/questions/facts/
  relationships — which has never been run live
  (`JARVIS_CUA_RUNTIME_DIALOGUE_TEST` never executed)

Each layer is individually defensible — provenance, read-set freshness,
verified facts, choice paging — but stacked, "open Calculator" traverses:
SpeechAnalyzer → ranged transcript → consumption ledger → context snapshot +
read-set → 9–19-question decide → dialogue prerequisite evaluation → session →
observe → paged choose → risk judge → dispatch → postcondition → loop. The
official reference does the same observe→choose→act→verify loop in a few
hundred lines of Python.

## 5. Recommended architecture — two lanes

### Lane 1 — Fast path (one-shots, ~80% of usage)

For "open X" / "search Y" / "type Z" / "switch to app" — operations needing no
in-loop judgment:

1. Slim `decide()` to ~5 questions: operation, app, span, literal payload,
   stop/target.
2. Dispatch directly: `launch_app` / `bring_to_front` / `browser_navigate` /
   `type_text` with the exact literal span copied in code (`SpeechSpan.copy` —
   no model-generated text, already correct).
3. One postcondition check. No observe→choose loop, no risk judge for
   non-destructive ops.
4. Risk classification → deterministic keyword gate (send/delete/purchase),
   not a Jev call per step.

Target: <1 s warm, <2 s cold transcript→effect. Achievable — warm handoff is
already ~150 ms; the remainder is Driver calls the fast path mostly skips.

### Lane 2 — Agent loop (multi-step)

1. Per-step decision shaped like `jev-use`: one choice question over candidate
   action IDs + `done` / `reobserve` / `abstain`. No composition.
2. Replace the 32-action bound with a time/iteration budget plus a bounded
   wait-for-window state (jittered re-observe), so launched apps that take
   5–9 s to surface a window don't exhaust the task.
3. Escalation: when Jev abstains or an iteration fails once, send the same
   compact observation to the configured text provider (Groq or another
   OpenAI-compatible endpoint) for a *plan*, executed through the same Jev
   loop — advisory only, matching SPEC S6. This is where a reasoning model
   earns its keep.

### Dictation

Drop owned-range mid-hold streaming (blocked on a Driver contract that does
not exist). Insert-on-release: copy the exact literal span deterministically,
dispatch once, one readback. This is the competitor approach and it is
reliable.

### Continuous session

Keep the consumption ledger — it caught real double-effect bugs. Replace the
context read-set/revision freshness machinery with what the code already
guarantees: targets rebind from fresh observation at dispatch time.

### Driver — install the candidate patches

Highest-leverage available change. Three combined patches are built,
SHA-verified, and each has a passing isolated live proof: launch-watchdog fix
(the ~8 s foreground stall behind the Google-search failure), scroll readback
(the false-completion class), menu-focus (stale NSWorkspace readiness). They
sit uninstalled in `ThirdParty/Cua/` (`launch-watchdog-candidate.patch`,
`scroll-readback-candidate.patch`, `menu-focus-candidate.patch`; combined
candidate SHA-256 `a4fcfdd7a74c317ecd4a9364a59c745c1975c5c6262f5fafad6c31dcd3381624`
/ scroll-reviewed `483b6930…`). Replacing the pinned binary needs explicit
sign-off per `AGENTS.md` — but the pinned build is what produces three of the
largest failure classes.

### Environment / shell fixes (cheap, high-yield)

- Detect locked console → report "unlock your Mac" instead of silent failure.
- Quick-release empty transcript: the 2 s finalization deadline races short
  holds — fix EOS handling or give the pill a "hold a beat" affordance.
- Honor Groq `Retry-After` before failing a generation task.
- Sign dev builds with a stable local identity instead of ad-hoc → stops the
  TCC re-grant churn that makes every test session start with permission
  confusion.

## 6. Keep vs. cut

Keep: SpeechAnalyzer pipeline (36–105 ms first audio), consumption ledger,
`JevClient`, span-copy literal extraction, candidate-ID pattern, pinned-driver
verification, Keychain handling.

Cut or collapse: `CuaDialogueState` → small intent registry (focus + pending
question, not a graph); the 9–19-question decide battery → ~5 questions;
per-step risk/windowEffect/repeatIntent judges → deterministic rules +
clarify; group/offset word paging → cap realistic command length (252-word
Choice bound covers real speech); provenance chains → keep IDs only where the
UI surfaces them.

## 7. Proof status — honest bottom line

| Claim | Status |
| --- | --- |
| Fast mic + fast Jev decision | Proven: 36–105 ms first audio, ~150 ms warm handoff |
| One-shot open works | Proven warm in harness (median ~813 ms, 30/30); cold/physical ~2–10 s and flaky |
| Multi-step tasks | Partially proven in disposable fixtures; failed on the real Google-search run; dialogue rework untested live |
| Dictation | Never passed — owned-range reconciliation blocked on a missing Driver contract; insert-on-release works in fixtures |
| Continuous session | Partially simulated; physical trials show speech timeouts and target-loss failures |
| Sep 30 coordination layer | 341 unit tests pass, zero live runs |

The gap between "tests pass" and "it works" concentrates in three places: the
Driver's contract gaps (three patches ready), the serial multi-call loop
architecture (fixable via the fast-path split), and unproven machinery added
in the last rework (deletable). Swapping Jev for a reasoning model addresses
none of those — it improves phrasing robustness on complex commands, which is
why it belongs in the escalation lane, not the driver's seat.

**Suggested first move (before any restructure):** install the combined Driver
candidate, then rerun the same live tests against the current build. That
removes the watchdog stall, the menu refusal, and the scroll false-completion —
likely most of what felt broken.

## Follow-up (same day, evening): Calculator "add 7+7" — fixed end-to-end

The reported failure (display stopped at `7+`, status claimed Completed) was two
compounding bugs, both now covered:

1. **False completion.** `done` was accepted on action history alone. A
   `doneEvidence` question now runs at completion time: Jev must classify the
   observed evidence as `proven` (readable app/visual state or a verified
   postcondition) or the claim is rejected back into the loop. Unverifiable
   tasks end `Failed`/`Blocked`, never `Completed`.
2. **Miscountable button sequences.** Clicking Calculator's AX buttons per
   operand dropped the second `7` (and once substituted `8`). A request with
   exactly one symbolic expression now produces a bound `type_text_chars`
   candidate (`type_chars_only: true`, process-scoped `post_to_pid` — no focus
   steal, no wrong-app risk) whose `text` is extracted deterministically from
   the request (`keyboardExpression(in:)`), with `=` appended when a
   result-seeking verb is present. Buttons whose labels would re-type the
   expression (`7`, `Add`, `Equals`) are suppressed for that window so the
   blind-click path can't compete. Unlabeled `AXPress` elements are no longer
   click candidates at all — one such click closed a window mid-task.

Verified live twice via `testCalculatorMathReproOptIn` under the desktop lock:
All Clear → `type_text_chars` textLength 4 (`"7+7="`) → `parse_visual_regions`
→ doneEvidence `proven` → `Completed`. ~1 mutation each instead of ~22 calls.

Unit: 169 focused tests pass; `keyboardExpression` and the suppression/name
guards are covered in `CuaActionCatalogTests`; the done gate is covered in
`CuaTaskAgentTests` (two unproven claims → `.blocked`, honest message).

## Follow-up (same day, late): clarification deadlock + Chrome tab scope — fixed

User report: "can you open a new tab in google with my google chrome open" kept
re-asking "which task do you mean" and replies couldn't resolve it. Three bugs:

1. **Answer binding discarded.** `decide()` returned early on `operation ==
   .clarify` / `span == "clarify"/"wait"/"ignore"` *before* reading
   `pendingQuestion`/`relationship`, so a reply Jev correctly classified as
   `relationship=answer` + `pendingQuestion=<id>` was dropped and the question
   re-asked — the deadlock loop. Now `relationship`/`pendingQuestion` are read
   first; a bound answer (non-control operation) bypasses the ambiguous
   early-returns and flows through the normal construction so it keeps
   `selectedTaskID`, `intentRevision`, and the owner-target app fallback.
   Stop/stopAll/correction keep priority — control is never swallowed as an
   answer. Answers with unparseable spans consume the full pending range.
   Single-question pending + `relationship=answer` + `pendingQuestion=none`
   binds the one question (pre-existing fallback, now honored pre-return).
2. **`.task` clarify offered with no tasks.** "Which task do you mean?" is
   unanswerable when `task_context` is empty. `invalidComposition` now degrades
   to `.operation` ("what would you like me to do") when `taskChoices` has no
   real tasks and no questions are pending.
3. **Browser tab classified `create`.** Decide-level scope rules said
   `create = new top-level document/window`, so "new tab" demanded a new
   native window via `new_window_observed` — a Chrome tab never produces one →
   guaranteed failure. The decide criteria now state a tab inside an existing
   browser window is `work`. Verified live: the user's exact transcript →
   `execute`, Google Chrome, `scope=work`; "open a new tab" alone →
   `clarify/target` (answerable "which app").

Residual nondeterminism: a vague reply can still arrive as `independent`
(Jev's call), but it now degrades to an answerable question instead of an
unanswerable task loop.

## Follow-up (same day, late): literal-mode payload clobbering — fixed

A rerun of the Calculator repro dispatched `type_text_chars` with a 7-char
payload (`"Add 7+7"`) instead of the bound `"7+7="`. Cause: Jev nondeterministically
picked `contentMode=literal`, selected the whole request as literal source
(verb included), and the run loop stamped `literal` onto every `requiresText`
action unconditionally — overwriting the catalog's deterministic bound text.
Now `literal`/`generated` fill only when `arguments["text"] == nil`; a bound
payload is exact by construction and wins. Same reason `inspectVisual` is no
longer hidden under `literal != nil` — element-less keyboard targets have no
other evidence path, and the choice is read-only.

## Follow-up (same day, late): expression-suppression extended to OCR labels

After the bound dispatch landed, Jev clicked an OCR'd "+" region — re-entering
the operator mid-expression. Visual click actions now get the same suppression
as AX buttons: when `expressionControlNames(in: goal)` is non-nil, visual click
candidates whose parsed label (from `Click visual <kind> <label> [region <id>]`)
matches are filtered out. Verified live: Clear → `type_text_chars` (4) → OCR →
doneEvidence `proven` → `Completed`; full suite 345 tests, 0 failures.

Known remaining flake: `testClarificationAnswerResumeBindsOwnerOptIn` (live,
opt-in) fails waiting for its freshly-compiled fixture app's two windows to
appear in `list_windows` — the fixture process launches and stays alive; Cua
doesn't observe the windows within the poll. Harness/environment issue, not a
runtime regression — `list_windows` returns correct data for real apps
(Calculator run used it 9x in the same session).

## "Open a new tab in Google Chrome" — three stacked bugs, all fixed live

User report: repeated clarifications ("Which window should I use?"), then silent
failure. The unified decision log (`com.chriswozniczek.jevvoice.cua`) showed
decide() was already correct (execute/Chrome/work, answer bound) — the failures
were all in execution.

1. **Phantom window pollution.** `list_windows` returns ~10 Chrome surfaces:
   one real document window plus 1×1/1440×30 off-screen helpers *and* tiny
   untitled on-screen chips (e.g. 125×22 tab-hover preview, `is_on_screen=true`).
   The scope=work branch offered all of them to Jev → "none" → refused.
   Fix: plausible-candidate filter is now titled-first — on-screen **and**
   titled; falls back to all-visible only when nothing titled exists (so a lone
   untitled real window still works), then titled-anywhere for hidden apps.
   Same ordering applied to the launch/create z_index pick.
   (`CuaTaskAgent.swift` work/create window-selection branches.)

2. **`browser_consent_required` was fatal.** Chrome refuses `get_browser_state`
   until the user grants introspection consent; the refusal propagated and
   killed the run. Fix: the run-loop catch sets `browserConsentDenied` and
   continues with `browser = nil` — native path serves browser *chrome*
   (tabs, menus, toolbar — all AX-visible and verifiable). Crucially,
   `includeEmbeddedWebControls` is now gated on `!browserConsentDenied` at both
   catalog sites, so AXWebArea page content is never offered for blind native
   input — preserving the CuaBrowserTests contract that consent refusal must
   not fall back to native web input. `discover()` still throws; the test
   passes unchanged.

3. **`awaitingNewWindow` had no deadline.** Jev mislabeled the New Tab click
   `windowEffect: new` → the loop polled `list_windows` ~30× until the 32-action
   budget died — even though the click had already created the tab (verified:
   "New Tab" AXRadioButton present). Fix: `maximumNewWindowPolls = 8` (~1.2s+);
   on expiry the flag clears and normal observation judges the post-action
   state — `new_window_observed` is still computed every round, so a window
   that arrives late still counts. Pinned-window-closed refusal is untouched.

Verified with a new opt-in live test (`testChromeNewTabReproOptIn`,
`JARVIS_CUA_CHROME_TAB_TEST=1`, desktop lock): decide → execute/Chrome/work,
window auto-picked with no question, `Press AXButton New Tab` dispatched once,
bounded wait expired, `doneEvidence: proven` → `Completed`, tab labels gained a
real "New Tab" radio (7→8, 8→9 across runs; label-set assertion survives
Chrome's suspension renames like "…Inactive tab - N MB freed up"). ~6.5s
end-to-end, one click, ~10 driver calls.

Full suite: 346 tests, 0 failures. Release app rebuilt and relaunched.

Caveat for future reports: Chrome tab-count assertions must compare label
sets, not counts — background tabs suspend and leave the AX radio list.

## "Browser DOM consent" — full pipeline wired + verified live (same day, late)

User asked how to grant browser DOM consent, then approved wiring the
`existing_profile` prepare path into the app with standing grant ("full
permissions across apps"). Four layers, all now in:

1. **Daemon grant reconciliation** (`CuaDaemonControl.swift` — new).
   `--grant existing-profile` is a `serve`-time flag; `mcp` proxying can't add
   it to a running daemon. `CuaConnection.connect()` now ensures the daemon
   runs with it: `pgrep` the daemon, check its argv for the grant, relaunch
   via `open -a … --args serve --grant …` when missing (keeps TCC attribution —
   `open` launches the app bundle). A persisted UserDefaults flag skips the
   check after the first reconcile; a `browser_consent_required` refusal
   clears it so the next task re-reconciles. Verified live: daemon running as
   `cua-driver-local serve --grant existing-profile` (pid confirmed).

2. **Per-task consent flow** (`CuaTaskAgent.swift`). On
   `browser_consent_required` the agent asks via the existing `work.approval`
   pill (Confirm/Cancel — the consent moment stays explicit), then calls
   `browser_prepare {kind: existing_profile}` → re-`bind`s. On real Chrome the
   endpoint was already live (remote debugging on), so prepare returned
   `attached_existing_profile` with zero side effects. The flow sets a
   `consentFlowRan` flag → `continue` rebuilds windows/state/catalog fresh —
   the pre-consent snapshot is seconds old by then and Chrome's volatile tab
   labels ("…Memory usage 267 MB") made the stale re-match fail with "target
   changed while deciding". First live pass after this fix: approve → attach →
   fresh catalog → `Press AXButton New Tab` ×1 → `doneEvidence: proven` →
   Completed, tabs 10→11, ~8s.

3. **Ambiguous active-tab → graceful degrade** (`CuaBrowserTarget.bind`).
   The driver is honest-by-design: `binding_quality=exact`,
   `mutation_allowed=true`, but if the native window title collides with N
   same-named tabs ("New Tab" ×4 vs window title "New Tab"),
   `selected_tab_target_id` returns none → zero active tabs → bind refuses
   "tab identity ambiguous". That refusal now degrades to the native
   chrome-only catalog instead of killing the task — do NOT weaken the
   no-guessing contract at the driver.

4. **Bound-browser can't express chrome intents → release once.** No
   `browser_new_tab` tool exists — DOM actions can't touch the tab strip. When
   bound and Jev picks `blocked` (or claims done with nothing dispatched), the
   binding is released once → `continue` → native chrome path serves
   tabs/menus. Verified live: bind succeeded → Jev picked inspectVisual →
   blocked → release → native chrome → completed.

## Companion fixes from the same debug session

- **False-done on pre-existing state.** Jev claimed `done` + judge said
  `proven` because a "New Tab" tab was already frontmost before the task ran —
  zero dispatches, state matched. The evidence state now carries
  `mutations_dispatched`, `browser_mutation_dispatched` booleans plus a
  churn-stable `state_at_start` signature (sorted `role|label` + window count
  — NOT the raw AX tree, which re-indexes constantly), and the `done` choice
  text says a create/open request needs something *newly produced* — an
  identical pre-existing instance doesn't count.
- **Repeat guard was dead under churn.** `effectIdentity` embedded
  `element_index`, which shifts every time the AX tree re-indexes → the same
  "New Tab" button got a fresh identity each round → `repeatIntent` never
  fired → one run dispatched click ×5 (tabs 11→16) before the budget died.
  Native actions now key repeats on a semantic `role:name` identity; exact
  `bindingIdentity`/`preconditionIdentity` still govern re-match.
- **Jev `max_tokens_exceeded` on real Chrome pages.** The full DOM snapshot
  (hundreds of refs) + full `windows`/`visual_regions` + duplicated
  `observation_at_start` overflowed the decide call. The *decision payload* is
  now projected: `decisionPage` (tab count + capped compact refs + bounded
  outline), `regions` compacted to label+bounds-approx, `windows` to a bounded
  list, and the at-start evidence reduced to a signature + booleans. The full
  catalog still holds exact refs for dispatch/re-match — grounding is intact;
  only the model's view is bounded. Visual click actions are no longer offered
  while a DOM binding exists (blind native input on page content).
- **Reverted, on purpose:** auto-retry of stale re-matches and exposing native
  menus alongside the bound DOM catalog — both broke pinned tests
  (`testNativeRefreshRejectsButtonWhoseMeaningChangesDuringRiskJudgment`,
  `testConfirmationIsExactSingleUseAndChangedContentStopsDispatch`,
  `testBoundBrowserPageChoicesExcludeNativeChromeMenus`). The
  `continue`-after-consent and blocked-release cover the real failures without
  weakening stale-target safety.

Verified: `testChromeNewTabReproOptIn` passes — the trace shows consent prompt
→ prepare → bind → release-on-blocked → native chrome → Completed, tabs +1.
Focused suites 171/0; full suite 346/0. Release app rebuilt (pid relaunched).

Residual nondeterminism (Jev's): it burned two exploratory clicks this run —
an OCR "New Tab" *tab label* (tab-switch, not create) and a "+" region —
before the real AXButton. The evidence gate correctly refused `done` until a
real new tab existed, so the waste was bounded and the outcome honest. That is
model-iteration cost, not a structural bug.

## Standing grants — ask once, remember (same day, late)

User: permission prompts keep repeating. `browser_consent_required` re-asked
on every task; `invoke_menu` background-focus asked per action. New
`CuaStandingGrants` (`Sources/JevVoice/ComputerControl/CuaStandingGrants.swift`)
persists capability grants in UserDefaults:

- `browserPageAccess` — first "Allow page content?" approval is stored; later
  consent refusals run `browser_prepare` silently. Covers Chrome restarts —
  the endpoint dies with the process and prepare re-toggles the browser's own
  remote-debugging switch without re-asking.
- `menuFocus(bundle:)` — the "Temporarily focus X for a menu" prompt grants
  per bundle and persists; the driver still restores focus afterward.

NOT persisted, on purpose — per-action confirmations that gate distinct
consequential operations each time: file upload to a site, JS-dialog accept,
window-frame set, isolated-profile window spawn, and the deletion/purchase
risk tier. Those describe a one-off side effect, not a capability.

Settings → Command confirmation gained "Reset remembered permissions"
(`CuaStandingGrants.reset()` clears all grants; next task re-asks).

Verified: live Chrome test passes (prompt seen once, auto-approved, silent
`browser_prepare`, tab created 8→9, Completed in ~11 s). Full suite 346/0.
First real-app browser task after this build will ask once, then never again.
