import type { BackendMessage } from "../global";

type Publish = (payload: BackendMessage) => void;

export class RuntimeSources {
  private retire?: () => void;

  async start<T extends { stop(): void }>(signal: AbortSignal, publish: Publish, boot: (publish: Publish) => Promise<T>): Promise<T> {
    signal.throwIfAborted();
    this.retire?.();
    const retire = () => {
      if (this.retire !== retire) return;
      this.retire = undefined;
      signal.removeEventListener("abort", retire);
      publish({ type: "gaze", away: true, held_reason: "source_stopped", confidence: 0 });
    };
    this.retire = retire;
    signal.addEventListener("abort", retire, { once: true });
    try {
      const runtime = await boot(payload => {
        if (this.retire === retire) publish(payload);
      });
      return { ...runtime, stop() { retire(); runtime.stop(); } };
    } catch (error) {
      retire();
      throw error;
    }
  }
}
