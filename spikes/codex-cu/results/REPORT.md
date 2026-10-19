# P2c — codex app-server computer-use headless spike — REPORT

Generated 2026-10-19 16:37 from `results/results.json` (run 20261019-162132, log `results/run-20261019-162132.log`).

## Verdict

**PROMOTE** against the predeclared rule (ExecPlan §Verdict rule) — covers **THIS console session only**; it is NOT background/multi-user-session proof (see the labeled section below).

| rule clause | met | evidence |
|---|---|---|
| >=2 canary tasks ok WITH cu_evidence under one zero-click config | yes | 3 under client_allowlist: ['textedit.type', 'finder.reveal', 'notes.snippet'] |
| p50 per-task wall <= 120s | yes | 27628 ms |
| no unbounded actuation (scope refusal verified under that config) | yes | scope.refuse:refused |
| no unrecoverable transport | yes | 0 rows with EOF/kill |

### Caveats that qualify this verdict (read before acting on it)

1. The zero-click config `client_allowlist` was ADDED mid-spike; it is not one of the five predeclared variants. All five predeclared variants failed to clear Sky's per-app gate (scoped/never: codex auto-declines the elicitation; auto_review/default: forwarded to the client; persistent: not settable). Zero clicks happen only because the CLIENT answers the elicitation from its own app allow-list.
2. The computer tool is NOT in the vendored CodexRuntime: it is the ChatGPT desktop app's `Codex Computer Use.app`, wired in as an MCP server (`mcp_sky`) by the spike. A product lane depends on that external install.
3. Autocorrect changed the typed MARK: `p2c-…` landed as `P2c-…` in TextEdit and Notes (TextEdit iCloud autosave files and the Notes title showed `P2c-59624-14`). Verifiers use AppleScript `contains`, which ignores case, so attribution to this run holds — but a STRICT exact-text check would pass only `finder.reveal`, and the ≥2 clause would NOT be met.
4. `calc.compute` = ok_no_cu: Calculator restored its last display (`4+7 = 11` from the previous run) on relaunch, and the agent reported success after only reading state. The actuation requirement caught it (no false ok). The pre-snapshot could not see it because Calculator was not running.
5. Side effects outside the sandbox: TextEdit autosaved 5 MARK documents into iCloud `com~apple~TextEdit/Documents` even with `close … saving no` (moved to iCloud Trash; each contained only a MARK); the Notes MARK note is in Notes' Recently Deleted.

Implementer recommendation: record **CONDITIONAL**. Conditions: (a) JevVoice's client owns the per-app approval policy (answers `mcpServer/elicitation/request`); (b) the product ships or requires `Codex Computer Use.app`; (c) background-session behaviour gets verified on jevbench. The mechanical rule says PROMOTE; the orchestrator/user decides at G7.

Surface: app-server only (`thread/start` -> `turn/start`). `codex exec` (discovery step 6) was not needed and not run — no exec-surface claim is made.

## Probe (protocol-derived)

- codex_bin: `"build/vendor/CodexRuntime/bin/codex"`
- version_output: `"codex-cli 0.160.0"`
- features: `["browser_use stable true", "computer_use stable true"]`
- login_status: `"Logged in using ChatGPT"`
- config_requirements_read: `{"requirements": null}`
- sol_family: `["gpt-6.1-sol", "gpt-6-sol", "gpt-5.6-sol"]`
- cu_host: `{"vendored_runtime_has_cu_host": false, "sky_client_path": "~/.codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient", "sky_client_present": true, "provenance": "installed by the ChatGPT/Codex desktop app under ~/.codex/computer-use (not part of the vendored CodexRuntime)"}`
- effective_config (fresh CODEX_HOME): `{"model": null, "model_reasoning_effort": null, "approval_policy": null, "approvals_reviewer": null, "sandbox_mode": null, "computer_use": null, "browser_use": null, "desktop": null, "auto_review": null, "apps": null, "default_permissions": null}`

`configRequirements/read` returned `requirements: null` VERBATIM — no ComputerUseRequirements are declared on this machine (no requirements.toml / MDM / cloud requirements). Declared requirements ≠ writable `Config.computer_use` (default_app_access + macos/windows tables only).

## Tool inventory per mechanism (zero-turn, `mcpServerStatus/list`)

- `bare` / server `codex_apps`: 698 tools, CU tools=[]
- `mcp_sky` / server `codex_apps`: 698 tools, CU tools=[]
- `mcp_sky` / server `computer-use`: 10 tools, CU tools=['click', 'drag', 'get_app_state', 'list_apps', 'perform_secondary_action', 'press_key', 'scroll', 'select_text', 'set_value', 'type_text']
  - Sky warm-up (`mcpServer/tool/call list_apps`, no model turn): ['ok 11082.4ms']

## Activation checkpoint

| mechanism | status | wall ms | CU calls ok/attempted | detail |
|---|---|---|---|---|
| bare | ok_no_cu | 11697 | 0/0 | no CU tool signature in item stream; agent: NO_COMPUTER_TOOL |
| mcp_sky | refused | 20687 | 0/1 | computer tool INVOKED but every call failed/denied: ["{\"content\": [{\"type\": \"text\", \"text\": \"Computer Use approval denied via MCP elicitation for app 'com.apple.finder'.\"… |

## Unattended-approvals matrix (task `textedit.type`)

Pinned base for every variant: `{"model": "gpt-6.1-sol", "model_reasoning_effort": "low", "sandbox_mode": "workspace-write", "cwd": "spikes/codex-cu/sandbox", "thread_start": {"ephemeral": true}, "answerer": "decline-all (no human); client_allowlist: accept elicitations naming corpus apps only", "task_timeout_s": 120.0, "interrupt_ack_s": 10.0, "stall_window_s": 40.0}`. Fresh CODEX_HOME per variant; mechanism `mcp_sky`.

| variant | config delta | status | asks | CU tools ok | zero-click | wall ms | tokens | detail |
|---|---|---|---|---|---|---|---|---|
| scoped | approval_policy=never + computer_use.default_app_access=deny + macos.bundle_ids{corpus app… | refused | 0 declined / 0 client-accepted | - | True | 13708 | 49573 | CU calls denied: [{"item_type": "mcpToolCall", "server": "computer-use", "tool": "get_app_state", "status": "failed", "id": "exec-a2e199e3-c395-45c0-8983-aab698… |
| scoped (scope: Dictionary) | approval_policy=never + computer_use.default_app_access=deny + macos.bundle_ids{corpus app… | refused | 0 declined / 0 client-accepted | - | True | 14925 | 80957 | scope held: successful CU calls targeting Dictionary: 0; CU errors=["{\"content\": [{\"type\": \"text\", \"text\": \"Computer Use approval denied via MCP elicit… |
| never | approval_policy=never + computer_use.default_app_access=allow | refused | 0 declined / 0 client-accepted | - | True | 22033 | 49973 | CU calls denied: [{"item_type": "mcpToolCall", "server": "computer-use", "tool": "get_app_state", "status": "failed", "id": "exec-e53f7a01-0d55-4d6c-b189-7dfe74… |
| auto_review | approvals_reviewer=auto_review | needs_human | 1 declined / 0 client-accepted | - | False | 19964 | 49946 | 1 approval request(s) declined (no human): ['mcpServer/elicitation/request'] |
| persistent | computer_use.allow_persistent_approval=true | blocked_env | 0 | - | - | 0 | - | allowPersistentApproval is NOT client-settable via config.toml: wrote computer_use.allow_persistent_approval=true, config/read computer_use readback={"default_a… |
| default | (none) | needs_human | 1 declined / 0 client-accepted | - | False | 29353 | 52001 | 1 approval request(s) declined (no human): ['mcpServer/elicitation/request'] |
| client_allowlist | (no config delta) client answers Sky's per-app elicitation: accept iff it names a corpus a… | ok | 0 declined / 1 client-accepted | get_app_state,press_key,type_text | True | 23158 | 152253 | TextEdit documents containing MARK: 1 via ax-fallback (apple-event: osascript timeout) |
| client_allowlist (scope: Dictionary) | (no config delta) client answers Sky's per-app elicitation: accept iff it names a corpus a… | refused | 1 declined / 0 client-accepted | - | False | 12824 | 83751 | scope held: successful CU calls targeting Dictionary: 0; CU errors=["{\"content\": [{\"type\": \"text\", \"text\": \"Computer Use approval denied via MCP elicit… |

### Approval events (raw, from the event stream)

- auto_review/textedit.type: `serverRequest/resolved` message=None meta=null -> answered null
- auto_review/textedit.type: `mcpServer/elicitation/request` message='Allow ChatGPT to use TextEdit?' meta={"persist": ["always"]} -> answered {"action": "decline"}
- default/textedit.type: `serverRequest/resolved` message=None meta=null -> answered null
- default/textedit.type: `mcpServer/elicitation/request` message='Allow ChatGPT to use TextEdit?' meta={"persist": ["always"]} -> answered {"action": "decline"}
- client_allowlist/textedit.type: `serverRequest/resolved` message=None meta=null -> answered null
- client_allowlist/textedit.type: `mcpServer/elicitation/request` message='Allow ChatGPT to use TextEdit?' meta={"persist": ["always"]} -> answered {"action": "accept", "content": {}}
- client_allowlist/scope.refuse: `mcpServer/elicitation/request` message='Allow ChatGPT to use Dictionary?' meta={"persist": ["always"]} -> answered {"action": "decline"}
- client_allowlist/calc.compute: `mcpServer/elicitation/request` message='Allow ChatGPT to use Calculator?' meta={"persist": ["always"]} -> answered {"action": "accept", "content": {}}
- client_allowlist/finder.reveal: `mcpServer/elicitation/request` message='Allow ChatGPT to use Finder?' meta={"persist": ["always"]} -> answered {"action": "accept", "content": {}}
- client_allowlist/notes.snippet: `mcpServer/elicitation/request` message='Allow ChatGPT to use Notes?' meta={"persist": ["always"]} -> answered {"action": "accept", "content": {}}
- CU tool errors under approval_policy=never (no request reached the client): ['{"content": [{"type": "text", "text": "Computer Use approval denied via MCP elicitation for app \'com.apple.Dictionary\'."}], "structuredContent": null, "_meta": …', '{"content": [{"type": "text", "text": "Computer Use approval denied via MCP elicitation for app \'com.apple.TextEdit\'."}], "structuredContent": null, "_meta": {"…']

## Canary corpus (variant `client_allowlist` — first variant with zero declined asks + >=1 successful CU call)

| task | MARK | status | CU tools ok | asks | wall ms | tokens | independent verify |
|---|---|---|---|---|---|---|---|
| calc.compute | p2c-59624-11 | ok_no_cu | get_app_state,list_apps | 0 declined / 1 client-accepted | 34200 | 70636 | AX static texts=['11'] expect 11 |
| textedit.type | p2c-59624-12 | ok | get_app_state,press_key,type_text | 0 declined / 1 client-accepted | 27628 | 185067 | TextEdit documents containing MARK: 1 via ax-fallback (apple-event: osascript timeout) |
| finder.reveal | p2c-59624-13 | ok | get_app_state,press_key | 0 declined / 1 client-accepted | 22131 | 196836 | front Finder target=/Users/karanvirkang/Documents/code/JarvisMacOSv1-empryo-staging-20260928/spikes/codex-cu/results want=/Users/karanvirkang/Documents/code/JarvisMacOSv1… |
| notes.snippet | p2c-59624-14 | ok | click,get_app_state | 0 declined / 1 client-accepted | 84572 | 179455 | notes containing MARK: 1 after Escape-unblock (AE stalled: osascript timeout)  |

## Measurements

- task rows: 4; ok (CU-proven + verified): 3; statuses: {'ok': 3, 'ok_no_cu': 1}
- wall ms over ok rows: p50 27628, max 84572
- total tokens over ok rows: p50 185067, max 196836
- token breakdown per ok row (input / cached input / output): ['textedit.type 184790/144000/277', 'finder.reveal 196653/158976/183', 'notes.snippet 179154/157056/301']
- `zero-click=True` on scoped/never rows means no ask reached a human; nothing actuated there (codex declined internally).
- TCC prompts observed: 0 rows; orphan check: leaked={}

## Background / multi-user session — labeled hypotheses

Labels: **[verified]** measured in this spike; **[documented]** read from codex's own schema/binary/plugin files; **[unverified]** hypothesis, no evidence either way.

- **[verified]** Everything above ran in the logged-in console session with the user's WindowServer; apps were driven while hidden/backgrounded (Sky's `get_app_state` launches/targets apps without bringing them frontmost).
- **[documented]** `allowLockedComputerUse` exists only in `ComputerUseRequirementsToml` (requirements layer: requirements.toml / MDM / cloud), next to `allowPersistentApproval`; `ComputerUseConfigToml` (user config) has 3 fields only. This machine declares `requirements: null`.
- **[unverified]** Whether `allowLockedComputerUse` lets the Sky host actuate while the screen is LOCKED or in a switched-out session. The Sky bundle ships `CUALockScreenGuardian.app` **[documented: file exists]**, suggesting a locked-screen code path; behaviour not tested.
- **[unverified]** Whether a fast-user-switched (non-console) session keeps a WindowServer the Sky host can actuate. Needs the `jevbench` user (`sudo scripts/bench/create-test-user.sh` — human step, not done).
- **[unverified]** Whether TCC grants (Accessibility / Screen Recording held by `Codex Computer Use.app`) carry to another user: TCC databases are per-user on macOS, so a background user would most likely need its own grants — hypothesis, not measured.
- **[verified]** The CU host is NOT in the vendored CodexRuntime: it is `~/.codex/computer-use/Codex Computer Use.app` installed by the ChatGPT desktop app. A jevbench user would also need that app installed + its per-app approvals.
- What a jevbench run would add: actuation in a switched-out session, per-user TCC behaviour, lock-screen behaviour with and without `allowLockedComputerUse` in a requirements.toml.

## Superseded runs (kept as evidence)

- `run-20261019-154247.rows.json` — run 1 (aborted by operator after TextEdit verifier bug -1700; runner ignored SIGINT as a background job, stopped via SIGTERM + manual app-server kill, no orphans left). Superseded by the next run in results.json. Rows: bare/activation.mouse=ok_no_cu, mcp_sky/activation.mouse=ok_no_cu, scoped/textedit.type=verify_blocked, scoped/scope.refuse=refused, never/textedit.type=verify_blocked
- `run-20261019-154822.rows.json` — run 2 (stopped by operator via SIGINT after corpus fell back to scoped). client_allowlist/textedit.type actually typed the MARK (5 CU calls incl. type_text; AX read later showed p2c-48355-9) but the AE verifier timed out: TextEdit main thread stuck in NSCorrectionPanel _interceptEvents (autocorrect bubble) -> verifier got AX fallback for run 3. Superseded by run 3. Rows: bare/activation.mouse=ok_no_cu, mcp_sky/activation.mouse=ok_no_cu, scoped/textedit.type=refused, scoped/scope.refuse=refused, never/textedit.type=refused, auto_review/textedit.type=needs_human, persistent/textedit.type=blocked_env, default/textedit.type=needs_human, client_allowlist/textedit.type=verify_blocked, client_allowlist/scope.refuse=refused, scoped/calc.compute=refused
- `run-20261019-155749.rows.json` — run 3 (stopped by operator via SIGINT — clean, no orphans). client_allowlist/textedit.type: Sky get_app_state -> server error -10005 timeoutReached x3 on a windowless TextEdit (0 documents after run-2 cleanup); a press_key error returned as plain text was miscounted as actuation (classifier fixed). Corpus fell back to scoped. Superseded by run 4. Rows: bare/activation.mouse=ok_no_cu, mcp_sky/activation.mouse=refused, scoped/textedit.type=refused, scoped/scope.refuse=refused, never/textedit.type=refused, auto_review/textedit.type=needs_human, persistent/textedit.type=blocked_env, default/textedit.type=needs_human, client_allowlist/textedit.type=refused, client_allowlist/scope.refuse=refused
- `run-20261019-160404.rows.json` — run 4 (complete, clean exit, 0 leaked). corpus under client_allowlist: textedit ok, finder ok; calc.compute: agent typed 4+7= and Sky AX showed 11 but the entire-contents verifier saw no AXStaticText (macOS 26 lazy SwiftUI tree) -> mis-classed driver_error; notes.snippet: note WAS created (count=1 after Escape-unblock) but AE verifier stalled behind the autocorrect NSCorrectionPanel -> verify_blocked. Verifiers fixed; superseded by run 5. Rows: bare/activation.mouse=ok_no_cu, mcp_sky/activation.mouse=refused, scoped/textedit.type=refused, scoped/scope.refuse=refused, never/textedit.type=refused, auto_review/textedit.type=needs_human, persistent/textedit.type=blocked_env, default/textedit.type=needs_human, client_allowlist/textedit.type=ok, client_allowlist/scope.refuse=refused, client_allowlist/calc.compute=driver_error, client_allowlist/textedit.type=ok, client_allowlist/finder.reveal=ok, client_allowlist/notes.snippet=verify_blocked

## Files / commands

- `appserver.py` — line-framed JSON-RPC client (no `jsonrpc` member), allowlist env, decline/allowlist answerers, bounded reads, group kill.
- `probe.py` (`--no-auth` = negative control, exits 2 with blocked_env) -> probe block.
- `run.py` — activation -> matrix -> corpus under `scripts/with-desktop-lock.py`; independent osascript/AX verifiers.
- `tasks.json` — corpus + verifier specs; `report.py` — this file; `results/run-*.log` — raw event streams.
