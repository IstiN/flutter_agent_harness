## 0.1.0

- Initial release: a pure-Dart DAP/1 hub, ported from the Go reference
  implementation with the same wire contract.
- Channel relay with pubkey ACLs, direct messages with offline mailbox
  fallback, presence queries, enroll pairing (master secret → per-agent
  bearer, hashes only persisted).
- Zero-knowledge: Ed25519 signature verification + timestamp/nonce
  replay protection; payloads stay NaCl-box ciphertext end to end.
- `io.dart`: `DapHubServer` with a hand-rolled RFC 6455 codec —
  real `Socket.flush()` backpressure, slow-consumer shed at a bounded
  queue cap, 2 MiB message limit.
- `dap_hub` executable configured via env/flags.
