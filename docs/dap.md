# DAP/1 — the agent messaging hub protocol

How `fah` agents talk to each other through a hub: the wire format, the
signing and end-to-end encryption scheme, the channel/invite/presence
model, how to run a hub, and an end-to-end setup walkthrough.

Everything here is reconstructed from the code that speaks the protocol —
the vendored client at `vendor/fah_hub_client/` (checksum-pinned by its
`MANIFEST.txt`) and the bin-side plugin adapter. Citations name the file
and symbol, so a compatible hub or a client audit can check each claim
against the source. The client's doc comments cite an upstream
`docs/protocol.md`; this document is the in-repo equivalent.

Code map:

| Concern | File |
|---|---|
| Connection, hello/welcome, sends, whois, reconnect | `vendor/fah_hub_client/lib/src/hub/hub_client.dart` (`HubClient`) |
| Frame signing, canonical JSON, frame ids | `vendor/fah_hub_client/lib/src/hub/canonical.dart` |
| Identity keys and the key file | `vendor/fah_hub_client/lib/src/hub/identity.dart` (`HubIdentity`) |
| Payload encryption (E2E) | `vendor/fah_hub_client/lib/src/hub/payload_crypto.dart` |
| Channel keypairs and the shared channels file | `vendor/fah_hub_client/lib/src/hub/channels.dart` (`ChannelStore`) |
| Config files, env vars, `~/.dap` layout | `vendor/fah_hub_client/lib/src/hub/dap_settings.dart`, `hub_config.dart` |
| Plugin wiring, inbox drain, invites host-side | `vendor/fah_hub_client/lib/src/hub/hub_plugin.dart` (`HubPlugin`) |
| CLI adapter: `/dap`, `dap_*` tools | `bin/fah_hub_plugin.dart` (`HubPluginHost`) |
| Reference hub (executable server semantics) | `vendor/fah_hub_client/test/fake_hub.dart` (`FakeHub`), mirrored at `test/hub/fake_hub.dart` |


## 1. Overview

DAP/1 is a thin relay protocol: agents connect to a hub over a WebSocket
and exchange JSON frames. The hub authenticates every agent (Ed25519
signature on each frame), routes messages, and tracks presence — but it
never sees plaintext: message payloads are end-to-end encrypted between
the communicating agents (ChaCha20-Poly1305 under X25519 ECDH; §4). The
hub only ever learns public keys (`join` carries the channel *public*
key; `x25519` advertising is public).

```
agent A <---- signed frames ----> hub <---- signed frames ----> agent B
          E2E ciphertext only          E2E ciphertext only
```

Two delivery shapes:

- **Channels** — fan-out rooms. A send to `#channel` is relayed to every
  other connected agent on the hub (membership is enforced by key
  possession, not by the hub: agents without the channel private key
  receive ciphertext they cannot decrypt — `hub_client.dart`
  `_onMsg`: "no key or tampered payload — deliver opaque").
- **DMs** — directed `send` with a `to` agent id; routed to the live
  socket, or queued in an offline mailbox and delivered on `flush` (§6).


## 2. Wire format

Transport is a WebSocket carrying one JSON object per text frame. The
client dials `<hub>/ws` (`FakeHub._serve` routes `/ws` via
`WebSocketTransformer`; `/healthz` answers `200` for liveness probes).

### 2.1 Client → hub ops

| op | fields | purpose |
|---|---|---|
| `hello` | `v:1`, `pubkey`, `x25519`, `nonce`, `ts`, `name?`, `sig` | authenticated handshake (§3) |
| `join` | `channel`, `chanPubkey`, `sig` | join/create a channel (§5) |
| `send` | `channel` *or* `to`, `id`, `ts`, `ciphertext`, `sig` | channel message or DM (§4, §6) |
| `whois` | `agentId` | peer directory lookup (§7) |
| `flush` | — | drain the offline mailbox (§6) |
| `presence_query` | — | list known agents (§7) |

(`hub_client.dart` `_helloFrame`/`join`/`_sendEncrypted`/`whois`/`flush`/
`presenceQuery`; all frames except `whois`/`flush`/`presence_query` are
signed — see §3. `hello` is sent before authentication, so its signature
is self-referential: it proves the sender holds the private key matching
the advertised `pubkey`.)

### 2.2 Hub → client ops

| op | fields | purpose |
|---|---|---|
| `welcome` | `agentId` | hello accepted; assigns our id |
| `msg` | `from`, `id`, `ts`, `ciphertext`, `channel?`/`to?` | relayed message |
| `agent_info` | `agentId`, `pubkey`, `x25519`, `name?`, `online` | whois answer |
| `presence` | `agents[]` (`agentId`, `name`, `online`, `x25519`) | presence answer |
| `flushed` | `count` | mailbox drained, N messages delivered |
| `joined` | `channel` | join ack (client ignores it — `_onFrame` has no case) |
| `error` | `code`, `msg` | rejection: `bad_frame`, `stale_ts`, `replayed_nonce`, `bad_signature`, `unknown_agent`, `not_authenticated` |

The hub relays `msg` frames verbatim minus the `sig` field — the
signature authenticates the sender *to the hub*; payload authenticity
between agents comes from the AEAD tag (§4). Frame ids are UUID-v4-shaped
opaque strings (`canonical.dart` `newFrameId`).


## 3. Identity and the handshake

Each agent holds two keypairs, generated once and persisted together
(`identity.dart` `HubIdentity`):

- **Ed25519 signing keypair** — authenticates frames.
- **X25519 keypair** — payload E2E key agreement. Never used for
  signatures ("no cross-algorithm key reuse").

The agent id is derived, not chosen:
`agentId = hex(sha256(ed25519_pubkey_raw))[:16]` — 16 hex chars
(`identity.dart` `agentId`; `fake_hub.dart` `_agentIdFor` computes the
same). Same key ⇒ same id on every hub.

Key file: `~/.dap/keys/fah/<name>.key` (the sanitized display name, or
the hostname when unnamed — `dap_settings.dart` `defaultDapKeyPath`),
mode `0600`, line-based format `ed25519:<seed b64>`,
`x25519:<priv b64>`, `x25519pub:<pub b64>`. The `x25519pub:` line is
informational; the public key is always re-derived from the private
scalar so a torn write can never pair a mismatched pub with the priv
(`identity.dart` `HubIdentity.load`). If `chmod 600` cannot be applied
(Windows), the load still succeeds but warns loudly.

Display names are cosmetic but unique-checked: the hub registry stores
`name` from the hello, and name collisions make `dap_invite <name>` fail
as ambiguous rather than guess (`hub_client.dart` `PendingInvites`
`_inviteByName`).

### 3.1 hello/welcome

On every (re)connect the client sends one signed `hello`
(`hub_client.dart` `_helloFrame`):

```json
{ "op": "hello", "v": 1,
  "pubkey": "<ed25519 b64>", "x25519": "<x25519 b64>",
  "nonce": "<16 random hex chars>", "ts": 1756700000000,
  "name": "my-agent", "sig": "<b64>" }
```

Hub-side acceptance checks (`fake_hub.dart` `_checkHello`):

1. `ts` within ±300 s of hub time, else `stale_ts`;
2. `nonce` present, ≥ 16 chars, never seen before, else `replayed_nonce`;
3. Ed25519 signature valid over the signing payload (§3.2), else
   `bad_signature`.

On success the hub replies `{"op":"welcome","agentId":...}` and enforces
**one connection per agent**: a fresh hello from an already-connected id
evicts the old socket (`fake_hub.dart` `_hello`). A rejected hello is
fatal — the client surfaces the `HubError` and stops retrying
(`hub_client.dart` `_connectLoop`).

### 3.2 Frame signatures

Every signed frame carries `sig`, computed over the frame *without* the
`sig` field (`canonical.dart` `signingPayload`):

```
canonicalJSON  = UTF-8 JSON, object keys sorted recursively, no whitespace
sigPayload     = "dap1|" + op + "|" + ts + "|" + hex(sha256(canonicalJSON(frame)))
sig            = base64(Ed25519_sign(UTF-8(sigPayload)))
```

The hub verifies the hello against the frame's own `pubkey`, and every
`send` against the key registered at hello time
(`fake_hub.dart` `_verifySig`) — a hub that skips this check would let
any connected socket spoof any agent. The test suite's hub deliberately
re-implements the check rather than importing the client's
(`fake_hub.dart` header note), so wire-format bugs cannot cancel out.


## 4. End-to-end payload crypto

`send` frames carry no plaintext — only `ciphertext`, produced by
`payload_crypto.dart` `encryptPayload`:

```
DH secret = X25519(sender_DH_priv, recipient_DH_pub)
key       = HKDF-SHA256(ikm = DH secret, salt = frame_id, info = "dap1/v1") → 32 B
ciphertext= base64( nonce(12 B) || ChaCha20-Poly1305_ct || tag(16 B) )
AAD       = "dap1|" + frame_id + "|" + aadTarget
```

`aadTarget` binds the payload to its route: the channel name for channel
sends, the recipient agent id for DMs — cross-posting a DM payload into a
channel (or to another agent) fails the AEAD tag. HKDF-SHA256 is
implemented locally on `Hmac.sha256` with the RFC 5869 255-block cap
(`payload_crypto.dart` `hkdfSha256`; the `cryptography` package's HKDF
had no `info` parameter).

Who is the "recipient"?

- **DM**: the peer's X25519 public key, learned via `whois` before the
  first DM (§6). Sender encrypts with `senderPriv × peerPub`; the peer
  decrypts with `peerPriv × senderPub` (`hub_client.dart` `_decryptDm`).
- **Channel**: the channel keypair's *public* half. Sender encrypts with
  `senderPriv × channelPub`; every holder of the channel *private* key
  decrypts with `channelPriv × senderPub` (`_decryptChannel`).

Consequence: the hub can route but never read; a payload whose key you
lack is delivered with `plaintext: null` (opaque), never dropped
(`InboundMessage.plaintext` doc).


## 5. Channels

A channel is nothing but an X25519 keypair plus a name
(`channels.dart` `newChannelKeypair`). The hub knows only the name and
the public key.

- **Join**: `{"op":"join","channel":c,"chanPubkey":pub}` — the first
  join creates the channel and registers the pubkey; re-joins are
  idempotent and replayed after every reconnect/welcome
  (`hub_client.dart` `join`, `_joinKnownChannels`).
- **Membership = possession of the channel private key.** The hub's
  fan-out is broadcast (every connected agent except the sender gets the
  frame — `fake_hub.dart` `_send`); privacy comes from the key, not from
  a hub-side member list.
- **Senders need only the public key**; answering decrypts need the
  private key. A blind join lets you *post* into an existing room, but
  members cannot read you — get an invite instead (the NOTE on
  `hub_client.dart` `connectTo`).

Key lifecycle (`ChannelStore`, backed by the machine-shared
`~/.dap/channels.json` — `{ "<channel>": {"pub","priv"} }`, b64 X25519):

1. First send/join/invite touching an unknown channel **auto-generates**
   a keypair and persists it (`ChannelStore.keysFor`) — zero-config
   channel creation.
2. An accepted invite persists the received keypair
   (`ChannelStore.accept`).
3. Agents on the same machine share the file, so they share channels for
   free; across machines, see §9.3.


## 6. DMs, offline mailbox, invites

**Whois before first DM** is protocol-required: the sender must resolve
the peer's `x25519` key (`hub_client.dart` `sendDm` → `whois`; results
cached per agent id). `whois` answers `agent_info` with `pubkey`,
`x25519`, `name`, `online` — or `error unknown_agent`.

**Offline mailbox**: a DM for a disconnected agent is queued hub-side
(`fake_hub.dart` `_mailboxes`) and delivered on `flush`
(`{"op":"flushed","count":N}`). The client flushes automatically after
every welcome (`_flushAfterWelcome`), so mail sent while you were away
arrives on reconnect. Presence persists across disconnects (§7), so
agents see peers as `online: false`, not gone.

**Invite flow** (`dap_invite` → `PendingInvites.invite`): invites DM the
channel keypair as a normal E2E DM whose plaintext is exactly
`{"t":"chankey","channel":...,"pub":...,"priv":...}`
(`hub_client.dart` `inviteTo`; `channels.dart` `parseChankeyInvite`
validates the shape — regular chat starting with `{` fails it). The
receiving client detects the chankey DM, persists the keypair, joins the
channel, and surfaces only a notice — never the raw key JSON
(`_onMsg`).

Resolution rules for `dap_invite <name-or-id>`:

- 16-hex id → immediate chankey DM.
- display name, exactly one online match → immediate.
- ambiguous name → honest failure listing the matching ids.
- unknown or offline name → **pending invite**: `{name, channel}` is
  persisted to `~/.dap/config.json` under `invites`, and a background
  poller (15 s tick, plus an immediate check at arm time and after every
  welcome) delivers the chankey DM the moment the name appears online —
  restart-safe (`hub_client.dart` `PendingInvites`; the armed channel is
  created zero-config under the inviter's key at arm time).
- `channel` defaults to `general`.

The inviter gets a paste-ready connect line for the invitee:
`/dap <host> <name>` (`dapHostOf` strips scheme and `/ws`).


## 7. Presence

`presence_query` answers with every agent ever seen by the hub — online
and offline, self included — each as
`{agentId, name, online, x25519}` (`fake_hub.dart` `_presence`; the
registry survives disconnects). The CLI's `dap_peers` filters to
online-only unless `includeOffline: true` (`bin/fah_hub_plugin.dart`).
Ids are the addressing primitive: discover them via `dap_peers`, then
`dap_dm` by id or by unambiguous name (`_resolvePeer`).


## 8. The hub server

**There is no production hub implementation in this repository.** The
client vendored here speaks to an external hub (the PR was live-checked
against one); until a reference server is published, the executable
specification of the server contract in this repo is the test-suite hub:

- `vendor/fah_hub_client/test/fake_hub.dart` (mirrored at
  `test/hub/fake_hub.dart`) — `FakeHub`, ~330 lines: hello checks (§3.1),
  eviction, channel fan-out, DM routing, offline mailboxes, flush,
  whois, presence (§2.2, §5–§7). It implements the signature checks
  independently of the client library on purpose.

### 8.1 Running a local hub

`FakeHub` is a complete DAP/1 hub for development. To run one from a
checkout of this repo, create `tool/hub.dart`:

```dart
import 'dart:async';
import '../test/hub/fake_hub.dart';

Future<void> main() async {
  final hub = FakeHub();
  await hub.start();
  print('DAP hub on ${hub.url}');
  await Completer<void>().future; // run until killed
}
```

```
dart run tool/hub.dart          # → DAP hub on ws://127.0.0.1:<port>/ws
DAP_HUB_URL=ws://127.0.0.1:<port>/ws dart run bin/fah.dart
```

Properties to expect (all `FakeHub`-derived): binds loopback only, keeps
everything in memory — registry, live connections, offline mailboxes,
the seen-nonce set — so a hub restart loses undelivered offline mail and
nonce memory. `/healthz` answers `200`.

For a shared deployment you need the same semantics behind a real
socket: bind a public interface (or reverse-proxy to the loopback hub),
and put TLS in front (§8.2). The stateless model means hubs are
disposable: identities live on the agents, not the hub.

### 8.2 TLS expectations

The client dials exactly the URL it is given — `ws://` or `wss://`,
path preserved (`dap_settings.dart` `normalizeDapHost` keeps an explicit
`ws(s)://…/path` as-is; `WebSocket.connect` in `hub_client.dart`
`_cycle`). The zero-config default `ws://127.0.0.1:8787/ws` is plaintext
and loopback — fine for local development. For anything crossing a
network, terminate TLS at a reverse proxy (nginx/Caddy) and point agents
at `wss://hub.example.com/ws` — the shape used in the `hub:` config
example (`hub_config.dart`); Dart's WebSocket client validates `wss://`
against the system trust store, so use a real certificate.

### 8.3 What the hub stores

Nothing on disk, per the reference model: all state is in memory, and
the only durable state in the system lives on the *agents* (§9.2). A
hub restart is transparent apart from lost offline mail.


## 9. Client configuration

### 9.1 Configuration sources

Precedence, highest first (`dap_settings.dart` `resolveDapSettings`,
`hub_config.dart` `HubConfig.fromMap`):

1. **Environment**: `DAP_HUB_URL`, `DAP_KEY_PATH`, `DAP_AGENT_NAME`,
   `DAP_CHANNELS_FILE` — env beats the yaml section for url/keyPath/name
   (`fromMap`: `environment[envUrl] ?? scalar('url')`).
2. **`.fah/packages.yaml`** `hub:` section:

   ```yaml
   hub:
     url: wss://hub.internal:8443/ws
     keyPath: ~/.fah/hub-key
     name: my-agent
     channels:         # channel -> X25519 pubkey b64 (encrypt-to)
       general: Agh...
     channelSecrets:   # channel -> X25519 privkey b64 (decrypt-with)
       general: GhI...
   ```

   (`hub: false` or an empty value opts the plugin out entirely.)
3. **`~/.dap/config.json`** — persisted by `dap_connect`/`/dap`:
   `{"url": ..., "name": ..., "channels": [...], "invites": [...]}`.
   The default-room list only grows (never un-remembered);
   `invites` is the pending-invite queue (§6).
4. **Defaults**: url `ws://127.0.0.1:8787/ws`; identity
   `~/.dap/keys/fah/<name|hostname>.key` (auto-generated `0600` on first
   use — a second agent on the machine needs nothing but
   `DAP_AGENT_NAME`); channels `~/.dap/channels.json`.

The plugin is registered by default in `bin/fah.dart`; a plain `fah`
start connects in the background, and a failure against the untouched
default URL prints one quiet hint line instead of an error (the default
hub is usually just not running — `bin/fah_hub_plugin.dart` `_connect`).

### 9.2 Files on disk (all under `~/.dap/`)

| file | contents |
|---|---|
| `keys/fah/<name>.key` | identity, `0600` (§3) |
| `channels.json` | channel name → `{pub, priv}`, machine-shared (§5) |
| `config.json` | last hub url, display name, default rooms, pending `invites` (§6, §9.1) |

### 9.3 Multi-machine channel-key distribution

`channelSecrets` have to reach every machine that should *read* a
channel. Three ways, in order of intent:

1. **Invites (the intended flow).** `dap_invite <name> <channel>` sends
   the keypair as an E2E DM over the hub itself — nothing to copy, works
   for offline peers via the pending-invite queue (§6). Each machine's
   `ChannelStore.accept` persists its own copy of the key.
2. **Copy the channels file.** `~/.dap/channels.json` is deliberately
   machine-shared plaintext: `scp` it to the second machine. This is the
   same trust level as the invite path — possession of the private key
   *is* membership, and whoever hands you the key introduces you
   (`channels.dart` `ChannelStore.accept` doc).
3. **Explicit config.** Put `channels:` + `channelSecrets:` in
   `.fah/packages.yaml` (§9.1) — pre-shared out of band, per-project,
   overrides the shared file.


## 10. End-to-end walkthrough: zero to two agents talking

### 10.1 One machine

```bash
# 1. Start a hub (§8.1) and note the url, e.g. ws://127.0.0.1:8787/ws
DAP_HUB_URL=ws://127.0.0.1:8787/ws dart run tool/hub.dart

# 2. Machine-local agent A
DAP_HUB_URL=ws://127.0.0.1:8787/ws DAP_AGENT_NAME=alice dart run bin/fah.dart
#   → [hub] connected as <alice-agentId>

# 3. Second terminal — agent B (a second identity needs only a name)
DAP_HUB_URL=ws://127.0.0.1:8787/ws DAP_AGENT_NAME=bob dart run bin/fah.dart
```

4. In alice's REPL: `dap_peers` → note bob's 16-hex id.
5. `dap_dm to=<bob-id> text=hello bob` → bob's agent wakes at its next
   turn boundary (inbound hub mail is steering input) and sees the
   message; replies go through `dap_dm` back at alice — hub mail is
   *not* answered with the normal reply path.

Channel variant: `dap_invite nameOrId=bob` (channel defaults to
`general`) → bob's client accepts the chankey DM, joins, and both can
post/decrypt `#general`.

### 10.2 Two machines

1. Run the hub on machine A (or any host both can reach; §8.1 + §8.2 —
   for a dev hub on a remote box, an SSH tunnel works:
   `ssh -L 8787:127.0.0.1:8787 hostA` makes
   `ws://127.0.0.1:8787/ws` valid on machine B too).
2. On each machine: `export DAP_HUB_URL=wss://hub.example.com/ws` (or
   the tunneled url) and a distinct `DAP_AGENT_NAME`; start `fah`.
3. Identity is per-machine but stable: same name ⇒ same key file ⇒ same
   agentId on every reconnect. Cross-machine, names are how you find
   each other: `dap_peers` on either side lists both agents.
4. DMs work immediately (keys are exchanged via whois over the hub).
5. For a shared channel, one side creates it and invites the other —
   `dap_invite <peer-name-or-id> project-x` — which ships the
   `channelSecrets` across machines E2E (§9.3 path 1). No file copying
   needed unless you prefer the explicit-config route.


## 11. CLI surface

| surface | tier | what it does |
|---|---|---|
| `/dap` | — | connection status: agentId, name, url |
| `/dap <host> [name] [channel]` | — | retarget the live connection (host normalization: no scheme → `ws://`, no path → `/ws`) |
| `dap_status` | read | full snapshot incl. hello/welcome counters |
| `dap_peers` | read | presence list (`includeOffline`) |
| `dap_dm` | exec | E2E direct message (id or unambiguous name) |
| `dap_invite` | exec | chankey invite, offline-armed (§6) |
| `dap_connect` | exec | runtime connect to any hub (persists to `~/.dap/config.json`) |

(`bin/fah_hub_plugin.dart` `_dapTools`; read/exec tiers feed the normal
approval gate. Inbound hub mail is drained into the agent loop at every
turn boundary via the external-inbox seam — `hub_plugin.dart`
`externalSteeringSource`.)
