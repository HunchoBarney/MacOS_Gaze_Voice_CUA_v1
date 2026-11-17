"use strict";

// Host-liveness probe for the spawned-tracker watchdog. kill(pid, 0) is the
// POSIX existence check: ESRCH means the pid is gone, EPERM means it exists
// but belongs to another user — which still reads as ALIVE (a reused pid is
// the host's problem, not a reason to quit). Anything else also reads as
// gone — a kernel that can't answer the probe can't be trusted to have a
// live host.
function isProcessAlive(pid, killImpl = process.kill) {
  try {
    killImpl(pid, 0);
    return true;
  } catch (error) {
    if (error && error.code === "EPERM") {
      return true;
    }
    return false;
  }
}

// Poll the host pid every intervalMs; the moment it stops answering, invoke
// onGone once and stop polling. Returns the armed timer (unref'd so it can
// never hold the process open) or null when the pid isn't a positive
// integer — a standalone tracker run has no host and gets no watchdog.
// Timer/scheduler/kill are injectable so tests drive ticks and errors
// without real processes or real waiting.
function startHostWatchdog(pid, options = {}) {
  const {
    intervalMs = 2000,
    onGone,
    killImpl,
    setIntervalImpl = setInterval,
    clearIntervalImpl = clearInterval,
    log = console.log
  } = options;
  if (!Number.isInteger(pid) || pid <= 0) {
    return null;
  }
  // A cleared interval must never re-fire onGone — guard explicitly rather
  // than trusting every scheduler to honor the clear on an in-flight tick.
  let fired = false;
  const timer = setIntervalImpl(() => {
    if (fired || isProcessAlive(pid, killImpl)) {
      return;
    }
    fired = true;
    log(`host pid ${pid} is gone — tracker quitting`);
    clearIntervalImpl(timer);
    onGone?.();
  }, intervalMs);
  timer?.unref?.();
  return timer;
}

module.exports = { isProcessAlive, startHostWatchdog };
