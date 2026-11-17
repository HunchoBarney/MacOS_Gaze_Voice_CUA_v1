# D14 Source Gate

SOURCE_VERDICT: PASS.
PHASE_VERDICT: FAIL, expected. P4-5 and P4-6 remain false.

Independent reviewer74ea56f0 re-reviewed the approved two-file production
change and its affected consumers after all source findings were resolved.
No source-blocking findings remain. This is not signed-app qualification.

Production files: Sources/JevVoice/Driver/CuaConnection.swift and
Sources/JevVoice/Drive/DriveLoop.swift. Existing native-token TaskLoop
dispatch only; no preference in shared dispatch. Schema support, owned
session epoch, transport generation and cancellation are checked before
input. Motion configuration sends only session and glide_duration_ms=120.
Definite cosmetic refusal keeps legacy motion; uncertain outcomes do not
authorize input or replay. Captured-input capabilities use the same complete
generation-scoped schema cache. Disconnect and proxy start replace its owner.
Driver focus watch, fresh observation and completion thresholds are unchanged.

The reviewer checked the pinned 0.45.4 input/output contracts and macOS
post_action_wait None behavior. No driver, runtime or model policy changes.

Fail-first evidence under workspace recovery-20261110:
- native-d14-before-loop.log: one real-loop missing-preference failure.
- native-d14-required-schema-before.log: two malformed/unsupported required
  motion schema cases attempted configuration before the guard was fixed.
- native-d14-cache-lifecycle-before.log: disconnect retained the old cache
  owner before lifecycle replacement was added.
- native-d14-after.log: three stale happy-path fixtures failed six assertions
  at the unchanged pinned-app guard. User selected Fix Test Fixtures;
  only their application identity inputs change.

Final source checks through the serialized lane:
- native-d14-final-consumers.log: 387 selected checks, zero failures.
- native-d14-final-cancellation.log: one bounded cancellation check, zero
  failures, 0.161 seconds. The earlier 2385.370-second delay is unexplained,
  retained, and not claimed fixed.

No signed D14 goal, speed gain, installation or phase PASS is established.
