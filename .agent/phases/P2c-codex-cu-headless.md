# P2c — Spike: Codex app-server computer-use headless feasibility

## Purpose

PROGRAM.md's reuse map slots "Background Mac agent" as "Codex
app-server Computer Use — unverified, 1-day spike". Answer it with
evidence: **can `codex app-server`'s `computer_use` feature drive
macOS GUI actuation unattended from a programmatic client**, and is it
viable as JevVoice's background-agent lane? Deliverable is a
promote/discard verdict + measured evidence — not a production
integration.

## Context

Ground truth collected at plan time (2026-10-19):

- **Vendored codex 0.160.0** at `build/vendor/CodexRuntime/bin/codex`
  (what the product ships — use THIS binary, not `~/.local/bin/codex`
  0.158.0). `computer_use` feature flag is **stable + enabled by
  default** on both.
- **Auth is live**: `codex login status` → "Logged in using ChatGPT".
  The app already symlinks `~/.codex/auth.json` into per-agent
  CODEX_HOMEs (`CodexAuth.swift`); `CodexRuntimeBridge.swift` already
  spawns `codex app-server` per agent with config.toml + env hygiene.
  This spike drives the raw binary directly (no app needed).
- **Protocol**: `codex app-server` speaks line-delimited JSON-RPC v2 on
  stdio (CodexProtocolClient.swift proves it). Full schema dumped at
  plan time via `codex app-server generate-json-schema` (275 v2
  schemas) — key surfaces, distinguishing *declared requirements*
  from *writable config*:
  - `configRequirements/read` returns `ComputerUseRequirements` —
    what the server/policy DEMANDS of clients:
    `allowLockedComputerUse`, `allowPersistentApproval`,
    `defaultAppAccess` (allow/deny), `macos.bundleIds` (camelCase
    here; per-bundle allow/deny). These are the constraints codex
    declares — NOT necessarily writable by us.
  - `Config.computer_use` is the *writable* surface and is NARROWER:
    `default_app_access` + `macos`/`windows` app tables only — it
    does NOT include the locked-use or persistent-approval booleans.
    Whether `allowLockedComputerUse`/`allowPersistentApproval` are
    client-settable at all is a DISCOVERY question, not an
    assumption.
  - `ApprovalsReviewer` = `user | auto_review | guardian_subagent`,
    selectable via config `approvals_reviewer` / turn
    `approvalsReviewer` — `auto_review` routes approval requests to a
    risk-assessed subagent. `AskForApproval` supports `never`
    (+ granular).
  - Turn control: `thread/start`, `turn/start` (effort/mode params —
    NO explicit computer-use selector; activation is config/tool
    mediated — see discovery order), `turn/interrupt`, `turn/steer`;
    `*Notification` stream per item.
- **Model catalog** (`codex debug models`) includes `gpt-6-sol` —
  the same model family as JevVoice's locked `gpt-6.1-sol`; computer
  use rides the vendor we already locked.
- **No `jevbench` user exists** — the true multi-user "background
  session" (fast-user-switched, non-console WindowServer session)
  needs `sudo scripts/bench/create-test-user.sh` — a HUMAN step. The
  spike therefore has two scopes:
  - **Measurable now**: unattended computer-use via app-server on
    THIS session — protocol, approval modes, real actuation,
    latency/tokens, what TCC grants the codex binary needs.
  - **Documented, not fabricated**: multi-user/locked-session
    semantics (`allowLockedComputerUse`, switched-out WindowServer
    behavior, per-session TCC) — analyzed from codex's own docs/
    config surface + our run data; unverified claims stay labeled.

## Design

Self-contained spike at `spikes/codex-cu/` (stdlib Python 3 only,
mirroring the P2b harness conventions; JSON-RPC client adapted from
`bench/lib/mcp_stdio.py`):

```
spikes/codex-cu/
  appserver.py    — line-framed JSON-RPC client for `codex app-server`
  probe.py        — env probe -> results.json probe block
  tasks.json      — canary GUI task corpus + verifiers
  run.py          — unattended turn runner (thread/start -> turn/start
                    -> collect item events -> independent verify)
  report.py       — REPORT.md
  results/        — results.json, REPORT.md, *.log (committed)
```

**Canary corpus** — bounded, non-destructive, this-session tasks
(the user's screen/mouse IS driven briefly; that is the measurement.
Runs MUST be announced to the user before starting):

Each task uses a **per-run unique marker** (`MARK = p2c-<pid>-<n>`)
so verifiers attribute state to THIS run, never to leftovers:

| id | task | independent verifier |
|---|---|---|
| `calc.compute` | open Calculator, compute 4+7 | frontmost process == `Calculator` (`osascript` System Events); AX extraction of the display field = "11" — verifier specifies the exact AX path probed, or `verify_blocked` if Calculator doesn't expose it |
| `textedit.type` | new TextEdit doc, type MARK | `osascript -e 'tell application "TextEdit" to get text of front document'` contains MARK (fresh doc — runner first confirms no pre-existing doc holds MARK) |
| `finder.reveal` | open Finder at `spikes/codex-cu/results/` | frontmost == `Finder`; front window's target resolves to the canonical path (AppleScript `target of front Finder window`) |
| `notes.snippet` | open Notes, create note with MARK text | `osascript` enumerates Notes; a note whose body contains MARK exists; `skipped` if Notes isn't configured — recorded, not faked |

`run.py` records wall_ms / turn status / items seen / tokens (turn
usage) / verifier verdict per row — the INDEPENDENT verifier decides
`ok`; the agent's own claims are never evidence (zero-false-Done
discipline). Pre-run the runner snapshots relevant state
(frontmost app, open TextEdit docs, note count) for attribution.

**Tool-activation proof (the real feasibility question)**: passing
the end-state check does NOT prove computer-use — the agent could
`open -a Calculator` via shell. Every `ok` row must ALSO carry
`cu_evidence`: item-stream signatures of actual computer-tool calls
(screenshot/click/key/mouse-move items, whatever their real type
names are — discovered at the activation checkpoint). Rows whose
tasks pass without CU evidence are `ok_no_cu` — success but not the
thing being spiked. The verdict counts ONLY `cu_evidence` rows.

**Activation checkpoint (before the corpus)**: one discovery turn
asking for a single mouse-move — the item stream either shows the
computer tool firing or it doesn't. If no CU tool exists under any
config discovered, that IS the verdict (discard on this surface);
the corpus then runs only for context.

**Session safety bounds**:
- All GUI-mutating runs serialize through
  `scripts/with-desktop-lock.py` (repo rule for desktop mutations).
- `scoped` variant runs FIRST: `default_app_access=deny` +
  `macos.bundle_ids` allow-list of ONLY the corpus apps — the
  unrestricted `never` variant runs only after scoped proves out.
- Codex workspace sandboxed to `spikes/codex-cu/sandbox/`; corpus
  writes nothing outside it except the app-visible state the
  verifiers check (fresh TextEdit doc, one note) — cleaned up
  post-verify where the task is disposable.
- Per-task hard wall timeout 120s → `turn/interrupt` → bounded
  acknowledgement wait (10s) → process-group terminate → kill;
  same sequence on ctrl-c/TCC pause; no orphaned codex/actuation
  processes (pgrep before/after like P2b).

**TCC-prompt reality**: the first screenshot/AX call may surface a
Screen Recording or Accessibility TCC dialog for the codex binary —
a headless run CANNOT click it. The runner detects the stall
(screenshot/AX error or no-progress window) → records `needs_human`,
PAUSES, and asks the user to grant once (this IS the onboarding-once
grant under the locked Permissions decision) — it does not retry-loop
through the prompt. TCC grant events are recorded separately from
zero-click measurements — a run that needed a TCC click is
`needs_human`, not a failed unattended claim.

**Unattended-approvals matrix** — the actual headless question.
All variants share a PINNED base (recorded into results meta):
fresh CODEX_HOME per variant (no carried-over grants), same model
(probe picks the effective model once; if the default lacks computer
tools, `-c model=<catalog pick>` — recorded), same effort, same
sandbox policy; the variant name = exactly one config delta.
`effective_config` captured per variant (config readback or launch
flags logged) so rows are reproducible.

| variant | config delta | expected |
|---|---|---|
| `scoped` | `approval_policy=never` + `computer_use.default_app_access=deny` + `computer_use.macos.bundle_ids={corpus apps: allow}` (config side is snake_case per ComputerUseMacosConfig; requirements readback reports `bundleIds`) | zero clicks inside the allow-list |
| `never` | `approval_policy=never` + `default_app_access=allow` | zero human input anywhere |
| `auto_review` | `approvals_reviewer=auto_review` (config or turn `approvalsReviewer`) | subagent resolves asks |
| `persistent` | `allowPersistentApproval` (IF client-settable — discovery item) | one grant covers the run |
| `default` | no delta | baseline — record what it asks |

Rows record: status `ok|ok_no_cu|driver_error|timeout|refused|
needs_human|blocked_env|verify_blocked`, wall_ms, tokens, approvals
seen in the event stream, TCC prompts observed.

**Mechanism discovery order** (the plan does NOT presume the exact
turn-request shape): 1) `configRequirements/read` → enumerate
declared requirements; 2) `config read` → current effective config;
3) write config via CODEX_HOME `config.toml` (`[computer_use]`
table, snake_case keys per Config schema) or `-c` overrides;
4) `thread/start` → `turn/start` with a one-shot computer task →
watch the item stream for the computer tool; 5) model fallback
(`-c model=`); 6) `codex exec` non-interactive is the documented
FALLBACK surface — verdicts report app-server vs exec surfaces
SEPARATELY (exec cannot satisfy the app-server acceptance rows);
7) vendored `codex-resources/` last.

**Verdict rule (predeclared, PLANS.md spike-gate)**:
- **PROMOTE** = ≥2 canary tasks `ok` WITH `cu_evidence` under at least
  one fully unattended approval config (zero human clicks in the run)
  + p50 per-task wall ≤120s + no unbounded actuation (scoped config
  verified to refuse out-of-list apps or no refusal needed) + no
  unrecoverable transport.
- **DISCARD** = no `cu_evidence` on any config after the mechanism
  discovery order is exhausted, OR every unattended config requires
  human clicks, OR computer-use errors are systematic.
- **CONDITIONAL** (only when explicitly named): app-server turns work
  but only under a config that reduces unattended-ness (e.g., only
  `auto_review` clears asks) — verdict names the exact condition and
  what P-later must build/verify (e.g., jevbench session test).
- This-session success NEVER counts as background-session proof —
  the multi-user piece is reported separately as documented/
  unverified, and the verdict line says which of the two it covers.

**Headless/multi-user analysis section** — hypotheses to verify,
NOT assertions (labeled in the report):
- `allowLockedComputerUse` — declared requirement; whether it gates
  switched-out sessions is a question, not a given.
- Whether a fast-user-switched (non-console) session keeps a live
  WindowServer the computer tool can actuate — hypothesis from how
  macOS multi-session GUI works; verify via codex docs/source or a
  jevbench run (needs sudo — flagged needs_human, not faked).
- Whether TCC grants are per-session (i.e., whether a background
  user would need its own Screen Recording/Accessibility grants for
  the codex binary) — hypothesis; verify via docs or the jevbench
  path.
- What the jevbench step would add; what remains unverified.

**Secrets discipline**: no API keys in files/logs — ChatGPT auth
only; child env restricted to what codex needs (mirror
CodexProtocolClient's env-allowlist approach); CODEX_HOME under
`spikes/codex-cu/home/` and **`.gitignore` includes `home/`** —
auth.json is symlinked in there and must never be committed.

## Milestones

- [ ] M1 spike scaffold + probe (version/features/auth/
      configRequirements incl. ComputerUseRequirements + model list)
      + corpus + dirty-baseline capture
- [ ] M2 unattended turn runs: approvals matrix + canary corpus on
      this session, rows + verifiers + run log
- [ ] M3 background-session analysis + REPORT.md + verdict
- [ ] M4 acceptance + judge + commits

## Owned paths

```text
spikes/codex-cu/**
.agent/phases/P2c-codex-cu-headless.md
.agent/acceptance/P2c.json
.agent/PROGRESS.md
```

## Acceptance mapping

- P2c-1 → M1 (scaffold, baseline)
- P2c-2 → M1 (probe block contents)
- P2c-3 → M2 (canary corpus + independent verify)
- P2c-4 → M2 (unattended-approvals evidence)
- P2c-5 → M3 (background-session section)
- P2c-6 → M3 (report + verdict + handoff)
- P2c-7 → M1+M2 (secrets/env hygiene)
- P2c-8 → M4 (judge + commits)

## Gates

- G1: user approval (this plan + acceptance file)
- G2: implementer contract — jarvis-implementer profile, owned paths
      only, honest statuses, verify-everything
- G4: fresh-context jarvis-judge on integrated tree
- G7: commits on `ship/v1-p2c` (milestone + acceptance flip);
      `.agent/PROGRESS.md` entry; decision propagated to
      `.agent/phases/P2c-*.md` Decision Log + Handoff

## Surprises & findings (fill during execution)

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|

## Outcomes & Retrospective

<Filled at G7.>

## Handoff

<Filled at G7 — must name: the verdict, what a background-agent lane
would need (auth, TCC, session model, jevbench), measured
latency/tokens, what P-next builds on it or why discarded.>
