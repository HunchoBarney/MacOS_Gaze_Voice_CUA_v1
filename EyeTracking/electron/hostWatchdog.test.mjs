import { spawn } from "node:child_process";
import { describe, expect, it } from "vitest";

const { isProcessAlive, startHostWatchdog } = require("./hostWatchdog.cjs");

describe("isProcessAlive", () => {
  it("reads a live process as alive", () => {
    const sleeper = spawn("sleep", ["30"]);
    try {
      expect(isProcessAlive(sleeper.pid)).toBe(true);
    } finally {
      sleeper.kill("SIGKILL");
    }
  });

  it("reads a reaped process as gone (ESRCH)", async () => {
    const exited = spawn("true");
    await new Promise((resolve) => exited.once("exit", resolve));
    // The pid is ours until the child is reaped — use a guaranteed-dead
    // synthetic pid instead of racing the reaper.
    const deadPid = 0x7fffffff;
    expect(isProcessAlive(deadPid)).toBe(false);
  });

  it("reads EPERM as alive — a foreign-owned pid is still a pid", () => {
    const killImpl = () => {
      const error = new Error("kill EPERM");
      error.code = "EPERM";
      throw error;
    };
    expect(isProcessAlive(1, killImpl)).toBe(true);
  });

  it("reads ESRCH as gone via the injected kill", () => {
    const killImpl = () => {
      const error = new Error("kill ESRCH");
      error.code = "ESRCH";
      throw error;
    };
    expect(isProcessAlive(12345, killImpl)).toBe(false);
  });

  it("reads an unexpected kill error as gone — a probe that cannot run cannot vouch for the host", () => {
    const killImpl = () => {
      throw new Error("something else entirely");
    };
    expect(isProcessAlive(1, killImpl)).toBe(false);
  });
});

describe("startHostWatchdog", () => {
  it("arms nothing for a missing or invalid host pid", () => {
    const never = () => {
      throw new Error("setInterval must not be called");
    };
    for (const pid of [0, -1, NaN, 1.5, undefined]) {
      expect(startHostWatchdog(pid, { setIntervalImpl: never })).toBeNull();
    }
  });

  it("fires onGone once and stops polling when the host dies", () => {
    let tick;
    const timers = [];
    const fakeSetInterval = (fn) => {
      tick = fn;
      const timer = { unref() {} };
      timers.push(timer);
      return timer;
    };
    const cleared = [];
    const gone = [];
    const killImpl = (pid) => {
      const error = new Error("kill ESRCH");
      error.code = "ESRCH";
      throw error;
    };
    const timer = startHostWatchdog(4242, {
      setIntervalImpl: fakeSetInterval,
      clearIntervalImpl: (t) => cleared.push(t),
      killImpl,
      onGone: () => gone.push(true),
      log: () => {}
    });
    expect(timer).not.toBeNull();
    tick();
    expect(gone).toHaveLength(1);
    expect(cleared).toHaveLength(1);
    expect(cleared[0]).toBe(timer);
    // A second tick (should be impossible post-clear, but must stay inert
    // if a racy scheduler delivers one) must not re-fire onGone.
    tick();
    expect(gone).toHaveLength(1);
  });

  it("keeps polling while the host answers", () => {
    let tick;
    const gone = [];
    startHostWatchdog(process.pid, {
      setIntervalImpl: (fn) => {
        tick = fn;
        return { unref() {} };
      },
      clearIntervalImpl: () => {},
      onGone: () => gone.push(true),
      log: () => {}
    });
    tick();
    tick();
    expect(gone).toHaveLength(0);
  });
});
