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

With `LIVE_METERING=1`, GPT-Live time is metered per install against a
monthly tier (the UTC calendar month). Each created session gets a
`LiveMeter` Durable Object, one per session id, that attaches to OpenAI's
sideband (`/v1/live/sessions/{id}/attach`) and reads the cumulative
`session.usage.updated` and `session.closed` usage. It keeps the largest
snapshot, so replays and out-of-order events never double-count, and charges
real cents to the daily spend as usage arrives instead of the flat
`LIVE_SESSION_CENTS`. A Standby second counts `STANDBY_WEIGHT` of a Live
second. Once an install is capped the current turn finishes: the meter sends
`session.close` at the next `session.paused` (at once if Live is already in
Standby), or after `CAP_GRACE_SECONDS` more session or clock time. New
sessions then get 429 `live_limit` and the app falls back to basic voice
until the month ends. A dropped sideband is reattached with backoff (1 s
doubling to 30 s, eight tries); if the session ended meanwhile, the time
from the last snapshot to the drop is billed at the active rate. With
metering off, Live behaves as before.

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
| `GET /v1/usage` | install token | Not charged: `{ metering, tier, period: "YYYY-MM", periodEnds, liveSeconds, liveSecondsLimit, warnAt, capped, tasksLimit }`. `liveSeconds` is weighted; `liveSecondsLimit` and `tasksLimit` are null when uncapped; `warnAt` is the fraction of the limit to warn at. With metering off, `liveSeconds` is 0, the limit null and `capped` false |
| `GET /admin/usage` | admin token | Today's spend, installs, top spenders |
| `POST /admin/pause`, `/admin/resume` | admin token | Kill switch for every install |
| `POST /admin/installs/:id/revoke`, `/restore` | admin token | Turn one install off or on |
| `POST /admin/installs/:id/tier` | admin token | `{ tier }`: put one install on a tier from `TIERS` |
| `GET /health` | none | `{ ok: true }` |

Errors are `{ "error": { "code", "message" } }`, with `Retry-After` on 429
and 503. Codes: `not_configured`, `paused`, `unknown_install`, `revoked`,
`rate_limited`, `daily_limit`, `service_daily_limit`, `registration_limited`,
`live_limit`, `unknown_tier`, `model_not_allowed`, `field_not_allowed`, `too_large`, `upstream_busy`,
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
| `GLOBAL_DAILY_CENTS` | 500 | Estimated spend across all installs per day ($5) |
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
| `LIVE_METERING` | `0` | `1` meters Live sessions and enforces the monthly tier cap |
| `TIERS` | `{"jarvis":{"liveMinutes":300,"tasks":100,"priceUSD":30},"pro":{"liveMinutes":1000,"tasks":400,"priceUSD":100}}` | Tiers as JSON; `tasks` is a whole number; `liveMinutes` or `tasks` null is uncapped |
| `DEFAULT_TIER` | `jarvis` | Tier for an install with none set |
| `STANDBY_WEIGHT` | 0.4 | Live seconds per Standby second, against the cap |
| `LIVE_WARN_FRACTION` | 0.8 | Reported as `warnAt` |
| `LIVE_ACTIVE_CENTS_PER_MINUTE` / `LIVE_PAUSED_CENTS_PER_MINUTE` | 5 / 2 | Metered Live cost, charged to the daily spend |
| `CAP_GRACE_SECONDS` | 60 | Longest a capped session runs on without a pause |

## Develop

```sh
corepack pnpm install
corepack pnpm test        # Vitest against Node's SQLite and a fake upstream
corepack pnpm typecheck
corepack pnpm smoke       # wrangler dev + Durable Object + fake upstream, no network
corepack pnpm dev         # wrangler dev; put fake keys in .dev.vars (git-ignored)
```

Deploying: see the owner's deploy guide (`handoffs/KAR-38-deploy.md` in the
Captain's drive). Deploying is a separate go from the Captain; merging this
code doesn't deploy it, and metering stays off until `LIVE_METERING=1`.
