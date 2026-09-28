# Architecture and source map

The package keeps two modules: `JevVoice` owns the macOS application and integration
side effects; `JevVoiceCore` holds shared values, interpretation and model clients.
Directory groups are navigation aids, not new packages or access-control boundaries.

`EyeTracking/` is a separate Electron/Python trial in this repository. It owns its
gaze overlay, calibration, tests, and model inputs. It is outside the two Swift
modules and the active first-release voice behavior in `voice-ui/SPEC.md`.

## Normal control flow

`main.swift` creates the menu-bar application, windows, microphone catalog and Fn
monitor. `VoiceController` owns capture/session state and defaults to
`SpeechAnalyzerCapture`. Speech events include revisions, finalization and timing.
`ContinuousIntentCoordinator` coordinates decisions over changing speech.
`CuaVoiceRuntime` owns task contexts and connects them to `CuaTaskAgent` and
`CuaWorkQueue`. `CuaConnection` transports MCP to the pinned local Driver.
Cua owns desktop observation, native actions and cursor feedback. Jev chooses
structured decisions; the optional text provider generates prose/advisory reasoning.

This describes wiring, not acceptance of every behavior. See
[the migration gates](voice-ui/PLAN.md) for remaining work.

## Source ownership

| Directory | Responsibility |
| --- | --- |
| `Sources/JevVoice/Voice` | Fn input, microphone routing, capture contracts, SpeechAnalyzer and interaction coordination |
| `Sources/JevVoice/UI` | Settings, capsule/Activity windows, styling and provider controls |
| `Sources/JevVoice/Settings` | Preferences, Keychain and permission/provider configuration |
| `Sources/JevVoice/ComputerControl` | Cua transport, dependency verification, observations, action catalog, task execution and scheduling |
| `Sources/JevVoice/Legacy` | Older recognizer/native executor and app discovery retained for regression comparisons and opt-in fixtures |
| `Sources/JevVoice/Testing` | Conditional `SPEECH_FIXTURE_PROBE` harness; not enabled in normal builds |
| `Sources/JevVoiceCore/Speech` | Transcript/range consumption and owned dictation values |
| `Sources/JevVoiceCore/Models` | JSON/typed Jev contracts and network clients for Jev and text generation |
| `Sources/JevVoiceCore/Commands` | Command values, matching, interpretation/planning and comparison-path coordination |
| `Tests/JevVoiceAppTests` | App integration contracts and explicitly gated live checks, grouped by responsibility |
| `Tests/JevVoiceTests` | Core logic/model tests, grouped by responsibility |
| `Tests/Fixtures` | Disposable external application fixtures |

Speech capture callbacks are session-bound; asynchronous task results must retain
their task and target ownership. The UI/controller uses the main actor; network,
Driver and audio work have their own existing lifecycles. Consult implementation
before changing isolation. No new global coordinator is implied by these groups.

## Legacy boundaries

Production defaults to Cua. Injected interpreter/executor seams still exercise
older behavior in regression tests; Driver failure does not select them as a
fallback. The old recognizer supports historical fixture/policy checks, while the
shared `SpeechCapturing` contract lives with current voice code. `ExecutorError`
remains a shared error type despite its historical name. Removing these paths
requires replacement evidence under the migration, not only an unused-code scan.

## Runtime and data boundaries

API keys use Keychain; app preferences use UserDefaults. The app verifies a pinned
Driver executable hash before connection. Cua schemas/observations, selected
application content and speech can be sent to model services by the task/intent
clients. The optional generation provider receives source content needed for its
request. Configuration is not permission to export credentials.

Perception models, installed helpers, recordings used as fixtures and historical
verification output are not Swift package resources. See [Cua provenance](../ThirdParty/Cua/README.md)
and [local storage](LOCAL-DEVELOPMENT-STORAGE.md) for their ownership and recovery.
