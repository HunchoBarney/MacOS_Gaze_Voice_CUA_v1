# P1 — Bench test user + harness + baseline ExecPlan

> Status: draft
> Track: main · Depends on: P0 · Branch: `ship/v1-p1` (stacked on ship/v1-p0)
> Acceptance: `.agent/acceptance/P1.json` · Contracts touched: §7 bench task JSON (amended — D3)

## Purpose

Build the unattended bench that every later phase's G5 and the P13
release gate run against: a task corpus of hero-job prompts, a runner
that drives the real `DriveLoop` through the app's `--mcp-stdio`
surface and verifies end-state independently, Wilson-CI reporting, an
environment snapshot, per-task reset scripts, and the documented
test-user setup. Ships with a baseline report from the local-safe task
set on this machine.

## Context

- **Injection surface (verified):** `Sources/JevVoice/main.swift:844` —
  `JevVoice --mcp-stdio --agent <slug>` branches before NSApp/instance
  lock → `CuaDriveServer.main()` (Sources/JevVoice/Drive/CuaDriveServer.swift)
  speaks newline-delimited JSON-RPC on stdio (MCP). Tools: `drive_until`
  `{goal, app?}` → a result frame; `suggest_action` → read-only preview
  (ping/health use).
- **Result vocabulary (verified vs `CuaDriveServer.describe`, complete):**
  a result frame's text is one of — `Done.` (+history tail),
  `Already satisfied: <r>.`, `Blocked: <why>` (declined/nil/unclassified
  consent forms all carry this prefix), `<reason>. No grant or approval
  path changes that.` (permanent refusal — **no `Blocked:` prefix**),
  `Blocked: computer use needs the standing grant — …` (missingGrant),
  `Stuck: <reason>. <tail>`, `Needs input: text for <field>.`,
  `Ambiguous: which of <a, b, c>?`, `Ran out of steps. <tail>`,
  `Cancelled.`. A frame may instead be a toolError: `isError: true`
  with texts like `` `goal` is required. ``, `TYPESAFE_API_KEY is not
  configured…`, `Cancelled.`, or `error.localizedDescription` — the
  classifier must key on `isError` first, then the text vocabulary.
  Classifier output: `done|already|blocked|refused_permanent|stuck|
  needs_input|ambiguous|maxsteps|cancelled|error`.
- **Requirements for a live call:** app running so the Cua daemon socket
  exists — path from `~/Library/Application Support/JevVoice/cua.socket`
  hint file (or `JEV_CUA_SOCKET` env); `TYPESAFE_API_KEY` in the child's
  env (Keychain item: service `com.chriswozniczek.jevvoice`, account
  `typesafeAPIKey` — fetchable via
  `security find-generic-password -s com.chriswozniczek.jevvoice -a
  typesafeAPIKey -w`); mutations additionally need
  `~/Library/Application Support/JevVoice/policy.json` standingGrant
  true, else calls return "Blocked: computer use needs the standing
  grant".
- **Result text is a claim, not truth** — the bench verifies end-state
  separately (zero-false-Done discipline) and flags
  `result=Done, verified=false` as `false_done`.
- **Latency:** child process has no LatencyLedger attachment; the bench
  measures `wall_ms` per run (prompt dispatch → MCP result). Per-step
  span detail arrives with P4/P5 loop work — the result row carries a
  `spans: {}` slot so records don't need a schema bump.
- **Test user:** creating a macOS user needs sudo (can't be automated by
  an agent). `scripts/bench/create-test-user.sh` is the one user-run
  step; the corpus splits `local-safe` (runnable on this machine now)
  vs `test-user` (mutating Mail/Calendar/real browser state).
- **Bench sources (megaplan reuse map):** MacArena/macOSWorld-style
  tasks, cua-speedrun timing method (wall-clock per completed attempt),
  Online-Mind2Web-style web tasks for the browser rows.
- **Installed binary** for the child: prefer
  `~/jarvis-local/Jev Voice.app/Contents/MacOS/JevVoice` (matches the
  running app), fallback `.build/release/JevVoice`. `--binary` flag
  overrides.

## Owned paths

```text
bench/**
scripts/bench/**
.agent/phases/P1-bench.md
.agent/acceptance/P1.json
.agent/CONTRACTS.md
.agent/PROGRAM.md
.agent/PROGRESS.md
```

## Non-goals

- Creating the test user (documented user step only — sudo).
- Mutating tasks on this account (they're `requires: test-user`).
- Voice-path injection (Fn/mic) — `drive_until` is the honest
  automatable proxy; a text-injection seam for the voice lane is a
  later-phase item, noted in Handoff.
- Head-to-head Codex/Browser-Use runs (P13 consumes this harness).

## Milestones

### M1 — Corpus + validator
**Change:** `bench/tasks/*.json` — ≥14 tasks across all four hero jobs,
each tagged `local-safe` or `test-user` via the new `requires` field;
`bench/selftest.py` corpus section validates every task against the
contract schema (closed-set `success.kind`, `id` pattern, `runs` ≥5 for
hero tasks, `setup` script exists when named).
**Check:** `python3 bench/selftest.py` (corpus case) → OK; ≥5
`local-safe` tasks.
**Evidence:** task count per hero job; validator output.

### M2 — Client, verifiers, stats, selftest
**Change:** `bench/lib/mcp_stdio.py` (spawn/initialize/tools-call,
per-call timeout, stderr passthrough, clean reap),
`bench/lib/verifiers.py` (`file_state`, `ax_state` via `osascript`
System Events, `app_frontmost`, `speaks_substring`, `dom_state` via
Apple Events URL/title read), `bench/lib/wilson.py` (Wilson lower
bound, p50/p95), `bench/lib/results.py` (result-text classifier +
false-Done flag + jsonl row), `bench/selftest.py` — full coverage:
frame codec roundtrip against a stub MCP server subprocess, verifier
logic on fixtures, Wilson math, classifier mapping, task validation.
**Check:** `python3 bench/selftest.py` → all pass, 0 fail.
**Evidence:** unittest output.

### M3 — Runner, reporter, suite, env snapshot
**Change:** `bench/run.py` (`--task/--tag/--set/--runs/--out/
--dry-run/--timeout/--binary`; reset → inject → wall_ms → classify →
verify → row), `bench/report.py` (results.jsonl → per-task n/succ/
wilson_low/p50/p95 vs `budget.p50_ms` → `bench/results/baseline.json` +
`baseline-report.md`), `bench/run-suite.sh` (`caffeinate` + env
snapshot + suite + report, sequential, fails closed),
`bench/env-snapshot.sh` (sw_vers, hw model/RAM, app version from
installed bundle plist, daemon socket reachability, policy standingGrant
bit — no secrets), `bench/reset/*.sh` for tasks that name one,
`bench/.gitignore` (`results/`, `.env`).
**Check:** `python3 -m py_compile bench/run.py bench/report.py
bench/lib/*.py && bash -n bench/run-suite.sh bench/env-snapshot.sh
scripts/bench/create-test-user.sh`; `python3 bench/selftest.py` stays
green; `BENCH_STUB=1 bench/run-suite.sh` produces artifacts against the
stub backend (no app needed).
**Evidence:** command outputs; `bench/results/` artifacts.

### M4 — Test-user script + contract amendment + docs
**Change:** `scripts/bench/create-test-user.sh` (sysadminctl command +
refuses cleanly without sudo + prints the post-create GUI checklist:
login once, install app, grant Accessibility/Screen Recording/
Microphone/Camera, sign into Mail + browser); `bench/README.md`
(operate bench, env/key handling — key fetched from Keychain, never
logged, `.env` gitignored); `.agent/CONTRACTS.md` §7 amended with
`inject`/`requires`/`app` fields + `app_frontmost`/`dom_state`
verifier kinds explicit; `.agent/PROGRAM.md` decision index D3.
**Check:** `bash -n scripts/bench/create-test-user.sh`; `python3
scripts/check-owned-paths.py P1` staged → OK; `grep -l '"requires":
"local-safe"' bench/tasks/*.json | xargs grep -l 'Mail\|Calendar\|
Messages' ` → empty output (no mutating app under local-safe).
**Evidence:** script output; contract diff.

### M5 — G5 live slice (attempted real, honest fallback)
**Change:** none — run the bench. Launch the app (`make local` or the
installed copy), then `bench/run-suite.sh` against the `local-safe`
set for real via `drive_until`. If the app/Keychain/daemon can't be
brought up in-session, run the full suite against a stub MCP server,
record the blocker verbatim in baseline-report.md + Handoff, and leave
the exact rerun command.
**Check:** `python3 bench/report.py bench/results/<latest>.jsonl` →
baseline.json + report exist; every `local-safe` row has verifier
verdicts (real or `blocked:…` reason).
**Evidence:** results rows + baseline-report.md.

## Acceptance mapping

| acceptance/P1.json id | Milestone | Check layer |
|---|---|---|
| P1-1, P1-2 | M1 | contract (script check) |
| P1-3 | M2 | unit |
| P1-4 | M3 | unit+contract |
| P1-5 | M3 | unit |
| P1-6 | M2–M3 | unit |
| P1-7 | M3 | contract |
| P1-8 | M4 | contract |
| P1-9 | M4 | contract |
| P1-10 | M5 | live slice (or documented blocker) |
| P1-11 | G4/G7 | judge review |

## Gates

- G1: plan presented to user for approval (2026-10-18).
- G2: the milestone checks above are the sprint contract — judge review
  of this file + acceptance.json stands in for negotiation (tooling
  phase, no cross-phase seam changes beyond §7).
- G5: the M5 slice is this phase's bench — it IS the product here.
- G6: not a UX phase — no human-try checklist beyond the user's choice
  to run `create-test-user.sh`.

## Progress

- [x] M1 corpus + validator
- [x] M2 lib + selftest
- [x] M3 runner/report/suite
- [x] M4 test-user + contracts + docs
- [x] M5 live slice + baseline

## Surprises & Discoveries

- The `--mcp-stdio` child process never touches the app's LatencyLedger
  — spans for bench runs must come from the runner's own wall-clock
  timing until P4/P5 emit per-step spans. The result row carries a
  `spans` slot reserved for them.
- `git add` refuses already-deleted pathspecs (learned in P0) — same
  rule applies here.
- `README.md`/`EyeTracking/README.md` P0 edits remain in the user's
  uncommitted set — P1 doesn't touch them.
- `requires` grew a third value beyond D3's original text: `"human"` —
  the gaze pair is recorded for corpus coverage but never injected
  (no calibrated tracker + looker in automation). §7 documents all
  three values.
- Row `status` is wider than the classifier vocabulary: harness-level
  outcomes (`dry_run`, `setup_error`, `blocked:keychain`) reuse the same
  field so every attempted run yields exactly one row. report.py counts
  them as failures and excludes them from latency percentiles.
- `--dry-run` still executes named `setup` scripts and the live
  verifiers — it is "reset + verify, no injection", not a pure plan
  print. Stub runs mutate too (setup scripts run for real: a
  `BENCH_STUB=1` suite opened/quit Calculator on this machine).
- The stub server emits a `notifications/message` frame before its
  initialize response so the client's non-response-frame skip path is
  exercised on every roundtrip, not just in theory.
- **PRODUCT BUG — session-label wedge (P1's headline finding).** Every
  `--mcp-stdio --agent <slug>` child runs DriveLoop on session label
  `agent-<slug>` (CuaDriveServer.swift:205,209). When a child exits, its
  `mcp --embedded` proxy dies and the daemon tombstones the label to the
  dead owner; the resurrection/rotate path (DriveLoop.swift:300-316)
  never recovers — every later call on the same slug dies at ~1.2s with
  transport `.closed` → `Blocked: driver connection dropped mid-task`.
  Reproduced twice at suite scale (35/35 rows, twice); a fresh slug
  works instantly on the same daemon (verified `--agent freshslug1` →
  Done 2.6s). Any caller that re-invokes the same `--agent` slug wedges
  permanently until the daemon respawns. Mitigation (bench-local):
  unique slug per spawned child (`bench-<pid>-<n>`). The product fix
  belongs to a drive/session phase — carry to Handoff.
- Transport-error rows recorded `wall_ms: 0` — the MCPError path never
  timed the attempt. Fixed in run.py: the except branch now records the
  real elapsed time (a `read deadline exceeded` row now shows ~120s,
  not 0).
- The first suite runs surfaced a **daemon respawn**: `serve` died and
  the app re-minted it twice mid-bench (sockets changed
  `97dcf1a7`→`af8d326d`, healthy watchdog behavior). All wedged-era rows
  were excluded from the clean baseline via a separate
  `results-live-<date>.jsonl` slice.

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|
| D3 | 2026-10-18 | Bench task JSON gains `inject` (default `"mcp_stdio"`), `requires` (`"local-safe"\|"test-user"\|"human"`), optional `app` hint; verifier kinds `app_frontmost`+`dom_state` made explicit | The frozen §7 shape lacked how a prompt reaches the app and which account it may mutate; fields are additive, consumers unaffected |
| D4 | 2026-10-19 | Bench children use a unique `--agent bench-<pid>-<n>` slug per spawn, not a shared `bench` slug | Reused slugs wedge permanently on the session-label tombstone bug (see Surprises); a per-child slug keeps the bench unblocked while the product fix lands elsewhere |
| KAR-25 | 2026-11-17 | Record each selected real MCP trial as `blocked:operator_handoff` before fixture setup. | A bench slug cannot distinguish a trusted human handoff. No silent skips or changes to historical cases, stubs or historical measurements. |

## Outcomes & Retrospective

The bench exists and measures honestly end-to-end: stub suite, unit
suite (18 tests), and a real live slice of 35 `drive_until` runs on the
running app — `results-live-20261019.jsonl`, `baseline.json`,
`baseline-report.md`.

**Baseline (live slice, this machine, app 0.1.5):** `calc.quit` 5/5
verified at p50 1.3s, `finder.frontmost` 5/5 at 1.3s, `calc.open` 3/5
at 5.4s (2 false_done flagged); `calc.compute`, `safari.open-example`,
`chrome.open-example`, `textedit.type` 0/5 with verbatim
blocked/stuck/error reasons. Tier rollups: T0 misses the 500ms bar
(p50 1290), T3 misses 4000 (4396), TB "meets" trivially on failing
tasks. The product is far from the release bars on anything beyond
open/quit/frontmost — which is exactly what a baseline is for.

**Findings the bench produced:** (a) the session-label wedge bug —
reused `--agent` slugs permanently kill later transports until daemon
respawn (mitigated in-bench, logged for a drive/session phase);
(b) 2 real false_done rows on `calc.open` ("already running" claimed,
verifier found not running); (c) mid-complexity tasks exceed the
current loop — low_confidence presses on wrong elements (Calculator AC,
Safari "Show Search Menu"), "No usable window", "screen stopped
changing" — consistent with the pre-P4 known-gaps list, now measured.

Judge loop ran twice: first verdict FAIL on two real defects
(UnboundLocalError crash path + stale `wall_ms:0` rows in the shipped
baseline), both fixed and re-verified to PASS.

## Handoff

- **Carry-forward product bug (HIGH):** session-label wedge — reused
  `--agent <slug>` mcp-stdio children wedge permanently after the first
  child exits (tombstone binds label to dead transport; resurrection
  never recovers). Repro: two sequential `--mcp-stdio --agent X` calls
  with a real goal; second+ call → `Blocked: driver connection dropped
  mid-task: Cua disconnected` at ~1.2s. Bench works around it with
  unique slugs; the fix belongs in the session/driver layer — likely
  P4 (TaskLoop) or a dedicated drive reliability fix. Files:
  `CuaDriveServer.swift:205,209` (label minting),
  `DriveLoop.swift:264-322` (resurrect/rotate), `CuaConnection.swift`.
- **Test user not created** — needs sudo; `scripts/bench/create-test-user.sh`
  is the one documented human step. The test-user corpus (7 tasks) is
  unrun: inside a `jevbench` console session, `BENCH_SET=all
  bench/run-suite.sh`.
- **`wall_ms` is MCP roundtrip only** — no voice-path latency; P3 needs
  a text-injection seam on the voice lane for end-to-end measurement;
  `spans` slot in the row schema is reserved for per-step spans
  (P4/P5 emitters).
- **Gaze tasks are `requires:"human"`** — recorded for coverage, never
  injected; gaze verification stays a G6 human check per phase.
- **`bench/results/` is gitignored** — artifacts are local; regenerate
  any time via `bench/run-suite.sh`.
