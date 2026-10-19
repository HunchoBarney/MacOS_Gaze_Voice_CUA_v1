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

Evidence: `spikes/codex-cu/results/` (results.json, REPORT.md, run-*.log,
superseded run-*.rows.json). All runs on 2026-10-19, vendored codex 0.160.0.

- **The vendored codex has no computer tool of its own.** With the
  `computer_use` feature stable+enabled and an empty config,
  `mcpServerStatus/list` shows only `codex_apps` (698 connector tools,
  zero CU tools) and the model answers `NO_COMPUTER_TOOL`. Computer use
  comes from an EXTERNAL host installed by the ChatGPT desktop app:
  `~/.codex/computer-use/Codex Computer Use.app` (SkyComputerUseService +
  SkyComputerUseClient). The desktop app normally reaches it through
  `node_repl` + the `@oai/sky` JS package (computer-use plugin skill);
  the host's `~/.codex/config.toml` also carries a disabled
  `[mcp_servers.computer-use]` entry (`SkyComputerUseClient mcp`). The
  spike uses that MCP form (`mcp_sky`): 10 tools (list_apps,
  get_app_state, click, type_text, press_key, scroll, drag, set_value,
  select_text, perform_secondary_action). No mouse-move tool exists; the
  activation prompt falls back to get_app_state.
- **Cold start**: the first Sky calls after SkyComputerUseService launches
  return `bootstrapTimedOut` (run 1). Fix: a direct
  `mcpServer/tool/call list_apps` warm-up per session (no model turn),
  ~6s the first time, then calls succeed.
- **The real gate is Sky's per-app approval, delivered as an MCP
  elicitation** — `mcpServer/elicitation/request`, mode `form`, message
  "Allow ChatGPT to use TextEdit?", `_meta: {"persist": ["always"]}`,
  empty requestedSchema. Codex config does NOT pre-answer it:
  `approval_policy=never` (scoped AND never variants) makes codex
  auto-DECLINE it ("Computer Use approval denied via MCP elicitation"),
  even for apps on the `computer_use.macos.bundle_ids` allow-list.
  `default` and `auto_review` forward it to the client; the auto-review
  subagent does not resolve it.
- **Zero-human-click works when the CLIENT answers the elicitation.**
  Added variant `client_allowlist` (no config delta; the spike client
  accepts the elicitation only if it names a corpus app, declines
  everything else). Accepting with `content: {}` and no persist meta
  did NOT persist across sessions (later scoped/never runs still denied).
  Dictionary (out of list) was refused every run — the scope boundary is
  client-side.
- **`allowPersistentApproval` / `allowLockedComputerUse` are not
  client-settable.** Both live only in `ComputerUseRequirementsToml`
  (binary strings); `ComputerUseConfigToml` has 3 fields; writing
  `computer_use.allow_persistent_approval` does not show up in the
  `config/read` readback. `configRequirements/read` → `{"requirements":
  null}` on this machine.
- **No TCC prompt for codex**: Sky actuation runs under the
  already-granted `Codex Computer Use.app`; no TCC dialog was seen in any
  run (needs_human never came from TCC).
- **Verifier traps (not codex bugs)**: CU `type_text` of a MARK leaves
  AppKit's autocorrect `NSCorrectionPanel` in `_interceptEvents`, which
  stalls Apple Events to TextEdit/Notes (proven with `sample`). Verifiers
  fall back to AX reads (TextEdit) or send Escape (Notes) before reading.
  TextEdit's `whose text contains` fails with -1700. macOS 26
  Calculator's display is only reachable by walking UI elements (lazy
  SwiftUI AX tree; `entire contents` returns nothing). Sky's
  `get_app_state` times out (-10005) on a running TextEdit with zero
  windows → runner quits TextEdit only when it has 0 documents.
- **Runner safety bug found + fixed**: started as a background job, the
  runner inherited SIGINT=SIG_IGN, so ctrl-c did nothing (run 1, stopped
  with SIGTERM + manual app-server kill; no orphans). The runner now
  installs INT/TERM handlers; runs 2–5 stopped cleanly with
  `leaked={}`.
- **Autocorrect rewrites typed text**: CU `type_text` of `p2c-…` landed
  as `P2c-…` in TextEdit and Notes. Verifiers (AppleScript `contains`,
  which ignores case) still attribute the text to the run, but a strict
  exact-text check would pass only finder.reveal.
- **Calculator restores state across launches**: in run 5 it relaunched
  showing run 4's `4+7 = 11`, and the agent claimed success after only
  reading state. The actuation requirement classed it `ok_no_cu` (no false
  Done). The pre-snapshot can't see restored state while the app isn't
  running.
- **Side effects outside the sandbox**: TextEdit iCloud autosave wrote 5
  MARK-only `.rtf` files into `~/Library/Mobile
  Documents/com~apple~TextEdit/Documents` despite `close … saving no`
  (moved to iCloud Trash after verifying contents). Deleted MARK notes sit
  in Notes' Recently Deleted.
- Tokens per CU task: ~150–200k input (75–88% cached), ≤301 output.
  Turn wall time 22–85s.

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|
| 1 | 2026-10-19 | Mechanism = Sky MCP server (`SkyComputerUseClient mcp`, from `~/.codex/computer-use`) wired into a spike CODEX_HOME | Discovery order: bare vendored codex has no CU tool (zero-turn `mcpServerStatus/list` + model `NO_COMPUTER_TOOL`); mcp_sky exposes 10 CU tools. `codex exec` + node_repl/@oai/sky were not needed |
| 2 | 2026-10-19 | Added variant `client_allowlist` (no config delta; client accepts Sky's per-app elicitation only for corpus apps) beyond the 5 predeclared variants | All 5 predeclared variants were measured first; none clears the gate (never/scoped auto-decline it, default/auto_review forward it to the client, persistent not settable). The brief said server→client asks are "answered per config", and answering them is exactly what a product client would do |
| 3 | 2026-10-19 | Verdict by predeclared rule: **PROMOTE (this console session only)** — G4 judge confirmed PROMOTE is the correct label: CONDITIONAL requires *reduced unattended-ness*, and `client_allowlist` is genuinely zero-click. Rows: run 20261019-162132 corpus under client_allowlist, textedit.type/finder.reveal/notes.snippet = ok with cu_evidence, 0 declined asks, p50 27.6s, Dictionary refused, 0 transport deaths | Deployment prerequisites (handoff conditions, not verdict demotions): (a) JevVoice's client owns the `mcpServer/elicitation/request` policy — substring allow-list is spike-grade, needs exact bundle-id matching for product; (b) product ships or requires the ChatGPT app's `Codex Computer Use.app`; (c) 2 of 3 ok rows match the MARK case-insensitively (autocorrect `p→P`) — case-insensitive verifier, not exact-text fidelity; (d) background/multi-user behaviour unverified (needs jevbench) |

## Outcomes & Retrospective

5 runs. Runs 1–4 exposed mechanism, cold-start, gate, verifier and
runner-signal problems; each was fixed in the spike and the superseded
rows are kept in `results/run-*.rows.json`. Run 5 is the clean evidence
run. G4 judge: PASS (7/7), verdict confirmed PROMOTE under the
predeclared rule. Lesson: macOS app quirks (autocorrect panels, iCloud
autosave, state restore) dominate the cost of independent GUI
verification. Any P-later GUI bench should budget for them and use
spell-safe markers.

## Handoff

- **Verdict**: **PROMOTE for THIS console session** (3/4 canary tasks
  ok with cu_evidence under `client_allowlist`, 0 human clicks,
  p50 27.6s, scope refusal verified). Not background-session proof;
  Decision Log #3 lists the deployment prerequisites.
- **What a background-agent lane needs**:
  - auth: existing ChatGPT login via an auth.json symlink. Proven: a
    fresh CODEX_HOME per agent works.
  - CU host: `Codex Computer Use.app` (ChatGPT desktop app install),
    wired in as an MCP server. Warm it once per session.
  - approval: the client answers `mcpServer/elicitation/request` from a
    JevVoice-owned app allow-list (maps onto the locked Permissions
    decision). Codex config cannot do this: `approval_policy=never`
    declines the request.
  - TCC: no prompt was seen; the grants sit on Codex Computer Use.app.
  - session model: unverified, see below.
- **Measured**: turn wall 22–85s per task (p50 27.6s); ~150–200k input
  tokens per task (75–88% cached), ≤301 output; Sky warm-up 6–11s
  per session.
- **P-next builds**: a JevVoice client answerer (allow-list policy +
  audit of every elicitation), a CU-host presence/version check, and
  the jevbench run below.

### Background / multi-user session (labeled)

- **[verified]** All runs used the logged-in console session; Sky drove
  hidden/background apps without bringing them frontmost.
- **[documented]** `allowLockedComputerUse` and `allowPersistentApproval`
  exist only in `ComputerUseRequirementsToml` (requirements.toml / MDM /
  cloud), not in user config. This machine returns `requirements: null`.
- **[documented]** The Sky bundle contains `CUALockScreenGuardian.app`
  (the file exists; its behaviour was not tested).
- **[unverified]** Whether `allowLockedComputerUse` enables actuation on
  a locked or switched-out session.
- **[unverified]** Whether a fast-user-switched (non-console) session has
  a WindowServer Sky can actuate. Needs the jevbench user
  (`sudo scripts/bench/create-test-user.sh`, a human step that was not
  done).
- **[unverified]** Per-user TCC: a background user most likely needs its
  own Accessibility/Screen Recording grants for Codex Computer Use.app
  (TCC databases are per-user). This is a hypothesis.
- **[unverified]** Whether Codex Computer Use.app and its per-app
  approvals exist for another macOS user.
