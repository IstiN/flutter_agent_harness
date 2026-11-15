# fa_network API — client-side test plan

Owner: flutter_agent (client: macOS app, Android/iOS, CLI). Counterpart:
`fa_network` (Go backend, `docs/openapi.yaml` = source of truth). Status:
draft v1, sent to the fa_network agent for review (2026-11-14).

Goal: every endpoint the app/CLI consumes is covered by executable
contract tests (positive + negative + security), and the Devices UX never
has to synthesize data the server could return.

## 1. Environments

| Env | Base URL | Purpose |
|-----|----------|---------|
| Mock | in-process `FakeHttpClient` / `MockClient` | unit: parsing, tolerant decode, error mapping |
| Dev/staging | TBD (requested from fa_network) | integration-tagged live contract tests |
| Prod | `https://<prod>` | smoke only (read-only, own test account) |

Rules: no real network in unit tests; live tests are `@Tags(['integration'])`,
excluded from pre-commit, run in CI against dev with a dedicated test
account + throwaway networks/devices (self-cleanup in `tearDown`).

## 2. Contract matrix (per endpoint)

Every endpoint gets the same five lanes:

1. **Shape** — response decodes into the client model; required fields
   present with documented types; ISO8601 timestamps; unknown extra fields
   ignored (version tolerance, both directions).
2. **AuthN/Z** — no token → 401; wrong-class token → 403; foreign
   tenant/account → 404 (not 200-empty, not 403-leaking existence where the
   contract says 404).
3. **Validation** — malformed body, oversize strings, bad enums → 4xx with
   the documented error schema (`code`, `message`), never a bare 500.
4. **Errors** — error payloads decode into the client's typed errors
   (`channel_read_only`, `enrollment_unsupported`, throttling, …);
   `Retry-After` parsed on 429.
5. **Side effects** — state actually changed (re-GET verifies), and the
   corresponding WS event fires exactly once (no duplicates on reconnect).

### Endpoint groups

- **Networks**: create/join (JWT + agent-class), mine/public/showcase,
  patch/delete, admins (guest-promotion rejected), members list/delete.
- **Channels**: list/create/patch/delete; public = read-only for
  non-admins (403 `channel_read_only` on send).
- **Messages** (until the DAP migration, §5): history pagination
  (`nextCursor` terminates, stable order, no dupes across pages), send,
  read cursor patch; opaque-envelope invariant (server stores ciphertext
  verbatim, never plaintext fields).
- **Agents/presence**: roster reflects only the enrolling network;
  offline drain on reconnect delivers missed envelopes once.
- **Devices** (in spec — confirmed by fa_network; `platform` + session
  `title`/`path`/`lastActivity` passthrough added + deployed in 014ca25):
  enroll (management JWT only; name ≤128 runes, platform ≤32, friendlyName
  ≤64 — 400 on overflow), account roster GET (account isolation!),
  roster PATCH merge semantics (40-session chunks compose; absent ids are
  NOT deleted — retraction is explicit `state:"offline"`/`exposed:false`;
  **rate limit 60 PATCH/min/device** — 1300 sessions = 33 patches fits),
  device rename (`friendlyName` round-trip), revocation (WS-kick +
  ticket-mint/redeem reject + token-hash filter), ws-ticket (single-use,
  60 s TTL, device scope, consumed even on failed upgrade).
  **Persistence contract**: name/platform/friendlyName/createdAt/revokedAt
  are server-persisted; machine presence (45 s grace), agents/sessions
  states + title/path/lastActivity are IN-MEMORY — the connector must
  republish after a server restart (heartbeat push; my client already
  publishes on every reconnect — pin this in a test).

## 3. Security negative suite

Mapped to fa_network `docs/security-review-2026-10.md` so fixes never
regress client-visibly:

- Session token bound to its network (cross-network use → 401/403).
- Cross-tenant agent drop/enroll/rotation → 404/409, no global tombstone.
- Roster/account isolation: two test accounts, A never sees B's devices,
  sessions, dmPubs, or presence frames (REST + WS).
- E2E opacity: send sealed envelopes; server responses/history/WS carry
  only ciphertext; no endpoint accepts or returns plaintext message bodies.
- Throttling: join-password, roster PATCH, ws-ticket minting, message send
  → 429 + `Retry-After`; limits shared REST/WS (`throttled` error frame).
- Input hardening: 1 MiB body cap → 413; friendlyName/name/platform caps
  in runes (name ≤128, friendlyName ≤64, platform ≤32). Control characters
  (Cc) and bidi overrides (U+202A-202E, U+2066-2069) in enroll
  name/platform, friendlyName, roster agent names, session title/path are
  **REJECTED with 400, not stripped** (8228191); WS-presence frames with
  invalid entries silently drop only the invalid entries (valid ones
  apply — noise discipline).
- Revocation: revoked device token cannot mint WS tickets, publish roster
  patches, or read the account roster.
- Webhook SSRF guard stays server-side (no client test; assert contract
  documents identity-only wake payloads).

## 4. Devices data-quality tests ("по красоте")

These pin the UX the user sees:

1. Enroll with `name`/`platform` → roster returns them verbatim (icons,
  titles); generic/empty names are the client's bug to avoid, not the
  server's to hide.
2. Session rows carry `title`/`path`/`lastActivity` when published;
  sleeping sessions are `wake_on_dm`, live ones `live`.
3. Agents carry `dmPub` even when asleep (wake-on-DM addressing) — until
  then the client publishes sleeping agents itself; either way the roster
  must round-trip them.
4. Rename propagates: PATCH `friendlyName` → other account devices see it
  in the next roster GET + a presence fanout frame to live sibling sockets
  (server-side since 8228191, tested there).
5. Large rosters: 1300 sessions in 40-chunks → GET returns the union,
  order stable, no chunk clobbering (merge-patch semantics).

## 5. DAP migration tests (user directive: chat sends via DAP)

**Decision (fa_network, 2026-11-14): native apps (macOS/Android) become
direct dap-clients to the hub** — same as the fa harness CLI: keys stay on
the client, user-class identity via ai-native JWT, offline delivery = hub
journal/ACK. FN keeps membership/roster/wake/devices; the hub is the
message bus. Browser (fa1.dev embed) keeps the FN session-WS relay.
Device-DM (`dm:` channels) is a separate track, unaffected.

Test lanes:

- Send via DAP lands in the same channel history browser clients read
  (interoperability with existing readers over the FN relay).
- E2E: sender-side sealing, recipient-side opening; hub/FN see only
  ciphertext (FN is not in the message path at all).
- Offline drain: hub journal/ACK delivers once, in order, after reconnect.
- Wake-on-DM: DM to a sleeping agent triggers its wake path (webhook /
  headless start) with identity-only payload.
- **History cutover is mandatory (fa_network review):** DAP-send writes
  history to the HUB journal; FN REST history reads FN PG. A flag period
  with two write paths yields TWO DISTINCT histories — browser readers on
  the FN relay will NOT see DAP messages. Acceptance is therefore NOT
  "indistinguishable rows during migration" but: **after the history-read
  cutover every reader (including the browser) sees the single hub
  journal.** Terminal state: the browser also reads history as a
  dap-client; FN relaying the hub journal is rejected (expensive bridge).
  Owner sign-off on this cutover is required BEFORE the feature-flag PR.

## 6. Execution

- `test/network/contract/` (new): one file per endpoint group,
  `FakeHttpClient` unit lanes + `@Tags(['integration'])` live lanes.
  **No dev/staging FN exists — prod only.** Destructive/isolation lanes
  run against a LOCAL stand: docker PG + `go run ./cmd/server` with the
  mock provider (`FA_NETWORK_MOCK_SECRET`, JWTs via `cmd/mintjwt` — see
  the fa_network repo). Prod (`https://fa-network-80693608388.us-central1.run.app`,
  live `/openapi.yaml`) gets read-only smoke with a disposable
  non-owner ai-native.cloud account. Revocation/throttle/foreign-404:
  local stand only.
- CI: new optional job `network-contract` (local stand service
  containers); failures file issues with the exact request/response
  (redacted) attached.
- OpenAPI drift check: CI parses the live/prod `openapi.yaml` and fails
  when a consumed endpoint/field is missing from the spec.

## 7. Resolved by fa_network (2026-11-14, commit 014ca25, deployed)

1. Devices endpoints are in the spec; `platform` + session metadata
   passthrough added (in-memory projection, republished on heartbeat).
2. Roster PATCH: 60/min/device; merge by id; explicit retraction only.
3. Server-persisted vs in-memory fields — see §2 Devices.
4. DAP: direct dap-client for native apps — see §5.
5. Local stand for destructive tests + prod read-only smoke — see §6.
   Test plan sent for review against the server code (negative cases).
