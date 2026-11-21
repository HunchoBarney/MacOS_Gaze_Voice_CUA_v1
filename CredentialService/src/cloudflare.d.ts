// The few Workers runtime types this service uses, so the package needs no
// separate types package that conflicts with Node's globals in tests.
declare module "cloudflare:workers" {
  export abstract class DurableObject<Env = unknown> {
    protected ctx: DurableObjectState;
    protected env: Env;
    constructor(ctx: DurableObjectState, env: Env);
  }
}

interface DurableObjectState {
  storage: {
    sql: {
      exec(query: string, ...bindings: (string | number | null)[]): { toArray(): Record<string, unknown>[] };
    };
    get(key: string): Promise<unknown>;
    put(key: string, value: unknown): Promise<void>;
    deleteAll(): Promise<void>;
    setAlarm(scheduledTime: number): Promise<void>;
    deleteAlarm(): Promise<void>;
  };
}

interface DurableObjectNamespace {
  idFromName(name: string): unknown;
  get(id: unknown): unknown;
}

interface ExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
}

/** An outbound WebSocket from `fetch` with `Upgrade: websocket`. */
interface WorkerWebSocket {
  accept(): void;
  send(data: string): void;
  close(code?: number, reason?: string): void;
  addEventListener(type: "message", listener: (event: { data: unknown }) => void): void;
  addEventListener(type: "close" | "error", listener: () => void): void;
}

interface Response {
  readonly webSocket?: WorkerWebSocket | null;
}
