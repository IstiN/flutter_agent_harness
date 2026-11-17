# fa_network Machine Connector — joint contract (issue #2062)

Contract freeze v1 for the first implementation pass. **Backend
(fa_network, Go) is implemented by the fa_network agent; the connector,
CLI and app surfaces by the flutter_agent_harness side.** Both sides
build against THIS document; deviations are bugs (update the doc and
both repos in the same change).

## 0. Decisions locked by the owner (2026-11-12)

1. **Scope:** ALL seven migration phases of issue #2062 in this card
   (connector core → client swap → exposure UI + roster API → remote
   viewer → mobile in-process → extension device → A2A stays at the
   edge, untouched).
2. **Auto-registration:** a signed-in user (ai-native JWT on
   network.fa1.dev) gets their agents network-visible **by default** —
   a per-agent "available in network" toggle (default **ON**) is added
   at agent creation and in settings. The user launches nothing:
   opening the network surface shows online/offline for their machines
   and agents. Exposure is opt-**out** inside the owner's personal
   network. (Amends the issue's "deny-by-default": that now applies to
   **shared** networks only.)
3. **DM E2E:** fanet1 reuse — see §7 (decided jointly: harness side +
   fa_network agent).
4. **Backend implementation** is delegated to the fa_network agent;
   harness side owns connector + CLI + app/web/extension UI.
5. **UI surfaces in this card:** app (Flutter desktop + mobile, and
   the web build fa1.dev/network — same codebase) and CLI. The CLI
   `/network` VIEW is optional; the hard requirement is CLI sessions
   being reachable from the apps (remote viewer + DM).

## 1. Identities and addressing

- `deviceId`: stable UUID minted at enroll, stored in the device key
  store (Keychain / keystore / chrome.storage / `~/.fah` on desktop
  dev).
- `deviceToken`: opaque bearer issued by the backend at enroll, bound
  to (userId, deviceId). Authenticates the device WS and
  device-scoped REST. Rotatable; revocation closes sockets and
  rejects tickets.
- Agent address: `<agentName>@<deviceId>` (e.g. `goal_builder@macbook`).
- User address: `user:<aiNativeUserId>` (today's member identity).
- Agents keep their existing fanet agent-class enrollment; the
  **connector enrolls/proxies agents on their behalf** — an agent
  never owns an upstream socket.

## 2. Personal (default) network

- The backend auto-provisions ONE personal network per ai-native user
  on first device enroll (or first JWT login to the network surface):
  `POST /api/devices/enroll` with a JWT and no personal network yet →
  creates it (owner = the user) and enrolls the device into it.
- Membership: the owner's devices + their clients (browser/mobile/app
  viewer sessions). Join-by-password semantics do not apply.
- Exposure defaults: agents ON, sessions ON (personal). Shared
  networks: sessions default OFF (§6).
- Shared-network join semantics (co-acked 2026-11-12): membership is
  USER-centric — join membership lives on the aiNativeUserId account
  (`joinAsAuthed` upserts `Member{UserID, NetworkID}`); every device
  of the user inherits it (`device.UserID → Member` lookup in device
  routing and roster). The password/invite is a FIRST-ADMISSION
  credential only: the network creator is a member at creation
  (`seedOwnerMember`) and is never asked for a password; an authed
  existing member joins by JWT alone (`joinNetwork` auth-first early
  exit — landed on the backend 2026-11-12: valid JWT + existing
  Member row → `joinAsAuthed` without reading the body; JWT without
  membership falls through to the password path as the first
  admission; guests and throttling unchanged). Re-entry is required only
  after an explicit kick (`DELETE /api/networks/{id}/members/
  {memberId}`), leave, or membership reset. Passwordless re-entry for
  JWT-less guests is OPEN DESIGN (per-device member token —
  undecided, not part of this contract).

## 3. Envelope v1 (one upstream WS per device)

One JSON frame per WS text message:

```json
{
  "v": 1,
  "kind": "hello | hello_ok | mail | presence | roster | ack | wake_hint | ping | pong | error",
  "msgId": "<uuid>",
  "refId": "<uuid>",
  "network": "<networkId>",
  "channel": "<channelId>",
  "from": "<agent@device | user:<id>>",
  "to": "<agent@device | user:<id>>",
  "ts": "<RFC3339 UTC>",
  "seq": 123,
  "ciphertext": "<fanet1 frame>"
}
```

Rules:

- `network` is absent on device-level frames (hello/presence of the
  machine itself); `channel` is required on `mail` (group channel id
  or `dm:...`); `to` is required for DM mail.
- The server routes by (network, channel, to), dedups by `msgId`
  (at-least-once upstream of the ack), preserves per-sender order and
  stamps `seq` on persisted mail. The server never reads ciphertext
  content or keys (**relay-only invariant**).
- **`msgId` IS the fanet1 frameId** for mail (§7): the HKDF salt, the
  AAD segment and the dedup key are ONE string. Redelivery must carry
  `msgId` byte-for-byte (any id rewrite breaks decryption — the AD
  binding tripwire); the connector never mints a new `msgId` when
  retrying from the outbox.
- One device socket MAY carry mail for every network the device is a
  member of and every exposed local agent — that is the whole point
  (AC1/AC2).
- `ack`: the connector acks inbound mail only AFTER the local mailbox
  write; unacked frames are redelivered on resume (no lost input).
- `refId` on ack/error references the delivered msgId; on
  hello_ok it references the hello.

## 4. Device WS protocol

- Ticket: `POST /api/ws-ticket` authenticated with the **deviceToken**
  (scope=device) → single-use ticket, TTL 60 s (existing wsticket
  machinery, device-scoped).
- Dial: `GET /ws?ticket=<...>` (existing endpoint; device ticket
  selects the device session path). On open the connector sends
  `hello` (deviceId + local roster digest) → server replies
  `hello_ok` + full `roster` snapshot for the device's networks, then
  incremental roster/presence frames.
- Reconnect: 1 s → 30 s backoff, resume by (deviceId, deviceToken);
  the server redelivers undelivered (unacked) mail in seq order after
  the roster snapshot (AC5). Redelivered/stored mail is forwarded
  VERBATIM — `from` stays the sender id the frame arrived with
  (`user:<uid>` since fa_network 2a5bf20; the codec also tolerates the
  documented bare-`<uid>` legacy rewrite). The client never rebuilds a
  stored envelope from the local agent registry: a `from` equal to the
  ADDRESSED agent makes the recipient's codec treat the DM as an
  own-reply echo (empty payload → ack/drop — incident 8ff48b96).
- `ping`/`pong` every ~20 s; server drops half-open connections.

## 5. Presence (three levels, independent TTLs)

- **Machine:** `online` (socket + heartbeats) / `degraded` (socket
  lost; local agents keep working; server infers it while the grace
  window runs) / `offline` (grace expired ~45 s; clean shutdown
  deregisters immediately).
- **Agent:** `live | busy | offline` — proxied by the connector from
  the local fabric registration state (`busy` = run in progress, mail
  still accepted). Agent presence rides inside the machine presence
  frame.
- **Session** (exposed ones): `live` (owner lease active) /
  `wake-on-DM` (exposed, no live lease) / `offline` (device offline).
  Lease state comes from the local attach/lease store (issue #428
  semantics).
- Heartbeat: a `presence` frame every 15–30 s and immediately on any
  state flip. Presence truth = **server receive time**, never client
  wall-clock claims (lease-store mtime lesson).

## 6. Exposure and ACL

- Exposure flags live **locally** (device registry): default ON for
  agents+sessions in the personal network (owner decision §0.2);
  shared networks default OFF for sessions. Toggles propagate in the
  next presence/roster frame (≤ one heartbeat).
- **Remote writers are always VIEWERS** (issue #428): inbound
  DM/channel mail addressed to an agent is written into the agent's
  mailbox as plain user text (existing `externalSteering` /
  `SessionInputChannel` semantics — zero agent-loop changes, AC4).
- The connector ACL rejects: slash-commands, `/approval`, `/config`,
  tool grants, takeover/admin payloads. **Content ACL lives entirely
  in the connector** (only it decrypts); server-side AC6 negatives
  are STRUCTURAL only: non-exposed `to`, non-member network, wrong
  ticket scope, DM routing to a foreign address (relay-only law).
- The session file is written only by the local owner (lease
  invariant).

## 7. DM E2E (fanet1 reuse — decided)

- DM channel id: `dm:user:<userId>:<agentName>@<deviceId>` (stable
  both directions).
- Keys: the agent (via the connector) holds ONE x25519 keypair per
  agent ADDRESS `agentName@deviceId` (`dmPriv`/`dmPub`), in the
  device key store — an agent lives on one device at a time; moving
  devices re-enrolls with a fresh `dmPub`, so roster readers key on
  the agent address, never the bare agent name. `dmPub` is published
  in the agent's roster entry. The user client uses its existing dap
  identity keypair. The envelope `msgId` doubles as the fanet1
  `frameId` (HKDF salt + AAD segment) — §3.
- Frames are **fanet1 exactly**: `senderX` = user identity pub;
  `shared` = ECDH(user_priv, dmPub) = ECDH(dmPriv, senderX)
  (symmetric); per-frame key = HKDF-SHA256(shared, frameId,
  info="dap1/v1"); AD `dap1|<frameId>|<dmChannelId>`;
  ChaCha20-Poly1305. Replies derive the same `shared` from the
  cached user pub (roster or first received frame).
- Server: DM is a **virtual channel** — no channel object with
  members; routing by `to`; persistence = inbox views for both
  parties (seq per DM pair, existing per-channel queue machinery
  reused per dm id); read cursors per user (existing cross-device
  semantics).
- DM history: windowed reads (existing `/api/inbox` views), never
  auto-relayed in bulk.
- **CLI inbound delivery (issue #2214):** the connector's ack-owning DM sink
  decrypts and ACL-sanitizes the complete payload before writing into the
  current session's real `<mailboxPrefix>/main` mailbox as `kind:user` mail.
  The existing inbox watcher / `externalSteeringSource` supplies idle wake and
  mid-run steering; no second agent invocation or wake loop is introduced.
  Mailbox ids combine zero-padded server `seq` (timestamp fallback) with the
  base64url `msgId`, so filename sorting preserves order and redelivery is
  idempotent across both pending `inbox/<id>.json` and consumed
  `read/<id>.json` records.
- **Ack vs. receipt:** the accepted order is completed current-mailbox write
  → encrypted `accepted, awaiting steering` receipt → original ack. A receipt
  send failure therefore leaves the original unacked for idempotent retry. A
  missing listener, stale local agent address, or non-current `sessionId` gets
  an encrypted `queued / not listening` reply and the original stays unacked
  so a later live session can receive it. Resume/wake for that later session
  remains issue #2213. Sink/mailbox/key-store failures are transient and stay
  unacked. Malformed fanet1, wrong-key, AAD, and authentication/tamper
  failures are permanent typed rejections: they are acked once to stop hostile
  redelivery, with a credential-free/plaintext-free notice. `dmMail` is a
  post-sink observation stream only; it is not an acknowledgement mechanism.
- **Own-echo belt (8ff48b96 follow-up):** a frame whose sender id equals
  the ADDRESSED agent (`from == to`, or `from` swapped into the agent
  address while `to` points back at the user) decodes to an empty
  payload — indistinguishable from the agent's own fanned-back replies.
  The connector classifies it by the only honest local signal, the frame
  id: an id this connector minted is a benign own-reply echo (quiet
  ack/drop); anything else is a malformed inbound with a REWRITTEN
  sender — still acked exactly once (the server caps redelivery at
  32/device, so refusing the ack would only loop), but never silently:
  a `::warning non-echo frame with rewritten sender` log line plus the
  AC6 rejection surface name it in the field. Echo classification is
  per-process: after a restart an old own echo re-classifies as
  non-echo (still acked; the warning is the honest signal).
- **Replies:** inbound steering includes `reply with agent_message to:
  "network-dm:v1:<base64url(route-json)>"`. The opaque route contains the
  network/channel, normalized sender address, sender x25519 public key,
  current agent address, and optional session/threading metadata. The CLI
  agent uses the existing `agent_message` tool with that exact address; its
  host gateway validates that the route belongs to the current CLI session,
  loads only an existing local DM key, and sends through `sendMail` with the
  freshly minted envelope `msgId` as the fanet1 `frameId`. Unknown, malformed,
  or wrong-session routes return an actionable error and are never silently
  dropped.

## 8. Wake paths

- **Desktop:** existing `mailboxWakeCommand` headless wake (identity-
  only webhook payload) — unchanged (AC10).
- **Mobile:** `wake_hint` frames + push subscriptions (APNs/FCM),
  identity-only payload; phase 5. Contract reserves the payload
  shape `{type: "push", platform, agentName}`.
- **Extension:** `wake_hint {type: "extension"}` — best-effort SW
  revive while the browser runs; browser closed = device offline,
  queue on server. Extensions never spawn processes.

### 8.1 Full session catalog and desktop wake-on-DM (#2213)

A device publishes its complete exposed local session listing, not only the
session with a live lease. Connect/enroll sends a full snapshot; store change
notifications trigger a debounced incremental patch (changed/new rows plus
retractions for removed rows). One roster patch contains at most 40 session
rows and larger stores are sent as ordered pages, so 1000+ session stores do
not create one unbounded frame. The listing itself remains backed by the
existing persisted listing index and bounded reads; no transcript records are
sent.

The roster session's existing `id`, `title`, `path`, and `lastActivity` fields
remain the interoperability baseline. `title` is the persisted session name,
or the bounded first-prompt snippet, or a cwd label as a final human fallback;
`path` is the existing connector cwd field and clients render its basename as
the cwd slug. `lastActivity` is RFC3339 UTC. Clients sort by `lastActivity`
descending (id tie-break). The connector also emits additive optional
`snippet` and `cwd` keys; roster servers MUST preserve unknown/additive
session metadata keys when merging patches so structured snippet/cwd survive
a round trip. Until then the baseline `title`/`path` mapping above is lossless
for display and requires no new endpoint. A missing/unknown id is never
invented into the catalog.

Rows render three states: `live` (current lease), `wake-on-DM` (catalog row
without a live lease on an online desktop), and `offline` (device offline).
A DM addressed to a wake-on-DM row launches the existing sender-driven
`mailboxWakeCommand` with explicit `--session <id>` and
`--inbox <target-mailbox>` arguments. The existing gh-1744 same-cwd guard and
gh-1180 wake receipts apply unchanged; the just-arrived DM stays unacked until
the woken target session consumes it through the #2214 mailbox path. The
current/live session never spawns a second agent and steers through its
existing mailbox. Mobile and extension devices stay queue-only and send the
honest encrypted queued/not-listening receipt rather than claiming a wake.

### 8.2 Interactive enrollment and roster hygiene (#2212)

The interactive TUI shares the headless `NetworkCommandRunner` contract:
`/network login` performs OAuth loopback (with `/network login --jwt [token]`
as the masked-paste fallback), `/network enroll [--name <name>]` prompts for a
friendly name with the local hostname as its blank-input default, and
`/network rename <name>` / `/network rename --clear` updates the enrolled
label. `/network status` and `/network devices [--roster]` inspect account,
device and live roster state. Bare `/network` and `/network join <invite>`
remain the DAP wizard; `/network dap …` is its explicit alias and
`/network help` disambiguates the two surfaces. Enrollment output points to
the app **Devices** surface: only live sessions are steerable directly, while
catalog sleepers are woken from their Devices row. The app asks the same
friendly-name question only when it has no stored device credentials; the
existing device-row rename dialog remains available on desktop and mobile.

Re-login/token refresh for the same account subject (or non-empty email
fallback) preserves the stored `deviceId`/`deviceToken`; only an actual
account switch clears the pairing. Enrolling with an existing stored device
identity is therefore a no-op and cannot manufacture same-host duplicate
rows. Revocation/account switching still requires a fresh enrollment.

Sub-agent transcripts are internal child state, never roster or DM targets.
CLI/app catalog projections exclude both children with a live parent and
orphaned/legacy children. Because roster PATCH is additive, they also publish
`{id, state: "offline", networks: []}` for known legacy child ids on a full
sync (and when a new child appears). Devices filters any legacy remote rows
marked `agent: "subagent"`, `subagent: true`, `parent`, or `parentId` before
folder grouping. A device with active sub-agents consequently renders exactly
one parent session row. Folder fallback must never turn an orphan into a DM
target.

The Devices UI applies a **30-day client display TTL** to offline session rows
whose `lastActivity`/`lastActiveAt` timestamp is older than the TTL. The same
rule applies to own persisted rows and remote rows; live/busy rows never age
out. Rows without a usable timestamp remain visible for legacy compatibility.
This is not server deletion.

**Required fa_network behavior (documentation-only here; no Go change in this
branch):**

1. Treat an offline + empty-`networks` session patch as an authoritative
   retraction/tombstone for that `(deviceId, sessionId)`, omit it from later
   roster snapshots, and do not let an older cached snapshot resurrect it.
2. Reap retracted rows promptly and persisted offline rows after the same
   30-day TTL (using server receive/update time, not an untrusted client
   timestamp). Device revocation must remove the device from account rosters.
3. Preserve additive roster agent shapes: `address` + `state` is sufficient
   when `exposed` is omitted; explicit `exposed: false` remains hidden. Do not
   report `agents=0` merely because no socket-local agent is present—the
   roster is the exposed catalog, not only the live registry.

## 9. Backend OpenAPI delta (fa_network)

New:
- `POST /api/devices/enroll` (JWT) → `{deviceId, deviceToken,
  personalNetwork}` (auto-provisions the personal network, §2).
- `DELETE /api/devices/{deviceId}` (revoke).
- `GET /api/networks/{id}/devices` (+ nested agents/sessions roster,
  exposed entries only).
- DM routing on `/ws` (`kind=mail`, `channel=dm:...`) + inbox DM
  views.
- `POST /api/ws-ticket` accepting deviceToken (scope=device).
- Roster patch: exposure flags + `dmPub` per agent (deviceToken or
  owner JWT).

Extended:
- presence model: device level (machine), agent live/busy proxy,
  session lease state.
- wake webhook payload: `type` hint (desktop | push | extension).

OpenAPI spec (`docs/openapi.yaml`) changes ride the same commit as
the code (fa_network law).

## 10. Harness deliverables (flutter_agent_harness)

- `lib/src/network/connector/`: envelope model, device registry +
  exposure flags, inbound ACL/sanitizer, envelope mux (`msgId` dedup,
  per-sender order), offline outbox (file-backed, injectable store),
  presence engine (injectable clock/timers), upstream WS client
  (injectable transport; reconnect/resume). **Pure Dart — no
  `dart:io`; native transport behind `lib/io.dart`.**
- Desktop daemon: existing loopback hub + upstream module; run modes:
  daemon (LaunchAgent / systemd user service / Windows logon task —
  never elevated), in-process (app/mobile), SW mini (extension).
  `fa connector run|install|status|remove`.
- Client swap: `SwappableMessagingRepository` primary = connector
  client (CLI + app), file fallback unchanged; legacy behavior
  byte-identical when unconfigured (AC14).
- UI: My Network **Devices** section (app + web), agent busy/idle
  badges, session exposure toggles (default ON personal), DM
  composer; CLI `/network status|devices|expose` (view optional).
- Remote viewer: app reads exposed sessions via `SessionEventSource`
  semantics and writes via `SessionInputChannel` semantics
  (server-relayed); leases untouched.

## 11. Acceptance mapping (AC1–AC14)

| AC | Verification |
|----|--------------|
| AC1 single upstream | fake-device-server connection count |
| AC2 envelope isolation/dedup/order | unit + fake server |
| AC3 exposure | fresh device in a SHARED network publishes zero sessions; personal default ON; disable unpublishes within one heartbeat (owner amendment §0.2) |
| AC4 zero-change inbound | integration over the real fabric |
| AC5 offline queue | fault injection (kill upstream, send, restore) |
| AC6 viewer-only writes | negative tests, both repos |
| AC7 presence TTLs | per-platform fakes + one manual pass per platform |
| AC8 extension device | extension host tests + e2e |
| AC9 mobile | integration; push optional, identity-only |
| AC10 wake paths | desktop headless wake receipt trail |
| AC11 relay-only | backend ciphertext-only tests + security note |
| AC12 Windows parity | same fake-server suite on Windows (CI runner or documented manual pass) |
| AC13 My Network UI | widget/golden tests + CLI output test |
| AC14 backward compat | existing fabric suite untouched and green |

## 12. Test seams

- Dart: `FakeDeviceServer` (in-memory WS server implementing §3–§5)
  — no real network in unit tests.
- Go: fake connector client over the same frames.
- Integration suites keep the `integration` tag convention.

## 13. Law compliance

Relay-only (no keys/plaintext server-side); no remote takeover/admin
or remote tool grants — ever; A2A untouched at the edge; pure-Dart
core (sockets only behind `lib/io.dart`); OpenAPI changes in the same
commit as code.
