# Jarvis credential service

A Cloudflare Worker that holds the owner's OpenAI and TypeSafe keys so people
using Jarvis never see or paste one. Each install registers for an anonymous
token, kept in the Mac's Keychain. With it the app:

- mints a short-lived OpenAI Realtime client secret (`ek_…`, 60 s to start a
  session) and opens the voice socket to OpenAI with that;
- opens a GPT-Live WebRTC session: the app sends its SDP offer, the Worker
  creates the session with the owner's key and returns OpenAI's SDP answer;
- sends Terra requests to OpenAI's Responses API through the Worker;
- sends Jev requests to TypeSafe through the Worker.

Limits per install: requests per minute per route, and an estimated dollar
spend per UTC day. Across all installs there's a daily spend cap, a daily cap
on new installs (also per network), and a kill switch.

Built on [Hono](https://hono.dev) 4.13 (MIT) and a SQLite-backed Durable
Object (`LedgerObject`), which keeps every limit check and charge strongly
consistent. KV is eventually consistent, so it can't enforce a limit.

## Endpoints

| Method and path | Auth | What it does |
| --- | --- | --- |
| `POST /v1/installs` | none | Registers an install: `{ installID, token }` |
| `POST /v1/realtime/client_secret` | install token | `{ value, expiresAt, model }` |
| `POST /v1/live/sessions` | install token | GPT-Live WebRTC session: `{ sdp, instructions?, input?, voice?, idle_timeout_s?, vad_threshold? }` → OpenAI's 201 `{ session: { id }, transport: { type, sdp } }` unchanged. The Worker fixes the model, client delegation with no tools, `store: false`, the speech wake policy (`idle_timeout_s` defaults to 8), a hashed safety identifier and the data-channel client events (`LIVE_CLIENT_EVENTS`); any other field is `field_not_allowed`. A provider 400 passes through |
| `POST /v1/responses` | install token | Responses API, allowed models only, `store: false`, no tools or streaming |
| `POST /v1/jev` | install token | TypeSafe System One, allowed models only |
| `GET /admin/usage` | admin token | Today's spend, installs, top spenders |
| `POST /admin/pause`, `/admin/resume` | admin token | Kill switch for every install |
| `POST /admin/installs/:id/revoke`, `/restore` | admin token | Turn one install off or on |
| `GET /health` | none | `{ ok: true }` |

Errors are `{ "error": { "code", "message" } }`, with `Retry-After` on 429
and 503. Codes: `not_configured`, `paused`, `unknown_install`, `revoked`,
`rate_limited`, `daily_limit`, `service_daily_limit`, `registration_limited`,
`model_not_allowed`, `field_not_allowed`, `too_large`, `upstream_busy`,
`upstream_error`.

## Configuration

Secrets, set with `wrangler secret put NAME` or in the dashboard. Until all
three are set every request answers 503 `not_configured`.

- `OPENAI_API_KEY`, `TYPESAFE_API_KEY`
- `ADMIN_TOKEN`: a long random string for the admin endpoints

Variables (defaults in [src/config.ts](src/config.ts)):

| Name | Default | Meaning |
| --- | --- | --- |
| `PAUSED` | `0` | `1` refuses every `/v1` request |
| `INSTALL_DAILY_CENTS` | 100 | Estimated spend per install per UTC day ($1) |
| `GLOBAL_DAILY_CENTS` | 2000 | Estimated spend across all installs per day ($20) |
| `REALTIME_PER_MINUTE` / `LIVE_PER_MINUTE` / `RESPONSES_PER_MINUTE` / `JEV_PER_MINUTE` | 6 / 6 / 20 / 120 | Requests per install per minute |
| `REGISTRATIONS_PER_IP_PER_DAY` / `REGISTRATIONS_PER_DAY` | 5 / 500 | New installs |
| `REALTIME_SESSION_CENTS` | 5 | Charged per Realtime secret (the socket goes straight to OpenAI, so this is an estimate) |
| `LIVE_SESSION_CENTS` | 8 | Charged per GPT-Live session (an estimate: a 0.8-minute conversation plus the 90 s Standby tail, until metering replaces it) |
| `RESPONSES_RESERVE_CENTS` | 5 | Held against the budgets while a Responses call runs, then settled to its `usage` |
| `RESPONSES_INPUT_CENTS_PER_MTOK` / `RESPONSES_OUTPUT_CENTS_PER_MTOK` | 200 / 800 | Charged from each response's `usage` |
| `JEV_CALL_CENTS` | 0.5 | Charged per Jev call |
| `REALTIME_MODEL` | `gpt-realtime-2.1` | The only Realtime model a secret allows |
| `LIVE_MODEL` | `gpt-live-1.1` | The only GPT-Live model a session uses |
| `MAX_LIVE_BYTES` | 262144 | Largest Live session request (offer, instructions and history) |
| `RESPONSES_MODELS` / `JEV_MODELS` | `gpt-6.1-terra` / `jev-latest,jev-1.14.0` | Allowed models, comma-separated |
| `REALTIME_SECRET_SECONDS` | 60 | Secret lifetime, 10–600 |
| `MAX_OUTPUT_TOKENS` | 4000 | Cap on Responses output |

## Develop

```sh
corepack pnpm install
corepack pnpm test        # Vitest against Node's SQLite and a fake upstream
corepack pnpm typecheck
corepack pnpm smoke       # wrangler dev + Durable Object + fake upstream, no network
corepack pnpm dev         # wrangler dev; put fake keys in .dev.vars (git-ignored)
```

Deploying: see the owner's deploy guide (`handoffs/KAR-38-deploy.md` in the
Captain's drive).
