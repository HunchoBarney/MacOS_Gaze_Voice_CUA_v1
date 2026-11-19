import { describe, expect, it, vi } from "vitest";
import type { BackendMessage } from "../global";
import { RuntimeSources } from "./runtimeSource";

const point = (captured_at_ms: number): BackendMessage => ({
  type: "gaze", x_norm: 0.3, y_norm: 0.4, confidence: 1, distance_m: 0.6, captured_at_ms
});

describe("runtime publication ownership", () => {
  it("a new producer invalidates the old slice even before either runtime controller resolves", async () => {
    const sources = new RuntimeSources();
    const publish = vi.fn();
    let oldEmit!: (message: BackendMessage) => void;
    let newEmit!: (message: BackendMessage) => void;
    let finishOld!: (controller: { stop(): void }) => void;
    const old = sources.start(new AbortController().signal, publish, emit => {
      oldEmit = emit;
      return new Promise<{ stop(): void }>(resolve => { finishOld = resolve; });
    });
    oldEmit(point(100));
    const newer = sources.start(new AbortController().signal, publish, async emit => {
      newEmit = emit; return { stop: vi.fn() };
    });
    expect(publish.mock.lastCall?.[0]).toMatchObject({ away: true, held_reason: "source_stopped" });
    oldEmit(point(101));
    expect(publish).toHaveBeenCalledTimes(2);
    newEmit(point(102));
    finishOld({ stop: vi.fn() });
    (await old).stop();
    expect(publish.mock.lastCall?.[0]).toEqual(point(102));
    (await newer).stop();
    newEmit(point(103));
    expect(publish).toHaveBeenCalledTimes(4);
    expect(publish.mock.lastCall?.[0]).toMatchObject({ away: true });
  });

  it("cleanup while startup is pending revokes late messages without requiring another start", async () => {
    const signal = new AbortController(), publish = vi.fn(), sources = new RuntimeSources();
    let release!: () => void;
    const boot = sources.start(signal.signal, publish, async emit => {
      emit(point(10));
      await new Promise<void>(resolve => { release = resolve; });
      emit(point(11));
      return { stop: vi.fn() };
    });
    signal.abort();
    expect(publish.mock.lastCall?.[0]).toMatchObject({ away: true });
    release();
    (await boot).stop();
    expect(publish).toHaveBeenCalledTimes(2);
  });
});
