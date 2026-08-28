# Goal: ChatGPT / Codex GPT auth — ship the Codex-backend provider end to end

Status: research done (sources + our prior plan reviewed), implementation not
started. Supersedes the transport claims of `docs/codex_websocket_adapter.md`
(see "Correction vs the old plan" below).
Reference: <https://github.com/openai/codex> — the open-source OpenAI Codex
CLI; its Rust workspace lives under `codex-rs/`, and all file paths below
are relative to that directory. Research was done against the local
checkout of that repo at
`/Users/Uladzimir_Klyshevich/git/references/codex`.
Provider in fa: the `chatgpt` catalog entry (`kind: 'chatgpt-codex'`), OAuth
already built, **currently hidden** (`ProviderSpec.visible: false`) because
model requests 404.

**How to use this doc (for the implementing agent):** work through the
Implementation checklist top-down. Tick a box only when its tests are green
and the gates pass (analyze / coverage ≥ 90% new code / no crap4dart
regression / no duplication regression). Log every deviation in the
Implementation log at the bottom.

## TL;DR

- **Auth works already** (`lib/src/providers/chatgpt_oauth.dart`): PKCE
  against `https://auth.openai.com`, token exchange, refresh, account-id
  extraction. Verified against codex-rs — same client id, same issuer, same
  refresh grant.
- **The blocker is transport**: our plain HTTP POST to
  `https://chatgpt.com/backend-api/codex/responses` returns 404. codex-rs
  sources show the backend DOES serve HTTP SSE (`Accept:
  text/event-stream`) — but with a mandatory header set (originator,
  session-id/thread-id, x-client-request-id) and a **Cloudflare cookie
  store** on chatgpt.com hosts. Our request looked like a bare bot →
  challenge/404.
- Plan: fix the HTTP SSE transport first (headers + Cloudflare cookies),
  keep the WS v2 transport as an optional later phase, then unhide the
  provider.

## What we already have in fa

| Layer | File | State |
| --- | --- | --- |
| OAuth (PKCE, exchange, refresh, account id) | `lib/src/providers/chatgpt_oauth.dart` | Works; parity with codex-rs verified |
| OAuth callback server (CLI) | `lib/src/cli/chatgpt_oauth_server.dart`, `/provider chatgpt oauth` | Works |
| Streaming adapter (HTTP POST + Responses SSE parse) | `lib/src/providers/chatgpt_codex.dart` | Rejected by backend (404); `_SseAccumulator` already parses Responses event types |
| Catalog wiring | `lib/src/model_roles/provider_catalog.dart` (`chatgpt`, `api: 'responses'`) | Hidden: `visible: false` until the transport ships |
| Pickers / app preset | `packages/fa_ui/lib/src/providers/*` | Present; chat stream errors honestly today |
| Old transport plan (WS-first) | `docs/codex_websocket_adapter.md` | Kept as background; transport claims corrected below |

## Verified facts from codex-rs (file-referenced)

### Auth

- Client id: `app_EMoamEEZ73f0CkXaXp7hrann`
  (`login/src/auth/manager.rs:1618`; override env
  `CODEX_APP_SERVER_LOGIN_CLIENT_ID`). Our `chatgpt_oauth.dart` already uses
  this.
- Issuer `https://auth.openai.com`; OAuth PKCE callback server on
  `127.0.0.1:1455` (`login/src/server.rs: DEFAULT_PORT`).
- Refresh: `POST https://auth.openai.com/oauth/token` with
  `grant_type=refresh_token` (`login/src/auth/manager.rs:192,1507`).
  Our implementation matches.
- **ChatGPT device flow also exists** (`login/src/device_code_auth.rs`) —
  different from GitHub's: user code from
  `POST {auth_base}/api/accounts/deviceauth/usercode`, verification page
  `{base}/codex/device`, token via
  `{auth_base}/api/accounts/deviceauth/token`, callback
  `{base}/deviceauth/callback`. Useful for headless; optional for us.
- Request auth headers: `Authorization: Bearer <access_token>` +
  `ChatGPT-Account-ID: <account id>` (account id = `chatgpt_account_id`
  claim of the id_token JWT — already extracted by our OAuth layer).
- codex-rs persists tokens to `~/.codex/auth.json`; WE persist to the
  Keychain-backed secure store instead (project rule — see the copilot goal
  for the full keychain contract; same rules apply here).

### Transport — HTTP SSE (this is the fix we need)

`codex-api/src/endpoint/responses.rs` + `codex-api/src/requests/headers.rs`:

- `POST {chatgpt_base_url}/responses`
  (`https://chatgpt.com/backend-api/codex/responses`) with
  `Accept: text/event-stream`; telemetry even names the transport
  `responses_http`.
- Headers per request: `x-client-request-id` (= thread id), `session-id`,
  `thread-id`, optional `x-openai-subagent`; `originator: codex_cli_rs` is
  attached by codex-rs' default HTTP client layer.
- **Cloudflare cookie store** (`http-client/src/chatgpt_cloudflare_cookies.rs`):
  `Set-Cookie` responses on chatgpt.com hosts are captured and replayed on
  subsequent requests; only Cloudflare cookie names (`cf_*`) are allowed,
  other cookies are dropped. A client without this jar gets challenged —
  this is the most probable cause of our 404.
- Rate-limit snapshots are parsed from the response headers
  (`codex-api/src/rate_limits.rs`, `parse_all_rate_limits`).

### Transport — WebSocket v2 (secondary; the old plan's subject)

- `wss://chatgpt.com/backend-api/codex/responses` with mandatory header
  `OpenAI-Beta: responses_websockets=2026-02-06`
  (`core/src/client.rs: RESPONSES_WEBSOCKETS_V2_BETA_HEADER_VALUE`), plus
  `Authorization`, `ChatGPT-Account-ID`, `originator`,
  `x-client-request-id` per connect (see `docs/codex_websocket_adapter.md`
  §3.2 for the table).
- Protocol: client sends one `{"type":"response.create","body":{…}}` per
  turn; server streams typed events; connection cached across turns;
  prewarm is `response.create` with `generate=false`.
- `core/src/client.rs` keeps a `disable_websockets` flag and a
  **session-scoped HTTP fallback**: codex-rs itself treats HTTP SSE as a
  working path. That is the basis of this goal's "HTTP first" decision.

### SSE event vocabulary (`codex-api/src/sse/responses.rs`)

`response.created`, `response.output_item.added`,
`response.output_item.done`, `response.output_text.delta`,
`response.reasoning_text.delta`,
`response.reasoning_summary_text.delta`,
`response.reasoning_summary_text.done`,
`response.reasoning_summary_part.added`,
`response.custom_tool_call_input.delta`, `response.completed`,
`response.incomplete`, `response.failed`.

Our `_SseAccumulator` already handles the core subset (text deltas, tool
calls, lifecycle); missing: `output_item.added`,
`reasoning_summary_*`/`reasoning_text` (surfacing reasoning is optional),
`incomplete` (must be treated as an error-ish terminal state).

### Misc

- `GET {chatgpt_base_url}/models` — model listing for the Codex backend
  (seen in `response-debug-context/src/lib.rs`); feeds our `/models`
  dispatch instead of any hardcoded list.
- Base URLs seen: `https://chatgpt.com/backend-api/codex` (production) and
  `https://chatgpt-staging.com/backend-api/codex` (staging,
  `agent-identity/src/lib.rs`) — keep the base overridable.

## Correction vs the old plan (`docs/codex_websocket_adapter.md`)

The old plan assumed the Responses API is "WebSocket-only" and that plain
HTTP POST is rejected. The fresh source dive disproves that: codex-rs ships
the HTTP SSE path as a first-class transport (POST + `Accept:
text/event-stream` + `responses_http` telemetry + Cloudflare cookie store +
session-scoped WS fallback). The likely cause of our 404 is the missing
Cloudflare cookie handling and/or the missing codex header set, not the
missing WebSocket. Therefore: **HTTP SSE is Phase 1; WebSocket v2 is a later
optional phase.** If Phase 0 proves Cloudflare blocks non-browser HTTP
clients outright, fall back to the WS-first approach of the old doc — that
decision point is built into the checklist.

## Implementation checklist

Same discipline as `goal/copilot_provider.md`: TDD (red → green →
refactor), tick a box only with green tests and passing gates, log
deviations. No real network in unit tests (`http.testing.MockClient` only);
live checks are `integration`-tagged.

### ⚠️ crap4dart — pay attention

The pre-commit hook step 5 runs the CRAP ratchet (`dart pub global run
crap4dart analyze`, threshold in `crap4dart.yaml`). CRAP = complexity ×
coverage: the codex transport code (SSE event dispatch, cookie jar,
reconnect policy) is exactly the kind of code that blows the ratchet even
with green tests. Split it into small pure functions (event router, cookie
filter, header builder), test every branch, and run `dart pub global run
crap4dart analyze` locally BEFORE committing. Refactor for simplicity first;
never lower the threshold. Also remember: repo-root `dart analyze` currently
fails on pre-existing issues, so commits go through `--no-verify` — the hook
will not save you; keep your files analyze-clean yourself.

### Phase 0 — live recon (decision point: HTTP vs WS)

- [ ] Manual/integration smoke: `POST /responses` with the full codex-rs
  header set (originator, session-id, thread-id, x-client-request-id,
  Accept: text/event-stream, Authorization, ChatGPT-Account-ID) using a real
  OAuth token. *Record status + response headers verbatim in the
  Implementation log; never log token/cookie values.*
- [ ] If challenged (403/404 + `cf-mitigated`/HTML): capture which
  `Set-Cookie` headers arrive and confirm the `cf_*` replay hypothesis;
  prototype the cookie jar in a scratch script before wiring it into the
  adapter.
- [ ] If Cloudflare blocks non-browser HTTP outright → record the verdict
  and switch the plan to WS-first (`docs/codex_websocket_adapter.md`
  approach); re-baseline this checklist accordingly.
- [ ] `GET /models` smoke with the same headers (feeds Phase 2 wiring).
- [ ] Phase 0 verdict appended to the Implementation log (HTTP viable /
  WS required), with response evidence.

### Phase 1 — HTTP SSE transport fix (`lib/src/providers/chatgpt_codex.dart`)

- [ ] Header-parity layer: originator/session-id/thread-id/
  x-client-request-id/Accept builders as small pure functions + tests.
- [ ] Cloudflare cookie jar: capture `Set-Cookie` on chatgpt.com hosts,
  filter to allowed `cf_*` names, replay on subsequent requests; unit tests
  with fixture headers (allow/deny/name-scoping/path-scoping cases mirror
  `chatgpt_cloudflare_cookies.rs` tests). *Pure Dart; no `dart:cookie`
  magic — a tiny immutable jar keyed by host.*
- [ ] Wire the jar + headers into the streaming POST; retry once after a
  challenge-and-cookie-set round trip. *Nuance: only one auto-retry — a
  second challenge means failure with a human-readable message.*
- [ ] SSE event coverage: add the missing events to `_SseAccumulator`
  (`response.output_item.added`, `response.reasoning_summary_text.delta/
  .done`, `response.reasoning_summary_part.added`,
  `response.custom_tool_call_input.delta`, `response.incomplete` — the last
  one must terminate the turn with a clear error). Event-router split into a
  pure function for testability (and the CRAP ratchet).
- [ ] Rate-limit headers parsed into usage metadata (nice-to-have; keep
  behind a small parser with tests).
- [ ] Models: `GET /models` branch in the harness per-dialect dispatch
  (`_fetchProviderModelIds`), no hardcoded model lists.
- [ ] Error surface: 401 → refresh token → retry once (already exists in
  the OAuth layer — wire it into this adapter); Cloudflare challenge after
  retry → actionable error text.
- [ ] Gates: new-file coverage ≥ 90%, `dart analyze` clean, crap4dart no
  regression, still pure Dart (no `dart:io` imports in the provider — use
  injected transports).

### Phase 2 — auth polish + storage

- [ ] Refresh loop parity: proactive refresh before `expires_at` + 401 →
  refresh → single retry (mirror the codex-rs manager semantics; reuse the
  existing `ChatGptOAuthCredentials` persistence).
- [ ] Storage stays Keychain-only: credentials in the secure store
  (`SecureKeyStore` / app secure storage), never in config.yaml/JSONL/logs;
  add the token-leak assertion test (same pattern as the copilot checklist).
- [ ] Optional: ChatGPT device flow for headless setups
  (`/api/accounts/deviceauth/*` endpoints), behind the existing
  `/provider chatgpt` flow; integration-tagged only.
- [ ] Optional: staging base URL overridable via config
  (`chatgpt-staging.com/backend-api/codex`).

### Phase 3 — WebSocket v2 transport (optional, only if needed)

- [ ] Only if Phase 0/1 shows HTTP is unreliable, or product wants
  lower-latency reconnects: add `web_socket_channel`, `wss` connect with
  `OpenAI-Beta: responses_websockets=2026-02-06` and the §3.2 header set of
  the old doc.
- [ ] `response.create` envelope + event dispatch reusing the SAME SSE
  accumulator (the payload shapes match — keep one parser, two transports).
- [ ] Cached connection across turns + prewarm (`generate=false`) +
  session-scoped HTTP fallback semantics.
- [ ] WS tests: mock transport, event fixtures, reconnect-on-drop.

### Phase 4 — unhide + ship

- [ ] Flip `ProviderSpec.visible` to true for `chatgpt`; remove the
  404-honest-error branch if it became dead code.
- [ ] `/provider chatgpt` flow docs (`--help`, README, config examples);
  models list flows through `/models`.
- [ ] App: pickers already preset — verify the end-to-end chat in the app
  against a real account (integration tag).
- [ ] Final gates: full test suite, coverage ratchet, crap4dart, jscpd;
  CHANGELOG entry.
- [ ] Update this doc: tick boxes, fill the Implementation log.

## Acceptance (definition of done)

`fa --provider chatgpt "<prompt>"` streams a real response (HTTP SSE path),
`/models` lists Codex-backend models, a 401 mid-stream recovers via token
refresh, a Cloudflare challenge surfaces a clear error instead of a bare
404, the provider is visible in the CLI picker and the app, tokens live only
in the Keychain-backed store, and the checklist is fully ticked with the log
filled.

## Risks / open questions

1. **Cloudflare** may require a browser-grade challenge that a plain HTTP
   client cannot pass — the decision point of Phase 0. Fallback: WS-first
   (the old doc), which codex-rs also maintains.
2. **`x-oai-attestation`** — an integrity header built from device info in
   codex-rs; without it some accounts/features may be restricted. Defer;
   revisit only if the backend enforces it.
3. **Undocumented API / ToS** — the Codex backend is not a public API;
   behavior can change silently. Keep every endpoint/header overridable.
4. **Model access depends on the ChatGPT plan**; `/models` is the source of
   truth — never hardcode.
5. **crap4dart ratchet** on the event-routing code — see the checklist
   warning.
6. **Cookie-jar security** — replay only `cf_*` names on chatgpt.com hosts;
   never persist cookies to disk (in-memory per session only).

## Implementation log

(Newest first, one bullet per fact. Phase 0 evidence goes here — statuses,
which headers mattered, cookie names seen. No token/cookie values.)

- (empty — nothing implemented yet)
