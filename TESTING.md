# Testing on the owner's Mac

The crew shares one 8 GB M1, so one heavy build runs at a time. A single
`make test` takes about 40–50 s warm. Most of the time a PR waits is queueing
for the lane and cold builds in fresh worktrees: 56 s on a quiet Mac, up to
190 s under load.

## While iterating

Run focused suites, not the full suite:

```sh
scripts/lane-test.sh swift test --filter FastLaneTests
```

## Once per final head

Run one full `make test` before asking for review:

```sh
scripts/lane-test.sh
```

Local CI runs it again at every PR head and on main, and posts the
`local-ci` commit status.

## The build lane

`scripts/lane-test.sh` keeps one long-lived checkout at
`~/.capy/work/build-lane/checkout` that every crew thread reuses:

1. It takes the lane lock (`~/.capy/work/build-lane/lock`), then waits until
   `pgrep -x 'swift-build|swift-test|swift-frontend|xcodebuild'` is empty.
   Both waits time out after an hour.
2. It mirrors your worktree into the lane checkout by content, committed or
   not, leaving out `.git`, `.build`, `build` and `node_modules`.
   Unchanged files keep their timestamps, so the next build only recompiles
   what differs from the last head the lane built.
3. It runs your command there and releases the lock.

When the crew's shared queue `~/.capy/work/lane/lane.sh` is installed,
`lane-test.sh` hands over to it. It works the same way, but waiters run in
the order they arrived instead of whichever polls first, and
`LANE_PRIORITY=high` (main-blocking jobs) goes to the front. Local CI
doesn't use the queue or the lane lock: it only waits for that `pgrep -x`
to come back empty.
`~/.capy/work/lane/lane.sh --status` shows the running job, how long it has
run, and the queue in order.

The installed queue is a copy of `scripts/lane.sh`. After changing it, run
`scripts/test-lane.sh` (fake commands, no Swift) and install it with
`install -m 755 scripts/lane.sh ~/.capy/work/lane/lane.sh.new && mv ~/.capy/work/lane/lane.sh.new ~/.capy/work/lane/lane.sh`.
Never edit the installed file in place. Each job also runs from its own
private copy, so a deploy can't change a waiting job. A job that holds the
lock keeps it until it has run, even when a high-priority ticket arrives
while it waits for another build, and stopping the queue stops every process
the job started.

Don't build in your own worktree as well: that adds a second cold `.build`
(400 MB–1.4 GB) and holds the lane for minutes. Local CI keeps its own
checkout under `~/.capy/work/local-ci`. Never point either at the owner's
checkout.

## Keeping tests parallel-safe

`make test` runs `swift test --parallel`: every XCTest case runs in its own
process, one per core, while other worktrees may be testing on the same Mac.
A test must not depend on, or write to, state those processes share:

- `UserDefaults.standard`: inject a `UserDefaults(suiteName:)` suite. For
  standing grants, call `usePrivateStandingGrants()`; for the eye-tracking
  switch, call `useGazeTrackingOn()` or set `DriveLoop.gazeEnabled`.
- Fixed ports and paths: bind port 0, and use a fresh temporary directory.
- Fakes behind the driver seam: serialise `call` with a lock, because the
  executor makes concurrent driver calls.

## What only the owner can check

Simulated and recorded tests never prove room acoustics, the wake word,
full duplex, gaze or packaged-app behaviour. These are owner physical
checks on a named signed build, run through `scripts/with-desktop-lock.py`
when they drive the desktop, and reported separately from test results.
Each passes only when the visible result below happens:

- Wake: "Hey Jarvis" said in a normal room wakes it and the glow changes.
- Standby: after a short silence the glow shows Standby; speaking again
  without the name resumes; 90 s after the last turn it is Asleep.
- "That's all" goes to Asleep at once; "stay with me" stays open.
- Talking over Jarvis stops its speech, and a request said once is
  carried out once.
- Another person or a TV speaking after a Standby resume never sends,
  deletes, buys or posts without a short question first.
- With eye tracking on, "click this" acts on the element you look at.
