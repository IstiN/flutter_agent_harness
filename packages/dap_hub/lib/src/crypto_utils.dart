// Shared crypto primitives for the DAP/1 hub: sha256 helpers, the
// constant-time credential compare, and the agentId derivation.
//
// Port of the Go hub's auth.go helpers (constEq, agentIDFor, sha256Hex).

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Hex (lowercase) of the sha256 of [input]'s UTF-8 bytes — the digest
/// form used for every issued-secret hash on disk and in memory.
String sha256Hex(String input) => sha256.convert(utf8.encode(input)).toString();

/// Constant-time string compare: hashes first so length does not leak,
/// then XOR-folds without early exit. Used on every credential path
/// (bearer tokens, ACL pubkeys).
bool constEq(String a, String b) {
  final ah = sha256.convert(utf8.encode(a)).bytes;
  final bh = sha256.convert(utf8.encode(b)).bytes;
  var diff = 0;
  for (var i = 0; i < ah.length; i++) {
    diff |= ah[i] ^ bh[i];
  }
  return diff == 0;
}

/// The DAP/1 agentId of a raw 32-byte Ed25519 public key:
/// `hex(sha256(pubkey_raw))[:16]`.
String agentIdFor(List<int> pubkeyRaw) =>
    sha256.convert(pubkeyRaw).toString().substring(0, 16);
