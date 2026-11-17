# G3 discovered consumers and tracker lock convergence

Pending G2 scope extension; do not edit these additional paths before review:

```
Tests/JevVoiceAppTests/DriveSessionCursorTests.swift
Tests/JevVoiceAppTests/GazeLaneTests.swift
Tests/JevVoiceAppTests/GazeRefusalStateTests.swift
Sources/JevVoice/Gaze/TrackerHost.swift
Tests/JevVoiceAppTests/TrackerHostLockTests.swift
```

Full release G3 compiled and ran1468 tests,25skips,10 failed assertions.
All new native/local/default/pause tests passed. Retain c1-r8-all.json/log and
source freeze c1-r8-source-1. No R8 G4/candidate/live acceptance.

Four legacy tests (6assertions) expect a driver scroll despite no native viewport:
DriveSessionCursorTests42,71, GazeLaneTests234-235, GazeRefusalStateTests361-362.
The latter two will require no scroll or key input with their existing missing
viewport; retain their honest refusal/window/gaze feedback assertions.
Session-label tests should exercise a complete explicit keypress instead, so
they still prove direct/caller labels with a real fake-driver dispatch and are
independent of the deliberately removed unbound scroll path. Keep labels and
one-dispatch assertion. Do not lower production checks.

TrackerHostLockTests failed again independently against the same binary
(c1-r8-tracker-recheck.json/log). TrackerHost.swift is unchanged from the baseline.
Its .running transition schedules applyLockParking (50), while a lock edge calls
it directly (683). Both actor invocations can suspend in status() before either
claims pausedByLock, then send duplicate pause POSTs (700-720). Existing tests
observe these duplicates; do not weaken their exact counts.

Proposed repair: one actor-owned lock-parking operation. Overlapping requests
mark pending and return; the existing convergence loop consumes the latest lock
state after each await. An overlapping state edge must still run after a failed
operation, without an unconditional retry loop. Invalidate a private parking
identity when leaving .running; check it and .running again after status() and
the pause POST so an old responder cannot claim a new tracker's pause. Preserve
manual-pause ownership and current lock/unlock convergence.

Before production changes, add a gated respawn-during-pause regression in the
existing TrackerHostLockTests, using separate old/new transports, plus retain
the existing duplicate/lock-race controls. No audio/model mocks or new test file.
No EyeTracking edits, protocol/schema changes, public API, model/provider pins,
native permissions, broad lifecycle refactor or daily replacement.

Review criteria: CON-1 legacy tests still exercise their intended authority or
session-label contract; CON-2 duplicate parking and latest-state/error handling
are addressed without blocking an edge callback on in-flight IO; CON-3 a retired
tracker cannot leave a new one falsely claimed; CON-4 scope/verification is narrow.
