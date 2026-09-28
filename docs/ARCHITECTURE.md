# Architecture and source map

The package keeps two modules: `JevVoice` owns the macOS application and integration
side effects; `JevVoiceCore` holds shared values and model clients.
Directory groups are navigation aids, not new packages or access-control boundaries.

## Normal control flow

`main.swift` creates the menu-bar application, windows, microphone catalog and Fn
monitor. `VoiceController` owns capture/session state and defaults to
`SpeechAnalyzerCapture`. Speech events include authoritative transcript snapshots, finalization and timing.
`MicrophoneInput` owns the long-lived engine on a serial queue. Its admission gate
drops idle buffers and strips any pre-hold prefix from a straddling buffer.
`SpeechAnalyzerCapture` owns a fresh prepared analyzer and bounded feed per hold;
it alone reconciles recognition ranges. Capture IDs, revisions, audio ranges and
finality pass through `ContinuousIntentCoordinator` in a transcript handoff, along
with the exact text and current task context. The coordinator owns speculative
handoff cancellation and consumed-span bookkeeping, not speech meaning. Fn release
closes admission and drains accepted audio, while the next analyzer prepares
independently of the still-running hardware.

For each pending source span, `CuaVoiceRuntime` starts a Cua session and sends the
original transcript and task context to `CuaTaskAgent.decide`, together with the
installed-app inventory. Jev makes the first operation, span, task relationship,
application and literal-payload decision there. The runtime creates task records
only after that decision and mechanically applies selected stop, stop-all or
correction mechanics. Selected execution continues through that same
`CuaTaskAgent`'s bounded observe/choose/act loop; later Jev calls use fresh Cua
observations inside that execution workflow. `CuaWorkQueue` owns app leases and
`CuaConnection` transports MCP to the pinned local Driver. Cua observations and
supported tools ground desktop targets and effects. The optional text provider
generates requested prose/advisory reasoning.

This describes wiring, not acceptance of every behavior. See
[the migration gates](voice-ui/PLAN.md) for remaining work.

## Source ownership

| Directory | Responsibility |
| --- | --- |
| `Sources/JevVoice/Voice` | Fn input, microphone routing, capture contracts, SpeechAnalyzer and interaction coordination |
| `Sources/JevVoice/UI` | Settings, capsule/Activity windows, styling and provider controls |
| `Sources/JevVoice/Settings` | Preferences, Keychain and permission/provider configuration |
| `Sources/JevVoice/ComputerControl` | Cua transport, dependency verification, observations, action catalog, task execution and scheduling |
| `Sources/JevVoiceCore/Speech` | Recognition ranges, consumed spans and capture provenance |
| `Sources/JevVoiceCore/Models` | JSON/typed Jev contracts and network clients for Jev and text generation |
| `Tests/JevVoiceAppTests` | App integration contracts and explicitly gated live checks, grouped by responsibility |
| `Tests/JevVoiceTests` | Core logic/model tests, grouped by responsibility |
| `Tests/Fixtures` | Disposable external application fixtures |

Speech capture callbacks are session-bound; asynchronous task results must retain
their task and target ownership. The UI/controller uses the main actor; network,
Driver and audio work have their own existing lifecycles. Consult implementation
before changing isolation. No new global coordinator is implied by these groups.

## Capture lifecycle

There is one production voice route: SpeechAnalyzer → transcript/revision transport →
the Cua task executor's first Jev decision → Cua observation and action. There is no
preceding speech interpreter, task-routing call or spoken-text extraction call.
Capture state and task progress have separate owners. Cancellation and session
identity reject late results; consumed-span tracking prevents replay while preserving
intentional repetitions. Manual mode still requires explicit submission. Legacy
recognizer, parser/planner, native executor, dictation helper and conditional probe
were removed under the authorized simplification plan. Live owned-range dictation
remains an open migration gate, not a replaced capability.

Ready hardware keeps the macOS microphone indicator active. Idle audio is discarded,
never retained or transcribed. Quit, sleep, session inactivity, permission loss and
input interruption stop hardware. Recovery prepares fresh input without resuming a
hold. Screen-lock notifications use loginwindow's installed notification names, an
undocumented OS integration that requires physical verification on supported builds.

## Runtime and data boundaries

API keys use Keychain; app preferences use UserDefaults. The app verifies a pinned
Driver executable hash before connection. Cua schemas/observations, selected
application content and speech can be sent to model services by the task/intent
clients. The optional generation provider receives source content needed for its
request. Configuration is not permission to export credentials.

Perception models, installed helpers, recordings used as fixtures and historical
verification output are not Swift package resources. See [Cua provenance](../ThirdParty/Cua/README.md)
and [local storage](LOCAL-DEVELOPMENT-STORAGE.md) for their ownership and recovery.
