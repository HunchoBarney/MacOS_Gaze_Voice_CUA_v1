# Jev integration repair, 2026-11-08

## Scope and disposition

Keep Jev as the fast, bounded judgment layer. No Sol/Terra replacement,
planner implementation, new computer-use tools, ASR/gaze rewrite, or P3
acceptance change. P4-5 and P4-6 remain false. Prior P4-1 through P4-4
judge evidence predates these repairs; this report is not a new G4 verdict.

## What changed

- Preserve `screen_values` when production extras supply page/window state.
  Include bounded read-only labels and values; omit secure/password values.
  Extra fields cannot replace the goal, options, app, window, or history.
- Rank numeric labels as well as words, keep stable ordering on ties,
  increase the default element shortlist from 16 to 32, and avoid treating
  StaticText as an editable field through substring matching.
- Separate action Choice from applicability and completion Nouls, batched
  in ONE request. Choice contains actions only: completion/reobserve/stuck
  no longer compete with controls. Noul state contains an explicit
  `available_actions` table. Text availability and literal insertion stay
  in code; Jev picks a field, never authors or rewrites its text.
- Pin the drive chooser to `jev-1.14.0`. Preserve model/version, full
  probabilities, applicability, completion probability, and RTT. Validate
  complete, finite, normalized distributions with a unique winning option.
  Missing or malformed evidence fails closed. The P3 semantic router's
  existing `readDetailed` API is unchanged.
- Act only when selected-option probability meets both 0.7 and the
  probability equivalent of the previous confidence floor, and
  applicability meets 0.7. Model completion requires 0.9. These are
  conservative provisional policies, NOT broad outcome calibration.
  Consent, protected actions, window/snapshot authority, cancellation,
  and literal ownership remain outside the model.
- Restore the four-round production default. Both completion policies
  require a verified settle AND current task-specific goal evidence.
  A quiet screen, blank expected string, or confirmed click alone cannot
  complete a task. Decider and loop share the same evidence checker.
- An explicit already-visible postcondition bypasses the model entirely:
  request the loop's verifyState first, then finish only with verified
  current evidence. Production distinguishes alreadySatisfied from an
  effect-backed done. No completion threshold was lowered.

## Before/after regression evidence

`jev-before.log` reproduces the state, candidate, privacy, state-key, and
round-budget defects before repairs: 191 selected tests, 16 assertions
failing in the new regression cases.

`jev-verification-before.log` reproduces quiet-screen completion and the
production completion-policy bypass. Subsequent testing also exposed two
different evidence implementations: the loop checked AX labels/values,
while the decider checked only markdown. Both now use TaskLoop's checker.

Existing positive session, consent, typing, browser, and token-recovery
fixtures now supply and observe their actual postconditions rather than
assert completion solely from a driver acknowledgement. The unverifiable
DOM-click case explicitly rejects both fabricated completion and a
fabricated alreadySatisfied result. Original dispatch/authority/consent
assertions remain.

## Live request experiments

User explicitly approved at most 30 TypeSafe requests on synthetic UI
fixtures only. Exactly 30 reservations/calls were used. No screenshots,
private application state, other providers, desktop actuation, or automatic
retries. `jev-live-grant.json` preserves the exhausted grant.

| Artifact | Arm | Correct Decisions | RTT p50 ms | RTT p95 ms |
| --- | --- | ---: | ---: | ---: |
| jev-live-initial.json | Legacy request | 3/5 | 87.519 | 191.502 |
| jev-live-initial.json | First revised request | 2/5 | 80.312 | 92.575 |
| jev-live-v2.json | Legacy request | 3/5 | 70.191 | 215.474 |
| jev-live-v2.json | Actions-only Choice | 4/5 | 74.874 | 81.433 |
| jev-live-final.json | Final request, 5 familiar + 5 held-out | 9/10 | 73.092 | 326.599 |

p50 is the median; p95 is nearest rank, including cold connections.
These are MODEL REQUEST timings and per-observation decisions, not task
completion latency, packaged-app success, or a statistical release score.
The first two experiments are paired request comparisons on common
fixtures and the same repaired candidate builder/current executor policy,
NOT a replay of the entire old app. The final ten use a different case
mix and cannot be presented as a same-set 3/5-to-9/10 A/B improvement.

The first revision genuinely regressed: overly indirect instructions and
reserved statuses competing with actions caused abstentions. Those failed
rows remain intact. Removing statuses from Choice fixed Save and numeric
grounding. Clarifying that code supplies/asks for literal text fixed Email
and held-out Full Name typing without exposing the literal to Jev.

The last live run correctly handled Save, numeric target 7, Email, held-out
Full Name, and a checkbox; it abstained on absent controls/fields, a failed
upload, and a multi-action request needing a planner. The remaining error
was a false abstention on an already-exported state: done Noul 0.87 below
0.9. This motivated deterministic postcondition checking, NOT a lower
threshold or a new network call.

## Verification of the final code

- `scripts/verification-lane.sh all`: 1,113 Swift tests, 15 skipped, zero
  failures; P3 verifier green; tracker typecheck green; 234 tracker tests
  across 11 files green. Evidence: `jev-full-final.log`.
- `scripts/verification-lane.sh p4-jev-replay`: all ten recorded cases
  through the current production chooser/decider pass. Nine reuse the
  exact recorded questions/state/answers; the already-exported case
  requires verifyState without invoking the model. This is OFFLINE replay,
  not another live run or a new accuracy sample. Evidence: `jev-replay.log`
  and `jev-replay-21FB99A7-7149-484D-9B3C-342EEC81EE83.json`.
- Request shape/model parsing tests use the real HTTP client with a
  fixture URLSession transport. They do not prove network or desktop
  behavior; the separately capped live requests exercise the real API.
- Exact requests, distributions, model IDs, decisions, and RTTs are in the
  three live JSON artifacts. The final replay binds chooser/decider source
  hashes and rejects changed request state/questions.
- User separately approved replacing/restarting the installed app.
  `JARVIS_P4_INSTALL=approved scripts/verification-lane.sh p4-local` passed:
  existing pinned runtimes verified, release built, stable local identity
  signed the app, app restarted, tracker `/ready` reached HTTP 200.
  Independent `codesign --verify --deep --strict` passed. All 39
  file-backed Mach-O section hashes match the release artifact; there is
  exactly one main app process (PID 42202 at verification).
  See `jev-install.log` and `jev-install-receipt.json`.
  Signing changes whole-file hashes and link-edit layout, so neither raw
  nor signature-stripped whole-file hash equality is a valid comparison
  here; the receipt retains distinct whole-file hashes and matching
  code/data section hashes. Original executables were never stripped.
- Final post-install audit also passed: `jev-final-audit.log` repeats the
  full Swift/typecheck/tracker lane; `jev-final-replay-audit.log` repeats
  the ten-case network-free replay. Final replay artifact:
  `jev-replay-27524220-DC0D-4F0E-802A-B91104EDCDCF.json`.
  All six production source hashes still match the installation receipt.
  The legacy fixture's em dash is ASCII-escaped in test source while
  preserving its exact wire text. Diagnostic spend remains 30/30.

## Remaining release work

- No new full desktop bench or physical Fn qualification was performed.
  The previous bench5 is 16/30 STRICT successes, not the obsolete 25/30
  externally matched end states. Blocked browser rows do not count.
- The request sample is small and synthetic. It does not establish
  general reliability, calibrated thresholds across risk classes,
  real workflow p50/p95, or the P4 >=95% acceptance bar.
- Unfamiliar multi-step workflows require a separate planner/current-step
  provider. No planning provider was silently installed. Tasks without
  verifiable postconditions fail closed rather than guess success.
- Fresh independent phase review and the strict live benchmark remain
  necessary for P4 closure. No acceptance flags were changed.
- Installation was separately approved and is recorded in
  `jev-install.log`; final install/signature/startup receipts are recorded
  separately. A tracker readiness timeout is never a gaze/product pass.

## Current TypeSafe sources consulted

- https://docs.typesafe.ai/concepts/state.md
- https://docs.typesafe.ai/primitives/choice.md
- https://docs.typesafe.ai/primitives/noul.md
- https://docs.typesafe.ai/confidence.md
- https://docs.typesafe.ai/patterns/companion-noul.md
- https://docs.typesafe.ai/models.md
- https://docs.typesafe.ai/model-jaggedness.md
- https://docs.typesafe.ai/primitives/advanced.md
- https://typesafe.ai/blog/dont-call-it-a-decision-model

Reproduction: `p4-jev` builds/tests the focused lane. `p4-jev-live` only
runs an already-built test binary, requires explicit approval and a
credential supplied in the child environment, and refuses spending beyond
the existing exhausted grant. Do not reset the grant to obtain new calls.
`p4-jev-replay` is network-free and uses the recorded synthetic responses.
