// Runs the real Worker and its Durable Object under `wrangler dev` against a
// fake upstream on this machine. No request leaves the Mac and no key is real.
import { spawn } from "node:child_process";
import { mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import assert from "node:assert/strict";

const seen = [];
const upstream = createServer((request, response) => {
  request.resume();
  request.on("end", () => {
    seen.push({ url: request.url, authorization: request.headers.authorization });
    response.setHeader("content-type", "application/json");
    if (request.url === "/v1/realtime/client_secrets") {
      response.end(JSON.stringify({ value: "ek_smoke", expires_at: 1_900_000_000 }));
    } else if (request.url === "/v1/live/sessions") {
      response.statusCode = 201;
      response.end(JSON.stringify({ session: { id: "live_smoke" }, transport: { type: "webrtc", sdp: "v=0 answer" } }));
    } else if (request.url === "/v1/responses") {
      response.end(JSON.stringify({ output: [], usage: { input_tokens: 10, output_tokens: 10 } }));
    } else {
      response.end(JSON.stringify({ answers: {} }));
    }
  });
});
await new Promise((resolve) => upstream.listen(0, "127.0.0.1", resolve));
const upstreamURL = `http://127.0.0.1:${upstream.address().port}`;

const state = mkdtempSync(join(tmpdir(), "jarvis-credentials-smoke-"));
const servers = [];

async function boot(vars) {
  const port = 18000 + Math.floor(Math.random() * 1000);
  const wrangler = spawn("corepack", [
    "pnpm", "dlx", "wrangler@4.165.0", "dev", "--port", String(port), "--ip", "127.0.0.1",
    "--persist-to", state, ...Object.entries(vars).flatMap(([name, value]) => ["--var", `${name}:${value}`]),
  ], { stdio: ["ignore", "pipe", "pipe"], detached: true });
  servers.push(wrangler);
  let log = "";
  wrangler.stdout.on("data", (chunk) => (log += chunk));
  wrangler.stderr.on("data", (chunk) => (log += chunk));
  const base = `http://127.0.0.1:${port}`;
  const deadline = Date.now() + 120_000;
  for (;;) {
    if (Date.now() > deadline) throw new Error("wrangler dev did not start:\n" + log);
    try {
      await fetch(base + "/health");
      return { base, wrangler };
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 500));
  }
}

const client = (base) => async (path, { token, body, method = "POST" } = {}) => {
  const response = await fetch(base + path, {
    method,
    headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), "content-type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: response.status, json: await response.json() };
};

try {
  const unconfigured = await boot({});
  for (const path of ["/v1/installs", "/v1/realtime/client_secret", "/admin/usage"]) {
    const reply = await client(unconfigured.base)(path);
    assert.equal(reply.status, 503);
    assert.equal(reply.json.error.code, "not_configured");
  }
  process.kill(-unconfigured.wrangler.pid, "SIGTERM");

  const admin = "admin-smoke-fixture";
  const { base } = await boot({
    OPENAI_API_KEY: "sk-smoke-fixture",
    TYPESAFE_API_KEY: "ts-smoke-fixture",
    ADMIN_TOKEN: admin,
    OPENAI_BASE_URL: upstreamURL,
    TYPESAFE_URL: `${upstreamURL}/v1/systemone`,
    REALTIME_PER_MINUTE: "2",
  });
  const request = client(base);

  const install = await request("/v1/installs");
  assert.equal(install.status, 201);
  const { token, installID } = install.json;

  const secret = await request("/v1/realtime/client_secret", { token });
  assert.deepEqual(secret, { status: 200, json: { value: "ek_smoke", expiresAt: 1_900_000_000, model: "gpt-realtime-2.1" } });
  assert.equal((await request("/v1/realtime/client_secret", { token })).status, 200);
  assert.equal((await request("/v1/realtime/client_secret", { token })).json.error.code, "rate_limited");

  const live = await request("/v1/live/sessions", { token, body: { sdp: "v=0 offer" } });
  assert.deepEqual(live, { status: 201, json: { sessionID: "live_smoke", sdp: "v=0 answer", model: "gpt-live-1.1" } });

  assert.equal((await request("/v1/responses", { token, body: { model: "gpt-6.1-terra", input: [] } })).status, 200);
  assert.equal((await request("/v1/jev", { token, body: { model: "jev-1.14.0", state: {}, questions: {} } })).status, 200);
  assert.equal((await request("/v1/jev", { token: "jv1_" + "A".repeat(43), body: {} })).status, 401);

  const usage = await request("/admin/usage", { token: admin, method: "GET" });
  assert.equal(usage.json.installs, 1);
  assert.equal(usage.json.top[0].installID, installID);

  assert.equal((await request(`/admin/installs/${installID}/revoke`, { token: admin })).status, 200);
  assert.equal((await request("/v1/jev", { token, body: { model: "jev-1.14.0" } })).json.error.code, "revoked");
  assert.equal((await request("/admin/pause", { token: admin })).status, 200);
  assert.equal((await request("/v1/installs")).json.error.code, "paused");

  assert.deepEqual(seen.map((call) => call.url), [
    "/v1/realtime/client_secrets", "/v1/realtime/client_secrets", "/v1/live/sessions", "/v1/responses", "/v1/systemone",
  ]);
  assert.equal(seen[0].authorization, "Bearer sk-smoke-fixture");
  assert.equal(seen[2].authorization, "Bearer sk-smoke-fixture");
  assert.equal(seen[4].authorization, "Bearer ts-smoke-fixture");
  console.log("smoke passed: wrangler dev, Durable Object ledger, fake upstream, fails closed without secrets");
} finally {
  for (const server of servers) {
    try { process.kill(-server.pid, "SIGTERM"); } catch {}
  }
  upstream.close();
  rmSync(state, { recursive: true, force: true });
}
