# Jev Voice: C1 → C2 → C3

Delivery map v2 · 2026-11-17 · KAR-22. Start with one reversible task through
each real entry point before broadening coverage. The examples below are tests
to earn, not a list of things the signed app can already do.

| Milestone | Current | Next user scenario | Proven when |
|---|---|---|---|
| **C1 · First minute** | Realtime and native execution landed. The later quiet candidate was signed; newer fixes are source-only. | Launch normally, hear an answer, dictate a literal into a scratch field, then look at a harmless control, ask to select it and interrupt the next action. Keep using the trackpad and keyboard throughout. | One identified signed GUI run shows genuine listening, exactly one correct insertion, the intended target's change and no late effect after Stop. Record cold and warm times; include failures. **Physical session deferred.** |
| **C2 · Useful tasks while I work** | P2 browser/agent spikes exist. A tool name, demo or successful dispatch doesn't prove an integrated task. | With controlled data, find an item in the browser, prepare a message draft, plan a calendar entry and save a note while the person types elsewhere. | From normal voice entry, independent reads find the right tab, draft, date and saved text; the person's field, selection and pointer stay theirs. A worker that needs their foreground must yield. **Live app/account cases deferred.** |
| **C3 · Private tester install** | Staging checks and retained signed candidates exist; neither establishes portability or a category win. | On a clean M1/8 GB tester Mac, install the app without a repo, complete permissions and calibration, read an email, look and open an item, then add a test event. | One frozen signed bundle completes onboarding, wake/recovery and the matched task and resource runs below. **Clean install, physical gaze/Fn and paid or live comparisons deferred.** |

## What the evidence actually covers

- **Landed:** local main `35f885125` includes R10 (`f054002`). Its
  [source/artifact review](results/P4/c1-r10-g4-artifact-review.md) is about
  those bytes. The separately recorded `origin/main` at `073fedeb1` adds
  release-verification work; it is not the dirty integration tree.
- **Signed, not accepted:** `final-first-minute-quiet-1` has a staged
  fingerprint in its [manifest](results/P12/c1-manifest-final-first-minute-quiet-1.json).
  Earlier Space attempts returned an unverified press, not observed arrival
  on Desktop 2. Retain R9-2 and R10; no daily replacement. R10's blocked
  MCP scroll, physical voice and latency/quality gaps are not repaired by
  that signature. An artifact receipt doesn't identify the next app to launch.
- **Dirty/source-tested:** the KAR-15 fake-wire named-control tests, KAR-17
  packaging fixtures and KAR-20 ask-only read counts are separate evidence,
  not features or speedups proven on that signed app. See the owning issues
  for KAR-18 admission and KAR-21 diagnostic separation, not a presumed
  merged binary. Keep source, fixture/replay, signed, provider and physical
  evidence separate; a missing observation stays open.

## C1 · Can I use the Mac normally in the first minute?

Measure normal launch → usable menu/status → **confirmed listening** (healthy
duplex audio and confirmed Realtime session) → first final → first verified
effect, cold and warm. Split permission, audio, connection and optional
tracker time; a painted menu or ready file isn't listening. Report actual
times against [PROGRAM's goals](PROGRAM.md#aggressive-interaction-goals-2026-11-15),
not an invented startup budget. Continuous conversation is the default after
permission; pause/off persists, Fn is optional. Ambient listening keeps the
screen quiet. Keep status, errors, asks, Pause/Resume and Stop discoverable;
do not trade feedback for an always-on pill over the user's work.

1. In a disposable field, dictate an exact string including a correction or
   negation and a final word. Check the full selection/value once, not partial
   text or spoken confirmation. Try a conversational follow-up and interrupt
   it: revoked work must neither speak late nor mutate a stale target.
2. Look at a harmless control and say “click this”; require a fresh resolved
   target, separate voice/click/key selection and an independently observed
   effect. Without gaze, name the control; ask one brief clarifying question
   if needed, otherwise decline safely. Never show a numbered grid or coach
   “show numbers”. This is the target for KAR-24, not a removal receipt.
   KAR-15's reader is different: only explicitly named Close or Minimize on
   the current window can qualify. “What is this?” and screen overviews don't
  authorize guessing, broad capture or sending pixels to Realtime. If onset
  didn't bind the pointed-at control, ask for its name; later gaze is not
  evidence of where the person looked when speaking.
3. Focus a running test app and return; switch to a named test Desktop and
   back. Observe actual frontmost identity and Space arrival separately. A
   press without an arrival witness is uncertain. Move the pointer or type
   mid-task: manual input wins; stop or rebind rather than steal focus.

KAR-5 owns the first-minute sequence; KAR-16 owns simplification (including
KAR-18/20/21). Stop at the first physical failure. Retest only by separate
authorization naming the signed candidate, reversible action, visible pass
condition and privacy-safe evidence. Never use personal content for a fixture.

## C2 · Can a task finish without taking over my screen?

Use the C1 final/target/stop contract. Start with a controlled Chrome page
then repeat in Safari: open the requested fixture item, read its detail,
verify the item identity and return. In a test inbox, read a message and
prepare an unsent reply; independently reopen the draft. In a test calendar,
create a reversible event after exact date/timezone/calendar confirmation;
read it back. Save a scratch note or reminder and reopen it by identity.
Cover Mail/Gmail, Slack/Messages and the rest of the four hero jobs in their
own phase populations; these first successes don't remove any of them.

For KAR-25, let a Cua worker do that task while the person continues typing
in another field. Prefer scoped background reads/actions that need no shared
pointer or focus. Serialize conflicting writes; when the only route needs
foreground input, pause and ask before taking it. Recheck target and consent
at dispatch; Stop, an intervening edit or a stale target prevents late work.
Prove the actual result through a fresh independent read, including hidden
or persisted state when required, and check the user's foreground for stray
input. A tool reply, screenshot of a toast or worker's own “done” is not proof.
Send/book/delete still require exact bound confirmation. Replay only a verified
trace with fresh locators and consent; never blindly retry an uncertain write.

## C3 · Can someone else install it and trust the results?

KAR-26 starts with C1 startup timing and ends at a clean private tester
install. Verify a relocated signed app launches without a checkout, package
manager, developer tools or warmed caches; its licensed pinned helpers and
local gaze models load from the distribution. Onboard permissions and real
browser attachment, show a remedy for denial, then complete the three real
first-run tasks. Prove calibration, correct target identity, wake and no-face
recovery with voice and eyes together on M1/8 GB. Dwell stays off by default;
when enabled, preserve the duration and look-away guard. Every gaze flow has
a non-gaze route; removing default **speech** models does not remove gaze.

Record idle CPU, steady RSS, footprint and cold/warm time to first useful
result. Freeze tasks, start states, versions, sample sizes and verifiers
before comparing. Compare exact insertion and edit burden with Wispr Flow;
compare verified computer and browser tasks with Codex Computer Use and
Browser Use. Follow the full [category scorecard](COMPETITIVE.md), including
absolute release bars, matched success, p50/p95, interventions, failures
and uncertainty. Keep the 24-clip dictation pilot separate from the ≥120-clip
held-out qualification. The three first-use moments in ≤3 minutes and 10/10
demo runs are release gates, not results. No category data means **not measured**.

## How the old gates carry forward (v2)

| Phase contracts | Milestone and dependency | Disposition |
|---|---|---|
| P0 harness; P1 benchmark baseline; P2a eyes, P2b browser, P2c agent, P2d speech | Foundations for all three milestones. | Preserve 13/13, 11/11 and four 8/8 spike verdicts as historical results; no spike qualifies a production flow. |
| P3 voice (after P2d); P4 TaskLoop (after P1) | C1 uses final authority, exact insertion, direct/Jev decisions and independent outcomes; outstanding qualification carries to C3. | P3 remains 0/8; see provider mapping below. P4 remains 4/6: P4-5/6 need their own evidence, not Terra-assisted success relabeled as Jev. |
| P5 recovery → P7 browser; P6 hero actions; P9 replay | C2: P5 needs P4; P7 needs P2b + P5; P6 can start from reviewed P3; P9 needs P5 + P7. | Preserve separate policy, safety, DOM/AX, confirmation and replay gates. Reuse direct operations first, Jev as primary chooser, approved Terra API for planning/generation or recovery; pinned Cua/native executes. No replacement-model tournament. |
| P8 eye core → P11 eye polish; P10 onboarding | C3: P8 after P2a, P11 after P8 + P5; P10 after P3 + P6. | C1 can address dwell safety; it cannot qualify production camera, recovery, voice-only alternatives or clean first-run UX. |
| P12 packaging → P13 RC | Begin packaging checks in C1; full P12 after P0–P11, P13 after P12. | Preserve strict bundle/license, rollback, resources, clean-user, human and matched competition gates. No acceptance or release until the applicable evidence and user decision. |

**Reading older criteria.** The [reviewed R10 contract](results/P4/c1-r10-realtime-contract.md)
supersedes local-ASR startup, local-only finals and local TTS for normal use.
Read older phase plans and frozen checks as follows; do not edit their receipts.

- P3-1 preserves inherited bytes and scope; COORD-1 governs checkout choice,
  not the historical branch name. P3-2/6/8 retain critical-slot accuracy,
  regression/hygiene, independent judgment and handoff.
- P3-3/4 local drain/preview, no commit on hit and zero cloud transcription
  describe the old input path. Normal voice needs a final correlated to the
  committed Realtime item even for direct commands. Keep one host permit,
  no reasoning response for literal insertion, no partial or duplicate acts
  and no pixels to Realtime. P3-5 preserves nine validated tools and stable
  task/ask identities; retiring competing paths does not ban R10 transcription.
- P3-7's signed 34/35 vs unsigned 35/35 local replay stays diagnostic. Keep
  the physical Fn population (4×5 warm + 4 controls, cold and warmups
  separate), remote and latency gates distinct. A local-only run budget is
  not authority for a Realtime trial. Never count a fixture or hands-free
  demo as that physical population.
- Apply R10 readiness to P10 onboarding and P12 normal staging; explicit
  diagnostics are not automatic fallback. For P7-5 keep the historical
  matched Sol-pixel benchmark distinct from production Terra. P4-5 needs
  Jev-only ≥95% and p50 ≤4 s; P4-6 needs independent judgment. A private
  method or MCP injection isn't proof of the public voice/script/replay path.

Before scoring an incompatible predicate, version its replacement, map the
guarantees and re-review the consumers, populations and budgets. Nothing in
this mapping awards PASS, replaces a frozen interface or removes a test.

[PROGRAM](PROGRAM.md) owns release bars and the full dependency DAG;
[PLANS](PLANS.md) owns G1–G7 and COORD-1. Implementation may consume an
independently reviewed upstream interface with affected checks, hash,
version, consumers and remaining failures; that does not close G5/G6.
[Phase plans](phases/) and [acceptance files](acceptance/) retain their
original scope. Use [REUSE](REUSE.md) and [CONTRACTS](CONTRACTS.md) before
new work. KAR-22 authorizes building across milestones, not a paid run,
desktop session, install, new data collection or release. The owning issue
binds any future authorized run, not the word “latest” in a prior receipt.

**Historical sources:** [pre-v2 delivery plan](SHIP-PLAN.v1.md) and
[2026-11-15 program review](results/P4/jev-program-review-20261115.md).
