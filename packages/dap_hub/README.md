# dap_hub

A self-hosted **DAP/1 hub** in pure Dart: a zero-knowledge relay that
routes **end-to-end-encrypted**, pubkey-ACL'd channels between agent
clients (DM and presence included). The hub never sees plaintext — it
holds only ciphertext frames, public keys, and secret hashes.

Port of the Go DAP hub (`main.go`, `relay.go`, `auth.go`, …) with the
same wire contract: a client written against the Go hub interoperates
with this one.

## What it does

- **Channels with pubkey ACLs** — `join`/`send` frames relayed to
  channel subscribers; the ACL lists Ed25519 public keys, not identities.
- **Direct messages** — agent-to-agent frames by `agentId`
  (`hex(sha256(pubkey))[:16]`), with an offline mailbox fallback.
- **Presence** — `presence_query` answered with the live/busy/offline
  view of registered agents.
- **Enroll** — first-connect pairing: a one-time master secret
  bootstraps per-agent bearer secrets (only hashes are persisted).
- **Zero knowledge** — payloads are NaCl box ciphertext
  (X25519 + XSalsa20-Poly1305); the hub verifies *signatures* (Ed25519)
  and *timestamps/nonces* against replay, never plaintext.
- **Backpressure that is real** — writes are paced by `Socket.flush()`;
  slow consumers are shed at a bounded queue cap instead of growing
  memory without limit.

## Pure-Dart core, IO at the edge

`package:dap_hub/dap_hub.dart` is pure Dart — no `dart:io`. The hub
works against a `DapConnection` interface, so tests drive it in-memory
and any transport can be bound.

`package:dap_hub/io.dart` adds `DapHubServer`: an HTTP server with the
WebSocket upgrade and a hand-rolled RFC 6455 codec (text/binary,
fragmentation, ping/pong, close handshake, masking rules, 2 MiB message
cap).

## Running the hub

```sh
dart pub global activate dap_hub   # or: dart run bin/dap_hub.dart from source

HUB_MASTER_SECRET=<bootstrap-secret> dap_hub -addr 127.0.0.1:8080
```

Configuration (env or flag):

| Env var               | Flag              | Default         | Purpose                    |
|-----------------------|-------------------|-----------------|----------------------------|
| `HUB_ADDR`            | `-addr`           | `:8080`         | listen address             |
| `HUB_MASTER_SECRET`   | `-master-secret`  | — (required)    | enroll bootstrap secret    |
| `HUB_ADMIN_TOKEN`     | `-admin-token`    | —               | admin HTTP API bearer      |
| `HUB_CHANNELS_FILE`   | `-channels-file`  | `channels.json` | persisted channel ACLs     |
| `HUB_SECRETS_FILE`    | `-secrets-file`   | `secrets.json`  | persisted secret hashes    |

The hub is designed for **loopback / trusted-network** deployment (the
reference deployment is a per-machine LaunchAgent / user service). It is
not a cross-machine transport.

## Embedding

```dart
import 'package:dap_hub/dap_hub.dart';
import 'package:dap_hub/io.dart';

final hub = DapHub(config: DapHubConfig(masterSecret: 'bootstrap-secret'));
final server = await DapHubServer.start(hub); // 127.0.0.1:8080 by default
```

## Status

0.x — wire-compatible with the Go DAP/1 hub for the implemented frame
set (hello/enroll, join, send, flush, whois, presence_query, admin API).
