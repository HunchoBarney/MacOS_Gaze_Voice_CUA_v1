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
  };
}

interface DurableObjectNamespace {
  idFromName(name: string): unknown;
  get(id: unknown): unknown;
}
