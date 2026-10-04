# TASKS.md — mini-Clicky build, lane ownership matrix

Single anti-conflict contract for the subagent build. Every lane works in its
own `git worktree` on its own branch, owns the files below EXCLUSIVELY, and
never touches another lane's files. Contracts live in
`Sources/JevVoice/Contracts/JevContracts.swift` — if a type needs changing,
report `CONTRACT-DEVIATION` instead of editing it.

Base: branch `mini-clicky` at the Wave-0 commit. Merge order + integration:
coordinator only. Reference docs: `/Users/karanvirkang/Code/Clicky_Decompile/mirror/`
(esp. `06-computer-use.md`, `05-agent-runtime.md`, `03-voice-realtime.md`).

## Wave 1 lanes (parallel, branch off mini-clicky base)

### L1 — Spine: drive-loop contract
- Owns: `Sources/JevVoice/ComputerControl/{CuaAgentLoop,CuaActionCatalog,CuaBrowserTarget,CuaVisionRegions,CuaStandingGrants}.swift`
- Forbidden: Voice/*, UI/*, Contracts/*, Makefile, every other file
- Deliver: loop consumes `DriveTask`, yields `DriveResult`/`DriveStatus`;
  `deny[]` enforced pre-offer AND post-answer; `values{label:text}` flow —
  Jev never writes text; `confidence<0.5` → `handedBack(lowConfidence)`;
  driver `effect`/`verified`/`escalation`/`suspected_noop` read and honored;
  `delivery_mode:"background"` on every input call; new lanes pixelClick /
  setValue / browserDialog / invokeMenu / launchApp(windows[]).
- Gate: `swift build` + focused `swift test` green; loop semantics preserved
  (existing tests may need updates to the new types — that's in-lane).

### L2 — Voice: TTS, dictation, latch
- Owns: `Sources/JevVoice/Voice/*.swift`,
  `Sources/JevVoice/Voice/SpeechOutput.swift` (new),
  `Sources/JevVoice/Voice/DictationDelivery.swift` (new),
  `Sources/JevVoice/Settings/Config.swift` (ONLY add: `ttsEnabled`,
  `latchMode`, `dictationHotkey` keys — do not touch other keys)
- Forbidden: ComputerControl/*, UI/*, Contracts/*, Makefile
- Deliver: `SpeechSynthesizing` impl (AVSpeechSynthesizer, speak/stop,
  voice-rate config); Fn+Ctrl dictation chord → `DictationDelivering`
  (element type_text → clipboard+paste fallback, restore prior clipboard);
  latch mode (tap Fn to start, tap to stop — FnInputState state machine);
  voice yes/no binding path surfacing `ConsentRequest` resolution intent.
- Gate: `swift build` + focused tests; dictation delivery verified with a
  mock target; no regression in `VoiceController` state machine tests.

### L3 — Driver embed + vendoring
- Owns: `Makefile`, `Sources/JevVoice/ComputerControl/CuaDependency.swift`,
  `Sources/JevVoice/ComputerControl/CuaConnection.swift`, `ThirdParty/Cua/*`
- Forbidden: all other Sources files, Voice/*, UI/*, Contracts/*
- Deliver: `make app` copies pinned `cua-driver` 0.32.0 into
  `Contents/Resources/` + SHA-256 verify vs `source-manifest.json`; runtime
  resolves bundle-embedded driver first, falls back to installed;
  `serve --embedded` spawn path (`CUA_DRIVER_EMBEDDED=1`,
  `--host-bundle-id com.chriswozniczek.jevvoice`, `--host-process-id $$`);
  vendor `@openai/codex` npm `darwin-arm64` binary into Resources the same
  way (hash-pinned); `CuaDaemonControl.swift` marked for deletion (leave file,
  coordinator deletes at integration — note in report).
- Gate: `make app` succeeds; embedded driver present in bundle;
  `codex` binary execs `--version` inside the bundle.

### L4 — Codex runtime (agent threads)
- Owns: `Sources/JevVoice/Agents/` (new dir):
  `CodexProtocolClient.swift`, `CodexRuntimeBridge.swift`, `AgentStore.swift`,
  `RoutineScheduler.swift`, `AgentWorkspace.swift`
- Forbidden: ComputerControl/*, Voice/*, UI/*, Contracts/*, Makefile
- Deliver: JSON-RPC stdio client for `codex app-server` (initialize →
  thread/new → turn/start → event stream); isolated `CODEX_HOME` per agent +
  `config.toml` writer (model_provider custom + `env_key`,
  `approval_policy="never"`, workspace-scoped sandbox, `mcp_servers` stubs for
  computer-use + jev-use loopback URLs); workspace scaffold
  (`output/`, `tmp/`, `AGENTS.md` with Standing-preferences + Notes template);
  `CompanionAgent` persistence (agents.json); `RoutineScheduler` (Timer-based
  re-injection while app runs); `<ROUTINE>` + `<COMPUTER_USE_REQUEST>` marker
  parse helpers.
- Probe FIRST: run `codex app-server` locally, dump the actual JSON-RPC
  handshake + thread/turn shapes (`codex app-server generate-json-schema` if
  it works) — code against observed wire format, not assumptions.
- Gate: spawn real codex app-server (user's `~/.local/bin/codex` fine for
  tests), thread+turn round-trip, events parsed; `swift build` green.
- Fallback if app-server drifts: `codex exec` non-interactive path — note
  whichever shipped in the report.

### L5 — MCP infra: loopback server + consent gate
- Owns: `Sources/JevVoice/MCP/` (new dir):
  `LoopbackMCPServer.swift`, `ComputerUseGate.swift`, `JevUseMCPServer.swift`
- Forbidden: all existing Sources files, Voice/*, UI/*, Makefile
- Deliver: localhost HTTP+token JSON-RPC MCP server (initialize, tools/list,
  tools/call); `ComputerUseGate` — proxies to driver, refuses
  `ConsentContract.inputTools` pre-consent (`blocked_by_consent` error),
  injects `delivery_mode:"background"`, refuses `scope:"desktop"`, consent
  keyed per (agent, turn) via `ConsentGating`; `JevUseMCPServer` —
  `drive_until`/`suggest_action` schemas exposed; drive_until calls a
  `DriveExecutor` protocol seam (stub impl OK — L1 provides the real one at
  integration): `protocol DriveExecuting { func drive(_ t: DriveTask) async
  throws -> DriveResult }`.
- Gate: loopback MCP round-trip vs a JSON-RPC test client; gate unit tests:
  input refused pre-consent, permitted post-consent, deny list enforced,
  desktop scope refused. `swift build` green.

## Wave 2 lanes (spawned by coordinator after L1+L5 merge)

### L6 — CompanionBrain + decide() excision
- Owns: `Sources/JevVoice/Companion/` (new): `CompanionBrain.swift`;
  `Sources/JevVoice/ComputerControl/{CuaTaskAgent,CuaVoiceRuntime,CuaDialogueState}.swift`;
  `Sources/JevVoiceCore/Models/{TextGenerationClient,JevClient}.swift`
- Deliver: `CompanionPlanning` impl (OpenAI-compatible chat + JSON decision);
  `decide()` battery deleted; `CuaDialogueState` slimmed (intents/answers/
  outcomes only); JevClient 20s timeout; degrade path (no key → fast lanes +
  honest message).

### L7 — Consent plumbing end-to-end
- Owns: consent wiring across runtime/UI/Voice (assigned at spawn)
- Deliver: `COMPUTER_USE_REQUEST` → `ConsentRequest` → card + spoken ask →
  voice yes/no + buttons → gate approve → next turn prefix.

### L8 — Agents UI
- Owns: `Sources/JevVoice/UI/AgentsView.swift` (new), `ContentView.swift`
  (agents section only), `VoiceWindows.swift` (nav), cursor label overlay
- Deliver: roster + chat + output preview + consent cards + per-agent
  `AgentCursor` labels.

## Report format (required from every lane)

```
LANE: <id>  STATUS: done|blocked
WORKTREE: <path>  BRANCH: <name>
FILES: <changed list>
TESTS: <commands + results>
CONTRACT-DEVIATIONS: none | <list>
KNOWN-ISSUES: <honest list>
```

## Rules for every lane

- Never stash/reset/clean; the folder is shared.
- Commit only on your lane branch; never push; never merge.
- `swift build` + focused `swift test` must pass in YOUR worktree before reporting done.
- Physical/daemon-touching checks: report as "unverified — needs coordinator".
- Match existing code style; no new dependencies; no comments unless needed.
