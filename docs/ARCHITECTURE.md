# Architecture and source map

The package keeps two modules: `JevVoice` owns the macOS application and integration
side effects; `JevVoiceCore` holds shared values and model clients.
Directory groups are navigation aids, not new packages or access-control boundaries.

`EyeTracking/` is a separate Electron/Python trial in this repository. It owns its
gaze overlay, calibration, tests, and model inputs. It is outside the two Swift
modules and the active first-release voice behavior in `voice-ui/SPEC.md`.

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

Conversational structure lives in `CuaDialogueState`, the single in-memory
authority the runtime consults and mutates: an `Intent` carries stable identity
across retries, corrections, clarification answers and new captures, while each
execution becomes an `Attempt` bound to that intent at a specific revision.
Decisions route into three shapes — add a new intent, resume an existing one
(answer binds the pending question and reopens the owner; retry starts a fresh
attempt on the same entry), or record a blocked refusal. Clarification questions
are revision-bound to their owner intent; verified facts carry
intent/attempt/revision provenance so prerequisites discharge only on observed
effects from the producing attempt. A resume reconstructs the original request,
scope, visibility and literal payload from the intent's stored contract, supplies
any answered text as `previous_context` to re-asked execution questions, and
rebinds targets from fresh observation rather than inheriting window IDs.
`VoiceController` projects presentation per capture session — active work,
pending questions and outcomes are scoped to the current hold, so a settled
failure cannot contaminate a new capture; Escape cancels only current-interaction
work while Stop All withdraws everything including question-only intents.
Dialogue state is bounded (unresolved cap, resolved-history trim that preserves
referenced intents transitively) and lives only in memory; nothing persists
across an app restart.

This describes wiring, not acceptance of every behavior. See
[the migration gates](voice-ui/PLAN.md) for remaining work.

The approved [execution simplification](EXECUTION-SIMPLIFICATION-PLAN.md) evaluates
which responsibilities the existing Cua/Jev integration can replace. The flow
above describes the current implementation, not a requirement to retain each
class or the present language/process boundary. Select that boundary from verified
contracts and total maintenance cost. The intended result has one desktop decision
and execution loop, Cua-owned supported observation/actions/verification, and only
the necessary Jarvis task/UI integration. No replacement is implemented or proven
by this architecture note.

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

The merged Cua executor retains the observed-action catalog, target and outcome
verification, timeout inspection, authorization, and guarded repetition from main.
The execution simplification candidate remains separately scoped and does not
close the migration's application acceptance gates. The standalone Cua agent keeps
a literal-payload utility for non-voice callers; production voice carries the
Jev-selected exact source span and does not run a preceding speech interpreter.

## Runtime and data boundaries

API keys use Keychain; app preferences use UserDefaults. The app verifies a pinned
Driver executable hash before connection. Cua schemas/observations, selected
application content and speech can be sent to model services by the task/intent
clients. The optional generation provider receives source content needed for its
request. Configuration is not permission to export credentials.

Perception models, installed helpers, recordings used as fixtures and historical
verification output are not Swift package resources. See [Cua provenance](../ThirdParty/Cua/README.md)
and [local storage](LOCAL-DEVELOPMENT-STORAGE.md) for their ownership and recovery.
