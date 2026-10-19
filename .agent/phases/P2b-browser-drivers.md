# P2b — Browser-driver spike: chrome-devtools-mcp vs Cua `browser_*`

## Purpose

Produce the numbers behind the browser-driver pick. PROGRAM.md locks
"Chrome DevTools MCP `--autoConnect` on bundled node; Cua `browser_*`
fallback" and P7 builds `BrowserDecider` + three `BrowserDriver` impls
(CONTRACTS.md §5) — but that direction rests on design intent, not
measurement. This spike measures both drivers on identical corpora —
per-op p50/p95, success rates, robustness — and records a driver pick
with the numbers behind it.

## Context

**Both contenders share one attach primitive.** Chrome ≥136 refuses
`--remote-debugging-port` on the default user-data dir (cookie-theft
hardening). The sanctioned logged-in path is Chrome ≥144's per-instance
`chrome://inspect/#remote-debugging` toggle, which writes
`~/Library/Application Support/Google/Chrome/DevToolsActivePort` and
opens a **WebSocket-only** listener (`/json/*` returns 404 — verified
live 2026-10-19). Cua's `existing_profile` route re-proves this exact
endpoint through the same file (`browser/engine.rs:1030-1056`);
chrome-devtools-mcp reaches it via `--autoConnect`. The spike compares
abstraction layers + robustness — not two different attach mechanisms.

**The drivers differ on tab capability — this shapes the corpus.**
chrome-devtools-mcp can create a self-owned tab on the real profile
(`new_page` → `Target.createTarget`) and run the full mutating corpus
inside it. The Cua tool registry exposes **no tab-lifecycle verbs**
(`browser/tools.rs` — `browser_navigate` requires an existing
`target_id`+`tab_id` from a bound target), so on `existing_profile` the
only workable tab is a user's own tab — which the spike's safety rules
forbid mutating. Consequence, decided up front:

- **Arm A — real profile**: devtools-mcp `--autoConnect` runs the FULL
  corpus inside a spike-owned tab it creates and closes. Cua
  `existing_profile` runs **read-only ops only** (attach +
  `get_browser_state` snapshot); its mutating verbs record
  `unsupported` in this arm. The asymmetry is itself a finding: on the
  logged-in surface, devtools-mcp can act in a self-owned tab while
  Cua can only read (production would let it act on user tabs, but the
  spike must not).
- **Arm B — isolated profile**: devtools-mcp `--isolated` (temp
  user-data-dir, auto-cleaned) vs Cua `isolated_new` (own
  `--user-data-dir` + `ManagedBrowser::drop` teardown —
  `browser/prepare.rs:233-264,353-354`). Identical full mutating
  corpus both sides. Op latency is profile-independent (same CDP
  codepaths), so Arm B carries the latency comparison; Arm A carries
  the real-profile capability comparison.

Machine facts (verified 2026-10-19):

- Chrome **155.0.8059.82** running, inspect toggle ON, ws listener on
  `127.0.0.1:9222`, `DevToolsActivePort` present (port + ws path lines)
- `chrome-devtools-mcp` npm: `1.11.0` published 2026-10-15 (4 days —
  fails the 7-day dep rule) → **pin `1.10.1`** (2026-09-23)
- Upstream issue `ChromeDevTools/chrome-devtools-mcp#1830` reported
  `--autoConnect` failing on macOS default profile — on v0.21.0 (old
  line); whether 1.10.x attaches here is a spike question, not a given
- Cua driver binary:
  `~/jarvis-local/Jev Voice.app/Contents/Resources/cua-driver`
  (`CuaDependency.bundledExecutable`); spawn shape per
  `CuaConnection.swift:113-114`:
  `mcp --embedded --socket <socket> --host-bundle-id com.chriswozniczek.jevvoice`
- Daemon socket: one line in
  `~/Library/Application Support/JevVoice/cua.socket`, rewritten by the
  app on every daemon re-mint (`CuaDriveServer.swift:26-28,48-56`);
  `JEV_CUA_SOCKET` env override exists
- The Cua arm needs the JevVoice app running — the app's
  `CuaDaemonHost` spawns `cua-driver serve` and vends the socket; if
  the app is down, the Cua arm records `blocked_env`. The real grants
  on this path are the daemon launch flags (e.g.
  `--grant existing-profile`, `CuaDaemonHost.swift`) plus Routine-mode
  consent for `browser_bound_input` — NOT `policy.json`
  `standingGrant`, which only `--mcp-stdio` consults
  (`CuaDriveServer.swift:58-62`)
- `browser_*` calls take `"session": <label>` (`require_explicit_session`,
  `browser/tools.rs`); the P1 wedge says session labels tombstone to
  dead transports → the spike mints a **unique session label per
  spawned proxy** (`p2b-<pid>-<n>`), calls `end_session` in a `finally`
  (fires `ManagedBrowser::drop` — kills isolated Chrome + removes its
  profile dir, `browser/session.rs` → `engine.rs:644-703` →
  `prepare.rs:233-264`), then terminates the proxy. The app spawns this
  proxy WITHOUT `--parent-liveness-stdio`
  (`CuaConnection.swift:113-114`) — P1 observed orphaned transports —
  so proxy lifetime is managed explicitly
- Full `browser_*` vocabulary proven in production:
  `browser_prepare` → `list_windows` → `get_browser_state`
  (`semantic_v2` refs) → `browser_navigate` → `browser_click`
  (`input_route: "dom_event"`, `BrowserActuation.swift:75-82`) →
  `browser_type` (`CuaSetup.swift:114-177`)
- MCP stdio framing is newline-delimited JSON-RPC — the same client
  discipline as `bench/lib/mcp_stdio.py` (~190 lines; copy the client
  core into the spike — `bench/` stays untouched)

Pre-existing dirty baseline (for the P2b-1 check): the worktree carries
the user's uncommitted set (dozens of `Sources/`, `EyeTracking/`,
`Tests/`, `bench/` modifications + deletions). `git diff` on those
paths can never be empty — so **M1 captures the baseline durably**:
`git status --porcelain` + `git diff` written to
`spikes/browser-drivers/results/dirty-baseline.txt` (owned path,
committed). The check is then mechanical: `git show --name-only` on
phase commits shows only owned paths, and `git diff` on non-owned
paths matches the recorded baseline with no new hunks.

## Owned paths

```text
spikes/browser-drivers/**
.agent/phases/P2b-browser-drivers.md
.agent/acceptance/P2b.json
.agent/PROGRESS.md
```

Writing outside this list is a violation — including `Sources/`,
`bench/`, `EyeTracking/`, `ThirdParty/`, `development/` (read-only for
this phase; the spike's op corpus lives inside the spike).

## Non-goals

- No production wiring, no `BrowserDriver` impl, no Swift changes —
  P7 builds on this phase's numbers.
- No fix for the session-label wedge (P4-owned), no `bench/` changes
  (the spike's corpus is its own, not bench tasks).
- No pixel-path comparison — P5 doesn't exist yet; the spike records
  absolute per-op numbers and P7 does the ≥2×-vs-Sol comparison later.
- CONTRACTS §5 `key`/`scroll`/`back` actions are not in the corpus —
  named as unmeasured in the Handoff.
- No pushing; commits only after acceptance + judge gates (G7).

## Forbidden

- Never touch the user's existing Chrome tabs — on Arm A, Cua's
  `existing_profile` runs read-only (`get_browser_state`); devtools-mcp
  creates its own tab, works only in it, closes it in a `finally`, and
  the run records `list_pages` count before/after.
- Read-only on real sites: no posting, purchases, settings changes,
  form submits, or logged-in mutations. Logged-in surfaces are entered
  only to prove real-profile DOM access. Mutating corpus ops
  (click/type) on real sites must target **non-mutating refs** —
  navigation links, inert buttons, a search box focus+type with NO
  submit; `sites.json` entries declare their safe-target selector per
  op, not just a URL.
- No `browser_prepare` with `allow_launch` against the user's default
  profile; `existing_profile` binds the running Chrome, `isolated_new`
  spawns a throwaway profile dir owned by the spike run.
- No `--remote-debugging-port` relaunch of the user's Chrome — the
  toggle endpoint is already live; if it isn't, that's `blocked_env`,
  not a workaround to invent.
- If `--autoConnect` never attaches after the spec'd attempts, every
  devtools row records `blocked_env` and the report says so — the pick
  is then recorded honestly as evidence-limited, not silently
  Cua-by-default.
- No leaking processes/state: `end_session` + proxy terminate in
  `finally` on the Cua side; devtools-mcp's `--isolated` temp dir
  auto-cleans but the spike verifies `list_pages`/process state after.
- No commits until acceptance evidence + judge PASS (G7).

## Design

`spikes/browser-drivers/` — self-contained: `package.json` pinning
`chrome-devtools-mcp@1.10.1` exactly (installed to the spike's own
`node_modules` via `npm install` inside the spike dir — never the
repo's pnpm files), committed `package-lock.json`, `.gitignore` =
`node_modules/` ONLY (`results/` is the committed deliverable — do
NOT ignore it).

- `probe.py` — environment checks, prints PASS or `blocked_env` per
  check and appends them to `results/results.json` under `probe`:
  1. `~/Library/Application Support/JevVoice/cua.socket` exists, and
     the bundled `cua-driver` is executable; spawn
     `mcp --embedded --socket <hint> --host-bundle-id <id>` and answer
     `initialize`+`tools/list` (the real daemon liveness check)
  2. `DevToolsActivePort` exists; parse port + ws path; real stdlib
     WebSocket handshake (raw `socket`+`base64`+`sha1`, no deps)
     against `ws://127.0.0.1:<port>/devtools/browser/<id>` → 101;
     record that `/json/*` 404s
  3. Chrome version ≥144
  4. `existing_profile` feasibility = attach + read-only
     `get_browser_state` on the bound tab only (no mutation attempt)
- `ops.py` — the driver-neutral corpus; exact tool names discovered at
  runtime via `tools/list` and recorded per driver:
  | op | devtools-mcp | Cua `browser_*` |
  |---|---|---|
  | attach | server spawn + `initialize` + `list_pages` (Arm A `--autoConnect`, Arm B `--isolated`) | proxy spawn + `initialize` + `start_session` + `browser_prepare` — Arm A args `{strategy:{kind:"existing_profile"}, pid, window_id}` bound via `list_windows`+`get_browser_state` (`BrowserSupport.swift:52-91`); Arm B args `{profile:{mode:"isolated_new"}, allow_launch:true}` (`CuaSetup.swift:114-120`) |
  | open_tab | `new_page` (Arm A only — Arm B's launch makes its tab) | `unsupported` (Arm A); `browser_prepare` side effect (Arm B) |
  | navigate | `navigate_page` | `browser_navigate` |
  | snapshot | `take_snapshot` | `get_browser_state` `semantic_v2` |
  | click | `click` by uid | `browser_click` ref + `dom_event` |
  | type | `fill`/`type_text` | `browser_type` |
  | extract | `evaluate_script` read-only expr | `get_browser_state` content fields as exposed |
  | settle | time-to-settled post-navigate | same signal as exposed |
  | close_tab | `close_page` | `end_session` (Arm B tears down the instance) |
  Statuses: `ok | driver_error | timeout | refused | unsupported |
  blocked_env`. Cua Arm-A mutating rows emit `unsupported`, never
  silently skipped.
- `run.py` — timing discipline. **One measured run drives BOTH
  drivers in one process** — `run.py` with no `--driver` flag runs the
  interleaved measurement; `--driver cua|devtools` exists for smoke/
  single-side debugging only and its rows are flagged
  `ordering: single` (never mixed into the interleaved comparison set).
  **Attach measured separately**: `attach_ms` = spawn + handshake +
  session/prepare + first-list, plus `teardown_ms` = close/end_session
  + transport exit. The attach+teardown cycle is itself timed **N=5
  per arm×driver** (covers open_tab/close_tab lifecycle costs — Cua's
  `end_session` destroys the session+isolated Chrome, so these live in
  the cycle table, not the per-op table). Per-op timing runs inside
  ONE attached session: warmup 3, timed N=15 per driver,
  **interleaved A/B ordering** (devtools iter, then cua iter,
  alternating — cancels warm HTTP cache/DNS/TLS bias on real sites).
  `time.monotonic()` around each MCP roundtrip. Rows `{arm, driver,
  op, site, iter, wall_ms, status, detail, session_label, ordering}` —
  for Cua Arm-A read-only rows `site` records the bound user tab
  (`site: "bound-user-tab"` + its URL in detail) since Cua can't
  navigate there. Timeouts: navigate 30s, snapshot 15s, others 10s —
  a timeout is a row, not an abort.
- `sites.json` — `example.com` (baseline), a dense-DOM read-only page
  (Wikipedia article), `github.com` (Arm A real-profile DOM proof —
  read-only), one SPA-class page. Arm B hits the same URLs on fresh
  profiles (logged-out is fine — latency is profile-independent).
- `robustness.py` — matrix rows: stale-ref click after navigation
  (expect clean refusal — measure error quality), iframe-heavy page
  snapshot, cross-origin nav, snapshot bytes per site (token-cost
  proxy — the DOM-first pitch is cheap context), re-attach after
  killing the spawned proxy/server (resilience).
- `report.py` → `results/REPORT.md`: per-op p50/p95 by (arm × driver),
  success matrix, attach-cost table, snapshot-byte table, robustness
  matrix, and the pick — `devToolsMcp` | `cua` | `hybrid` — with the
  numbers. `results/results.json` is the committed raw artifact.

## Milestones

### M1 — scaffold + env probe + corpus

- `spikes/browser-drivers/` package (pin `1.10.1`, `.gitignore` =
  `node_modules/`, `npm install` inside spike dir only, committed
  `package-lock.json`)
- `probe.py` checks above; `sites.json` + `ops.py` committed
- Record the environment table in Surprises: app/socket state, Chrome
  version, toggle state, ws handshake result

Checks: `python3 spikes/browser-drivers/probe.py` → all PASS or named
`blocked_env`; `node_modules/.bin/chrome-devtools-mcp --help` prints;
`git show --name-only` on any interim commit shows owned paths only.

### M2 — Cua side measured (both arms)

- Unique session labels per proxy; `tools/list` recorded;
  `browser_prepare` `existing_profile` (Arm A, read-only ops) +
  `isolated_new` (Arm B, full corpus) — each labeled, never silently
  substituted
- All ops timed per the interleaved discipline; robustness rows;
  `end_session` + proxy terminate in `finally`; app/daemon left
  running

Checks: `python3 spikes/browser-drivers/run.py --driver cua --smoke`
prints rows; full run writes cua rows to `results/results.json`;
**leak check against a recorded baseline** — `pgrep -f "cua-driver
mcp"` is captured BEFORE the run (production proxies are a known-real
state; the check is no NEW `cua-driver mcp` processes vs baseline),
captured after, diff empty; `python3
spikes/browser-drivers/robustness.py --driver cua` prints matrix rows;
no stray Chrome/profile dirs from `isolated_new`.

### M3 — devtools-mcp side measured (both arms)

- `--autoConnect` (Arm A) + `--isolated` (Arm B); the Chrome
  permission dialog outcome recorded (one-time human click is a
  documented step — if none appears, record that fact)
- Same corpus/sites/timing; robustness rows; spike-owned tab closed;
  `list_pages` before/after equal

Checks: `python3 spikes/browser-drivers/run.py --driver devtools
--smoke` prints rows; full run writes devtools rows; `python3
spikes/browser-drivers/robustness.py --driver devtools` prints matrix
rows; `list_pages` count before/after equal — user Chrome has exactly
the tabs it started with.

### M4 — report + pick + acceptance + judge + commits

- `report.py` → `REPORT.md` + verdict paragraph; phase file verdict
  (Surprises + Decision Log), Progress checked, Retrospective/Handoff
  filled (what P7 builds on the winner, the fallback story, the
  unmeasured: `key`/`scroll`/`back` + pixel-path comparison)
- Acceptance evidence; `check-acceptance.py` green;
  `check-owned-paths.py` green; fresh-context `jarvis-judge` PASS;
  milestone + acceptance commits on `ship/v1-p2b`

Checks: `python3 scripts/check-acceptance.py .agent/acceptance/P2b.json`
→ N/N; `python3 scripts/check-owned-paths.py P2b` → all staged owned.

## Acceptance mapping

| Criterion | Milestone check |
|---|---|
| P2b-1 self-contained spike | M1 checks + `git show --name-only` on phase commits |
| P2b-2 probe + ws handshake + blocked_env | M1 `probe.py` output → `results.json` `probe` block |
| P2b-3 Cua sessions/labels/statuses/no leaks | M2 checks + cua rows |
| P2b-4 devtools autoConnect + tab discipline | M3 checks + `list_pages` before/after |
| P2b-5 robustness matrix | M2/M3 robustness rows → REPORT.md |
| P2b-6 report + reproducible numbers | M4 `report.py` output + row recompute |
| P2b-7 verdict recorded | M4 phase-file sections |
| P2b-8 gate discipline | M4 acceptance/judge/owned-paths/commits |

## Gates

- G1: this plan + acceptance file — user approval (judge-checked first)
- G2: implementer confirms corpus/tool-name mapping before measuring
- G3: per-milestone checks green
- G4: fresh-context `jarvis-judge` review of artifacts vs acceptance
- G5: N/A — this phase IS the measurement; the spike's own runs are
  the live validation
- G6: no human-acceptance step — verdict is recorded from measured
  numbers, not taste
- G7: commits only after evidence + judge PASS

## Progress

- [x] M1 scaffold + env probe + corpus
- [x] M2 Cua side measured
- [x] M3 devtools-mcp side measured
- [ ] M4 report + pick + acceptance + judge + commits
  (REPORT.md + pick drafted; acceptance/judge/commits outstanding)

## Surprises & Discoveries

- Chrome's own docs confirm `--autoConnect` requires Chrome 144+ AND
  the user enabling Remote Debugging in `chrome://inspect` — already
  satisfied here (Chrome 155, live listener verified).
- The toggle endpoint is **WebSocket-only** — `/json/version` 404s;
  `--browser-url` HTTP discovery cannot work on it. Verified live.
- Cua `browser_*` is a CDP client (`cua-driver-core/src/cdp.rs`) with
  no tab-lifecycle verbs — `existing_profile` can only bind a user's
  existing tab → the two-arm design (read-only real-profile arm +
  full-corpus isolated arm) exists because of this, not preference.
- Cua's `isolated_new` launches Chrome `--remote-debugging-port=0
  --user-data-dir=<owned>` (`prepare.rs:353-354`) — the Chrome-136-safe
  route — and `ManagedBrowser::drop` SIGKILLs the group + removes the
  profile dir on `end_session` (`prepare.rs:233-264`).
- Session labels tombstone to dead transports (P1 wedge) → unique
  `p2b-<pid>-<n>` per spawned proxy; product fix stays P4's.
- The `mcp --embedded` proxy lacks `--parent-liveness-stdio`
  (`CuaConnection.swift:113-114`) — P1 saw orphaned transports; the
  spike terminates proxies explicitly.
- `policy.json` `standingGrant` is consulted only by `--mcp-stdio`
  (`CuaDriveServer.swift:58-62`), which the spike bypasses — the real
  gates are daemon launch grants + Routine-mode consent for
  `browser_bound_input`.

Environment at implementation (verified live 2026-10-19, refreshed
post-run):

| fact | value |
|---|---|
| JevVoice app | running, pid 60409 |
| daemon socket | `cua.socket` → `/var/folders/.../jev-cua-60409-1500340c.sock` — **re-minted mid-run** (was `...-95688121.sock` at baseline); the hint file must be re-read per attach |
| bundled driver | `~/jarvis-local/Jev Voice.app/Contents/Resources/cua-driver` v0.34.0, executable; daemon launch flags include `--grant existing-profile` |
| `mcp` proxy baseline/after | baseline: app-owned 60436, 60437 (`...-95688121.sock`); after: app-owned 72285 (`...-1500340c.sock`, ppid 60409 — daemon re-mint churn, not a spike leak); spike-spawned proxies all terminated, `cua_proxies_leaked: []` |
| Chrome | 155.0.8059.82 running (pid 84132) |
| inspect toggle | ON; `DevToolsActivePort` = port 9222 + `/devtools/browser/92cf2f64-...` |
| ws handshake | real stdlib handshake SENT, recv timed out at 10s — the toggle endpoint holds the connection pending consent (below) |
| `/json/version` | 404 as expected (ws-only endpoint) |
| tools/list | cua proxy: 58 tools (server 0.34.0); devtools-mcp 1.10.1: 31 tools incl. new_page/navigate_page/take_snapshot/click/fill/evaluate_script/close_page, all page-scoped via `pageId` (**numeric**, not string) |
| stray state | no running isolated Chrome; `isolated-882883f7-...` dir leaked by a killed transport, verified empty + removed — only the pre-existing `isolated-c47a53c5-...` remains |

Post-implementation surprises:

- **Chrome's "Allow remote debugging?" consent dialog gates BOTH
  Arm-A attach paths.** The moment the spike's ws handshake or the
  daemon's `browser_prepare` touches the toggle endpoint, Chrome shows
  a consent dialog in the user's browser (two were pending in
  `list_windows` — a window titled "Allow remote debugging?" owned by
  the Chrome pid). While it pends: `get_browser_state` bind-mode
  refuses `browser_consent_required`; `browser_prepare` fails
  `browser_wrong_target_refused` ("consent did not settle for reconnect
  attempt"); `--autoConnect` never answers `list_pages` (attach timed
  out at ~19s → recorded `blocked_env`). This is the spec'd dialog
  path — Arm-A devtools/cua rows are `blocked_env` with the dialog
  noted unless a human clicks Allow mid-run.
- `list_windows` returns the consent-dialog windows as Chrome windows —
  the Arm-A binder must rank candidates (dialogs sorted last) and try
  binds in order, since a dialog window can never mint a tab. Binds
  themselves do not stack new dialogs; `browser_prepare` retries would,
  so the spike skips prepare when the dialog is already pending.
- The `mcp --embedded` proxy exits cleanly on stdin EOF — no orphan
  transport even when the spike's python exits without `end_session`.
- semantic_v2 splits `content_refs` (readable content) from `refs`
  (actionable elements: `actions:["click","pointer"]`, editable =
  `"type" in actions`). The corpus reads `refs` only — on example.com
  the actionable link is `p<n>:7 "Learn more"`, not the visible-text
  "More information..." (snapshot wording vs accessible name differ).
- Intermittent transport death observed: one `mcp` proxy exited
  mid-`semantic_v2`-snapshot on the Wikipedia DOM (~60 KB) — stdout
  EOF at ~8s, not a timeout; the same call succeeded standalone at
  14.4s. Re-attach immediately after hit "mcp child closed stdout"
  during initialize — consistent with the P1 tombstone wedge (session
  reaping lags transport death). run.py retries reattach ×2 with
  backoff; deaths are recorded as rows, never swallowed.
- `extract` (get_browser_state `query`) on the Wikipedia DOM exceeded
  the 10s op budget once — a timeout row, transport closed per client
  discipline, next iter reattaches.
- The intermittent transport death recurred systematically at scale: of
  15 timed Arm-B iters, wikipedia `semantic_v2` snapshot timed out 10×
  (15s deadline; the one robustness-matrix success took 10.3s/63KB) and
  the proxy died outright on stdout EOF in several iters — github/spa
  cells in the same iter are cascade `driver_error`, not capability.
  Per-iter reattach always recovered (16 sessions over 18 iters).
- Measured attach/teardown (N=5+session, Arm B): devtools `--isolated`
  attach p50 6228ms / p95 9002ms, teardown p50 270ms; cua
  `isolated_new` attach p50 11731ms / p95 15781ms (isolated Chrome
  launch dominates), teardown p50 407ms (`end_session` →
  `ManagedBrowser::drop` kills the isolated Chrome).
- Measured Arm-B corpus (N=15 timed, interleaved): devtools ok on
  every non-type cell on all four sites (navigate p50 1334ms, snapshot
  p50 164ms, click p50 1093ms, extract p50 222ms, settle p50 216ms);
  cua ok on all of example.com plus wikipedia navigate/settle
  (navigate p50 1692ms, example snapshot p50 ~68ms).
- The as-run corpus clicked before typing; on wikipedia the click
  navigates → `type` hit stale refs every iter for BOTH drivers
  (devtools `Element with uid N no longer exists`; cua clean
  `refused browser_ref_stale`). Real robustness evidence: both drivers
  detect ref staleness correctly. Source now orders type before click.
- Arm-A outcome — two eras. PRE-consent: BOTH drivers blocked by the
  same Chrome consent gate — `--autoConnect` handshake pends ~18s →
  `blocked_env`; cua `existing_profile` binds consent-gated across all
  11-15 candidate windows (dialogs appear as Chrome windows in
  `list_windows`). POST-consent (user clicked "Allow remote
  debugging?" — one click, per-Chrome-instance): ws handshake → 101 in
  2.7s, `--autoConnect` attaches, cua `existing_profile` bound a real
  logged-in tab (`console.typesafe.ai/keys`) in 12.9s.
- **Arm-A measured post-consent** (540 rows, 12 cycles, zero leaks —
  `run-armA-consented.log`): devtools `--autoConnect` attach p50
  ~8.5s (5/5 cycles ok), full corpus in a spike-owned tab on the real
  profile — snapshot p50 72ms, navigate 2274ms, settle 241ms, click
  1229ms, extract 376ms, type 610ms (one site had a usable target).
  cua Arm-A post-consent: attach ok at ~7.7-12.1s with one
  `blocked_env` cycle (bind picked a non-consented window — grants are
  per-window-ish, not fully durable); read-only ops only per design —
  snapshot p50 3.3s and extract 1.9s **on `about:blank`** — a ~2-3s
  fixed floor for `existing_profile` reads regardless of page weight
  (vs 75ms isolated-profile snapshot). Mutation on the real profile
  stays unexercised by design (no tab verbs → would need a user tab).
- cua Arm-A attach reliability is consent-settle-sensitive: while the
  dialog was dismissing, `browser_prepare` intermittently refused
  "consent did not settle for reconnect attempt" (~14-20s deadline);
  once fully cleared, **10/10 attach cycles ok** (p50 6.9s — faster
  than devtools Arm-A's 7.6s; 15 ok attempts total across runs).
  run.py's dialog-stacking guard was narrowed so only genuine
  'dialog pending' refusals skip remaining slots — settle-time
  refusals don't stack dialogs, keeping cycles measurable.
- `devtools_pages_before/after`: pre-consent never recorded (Arm A
  never attached); post-consent Arm-A recorded `list_pages` 7 before
  and 7 after — spike-owned tab created and closed, zero user tabs
  touched. The earlier never-attached claim held only for the
  pre-consent era — nothing to leak either way (user Chrome windows
  unchanged, no leftover tabs).
- The daemon re-minted its socket mid-run (~00:21): new hint path, new
  app-owned proxy (ppid 60409). Leak checking compares pid+ppid —
  spike proxies would be owned by the run pid or orphaned to launchd.
- Killing a cua proxy mid-session (reattach_after_kill check) leaks the
  isolated profile dir: `isolated-882883f7-...` was left EMPTY under
  `CuaDriver/BrowserProfiles/` — with no `end_session`,
  `ManagedBrowser::drop` never fires and nothing removes the dir (the
  isolated Chrome process itself was gone). Cleaned by hand; a
  production `BrowserDriver` needs an orphan-dir sweeper or daemon-side
  reaping for crashed transports.
- **Verdict (measured): devToolsMcp primary + cua fallback** — the
  locked direction stands. devtools: 100% of dispatchable Arm-B cells
  ok, ~1.9× faster attach, ms-scale ops; its cost is snapshot size
  (wikipedia 470KB vs cua 63KB semantic_v2). cua: compact snapshots,
  clean refusals, every robustness check passed — but transport
  fragility on heavy semantic_v2 snapshots and ~2× attach cost make it
  the fallback, not the primary. Full numbers in
  `spikes/browser-drivers/results/REPORT.md`; raw rows in
  `results.json` (2016 rows, 54 cycle entries = 864 arm-B interleaved
  + 72 single-order smoke + 540 arm-A post-consent rows + attach-cycle
  attempts across three Arm-A runs; superseded arm-A stream retained
  in `results/run-full.log`, `skipped` cascade slots reported
  separately in REPORT.md's attach table).

## Decision Log

| # | Date | Decision | Why |
|---|---|---|---|
| 1 | 2026-10-19 | devToolsMcp (chrome-devtools-mcp@1.10.1, `--autoConnect`) primary; Cua `browser_*` fallback | Arm-B interleaved: devtools 83% cell-ok vs cua 32%; attach 6.2s vs 11.7s; per-op p50s devtools navigate 1334/snapshot 164/click 1093/extract 222/settle 216 vs cua 1692/68/2088/546/746 — cua snapshot wins on bytes (8-63KB vs 1-470KB) but its semantic_v2 on heavy pages hits the 15s read deadline and killed the stdio transport (301 cascade errors). Arm-A post-consent: devtools ran the full mutating corpus on the real profile in its own tab (snapshot 72ms); cua can only read bound user tabs (~2-3s floor even on about:blank) and cannot mutate without touching user tabs — no tab-lifecycle verbs exist. P7 needs an orphan-dir sweeper for killed-proxy leaks. |

## Outcomes & Retrospective

The spike answered its question twice over. The locked direction —
chrome-devtools-mcp primary, Cua fallback — is confirmed with numbers,
and the consent gate neither side documented turned out to be the
shared first-run cost: Chrome's "Allow remote debugging?" dialog held
BOTH drivers until a human clicked once, then both attached cleanly.
That's a P10 first-run design input, not a defect.

What worked: the two-arm split (forced by Cua's missing tab verbs)
separated capability from latency cleanly; the consent-blocked era
recorded itself as `blocked_env` rows instead of aborting; unique
session labels avoided the P1 wedge entirely across ~30 spawned
sessions; the interleaved corpus kept the comparison fair.

What hurt: Cua's transport fragility on heavy `semantic_v2` snapshots
(proxy stdout EOF mid-call — the P1 wedge's sibling: reaping lags
transport death) and the 15s read deadline — a production
`BrowserDriver` on this path needs a longer read window or streaming.
Also real: an implementer-side emitter bug mid-run (Arm-A rows
mislabeled site) was caught by the row schema and regenerated —
results carry `ordering`/era fields precisely because runs get
interrupted (the laptop-lid-close between consent and rerun is exactly
the scenario).

## Handoff

**Pick: devToolsMcp primary + Cua `browser_*` fallback** (measured —
Decision Log #1).

- Arm-B (isolated, fair corpus): devtools 83% cell-ok / cua 32%;
  attach 6.2s vs 11.7s; per-op p50 — devtools {nav 1334, snap 164,
  click 1093, extract 222, settle 216}ms vs cua {1692, 68, 2088, 546,
  746}ms. Cua's one win: snapshot bytes 8-63KB vs devtools 1-470KB —
  cheaper model context, why it remains the fallback.
- Arm-A (real profile, post-consent): devtools full corpus in own tab
  (snapshot 72ms); cua read-only ~2-3s/op floor on `existing_profile`,
  no mutation without touching user tabs. First-run requires ONE
  Chrome consent click — then ws/devtoolsActivePort works (101 in
  2.7s). Post-settle attach p50: cua 6.9s (10/10 ok), devtools 7.6s;
  while the dialog is still dismissing cua intermittently refuses
  'consent did not settle for reconnect' — retry, don't fail.
- P7 builds: `ChromeDevToolsDriver` (primary, `new_page`-owned tabs,
  `pageId` numeric handles) + `CuaBrowserDriver` (fallback —
  `get_browser_state` read paths, isolated-profile acting when the
  real profile isn't granted). SafariAppleEventsDriver unchanged.
- Robustness findings for P7: stale-ref refusals are clean on both
  drivers (devtools uid error vs cua `browser_ref_stale`); reattach
  after transport death works (devtools 4.7s, cua 12.5s) but cua
  leaks an empty `isolated-*` profile dir when the proxy dies
  mid-session — needs a sweeper or daemon-side reaping.
- Unmeasured: CONTRACTS §5 `key`/`scroll`/`back`; pixel-path
  comparison (P5 doesn't exist yet — absolute numbers recorded for the
  ≥2× check); cua `type` never got a clean timed row; devtools
  Arm-A against *other* logged-in surfaces (only github/example/
  wikipedia/spa ran).

Artifacts: `spikes/browser-drivers/` — `probe.py`, `ops.py`,
`run.py`, `robustness.py`, `report.py`, `sites.json`, `mcp.py`,
`package.json`/lockfile (`chrome-devtools-mcp@1.10.1`),
`results/{results.json (2016 rows, 54 cycle records, 26 robustness cells),
REPORT.md, run-full.log, run-armA-consented.log, robustness.log,
dirty-baseline.txt, devtools-stderr.log}`.
