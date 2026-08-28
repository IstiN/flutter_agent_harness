/// Canonical signing helpers for DAP/1 frames.
///
/// Spec (docs/protocol.md):
///   sigPayload = "dap1|" + op + "|" + ts + "|" + hex(sha256(canonicalJSON(
///                frameWithoutSigField)))
///   canonicalJSON = UTF-8 JSON, object keys sorted recursively, no
///   whitespace, no trailing newline.
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

final _sha256 = Sha256();
final _ed25519 = Ed25519();
final _random = Random.secure();

/// Recursively key-sorted, whitespace-free JSON encoding of [value].
String canonicalJson(Object? value) => jsonEncode(_sorted(value));

Object? _sorted(Object? value) {
  if (value is Map<String, dynamic>) {
    final keys = value.keys.toList()..sort();
    return {for (final k in keys) k: _sorted(value[k])};
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

/// The DAP/1 signing payload for [frame] (which must not yet contain `sig`).
Future<String> signingPayload(Map<String, dynamic> frame) async {
  final op = frame['op'] as String;
  final ts = frame['ts'].toString();
  final digest = await _sha256.hash(utf8.encode(canonicalJson(frame)));
  return 'dap1|$op|$ts|${hexEncode(digest.bytes)}';
}

/// Signs [frame] (without `sig` field) and returns the b64 signature.
Future<String> signFrame(
  Map<String, dynamic> frame,
  SimpleKeyPair keyPair,
) async {
  final payload = await signingPayload(frame);
  final sig = await _ed25519.sign(utf8.encode(payload), keyPair: keyPair);
  return base64Encode(sig.bytes);
}

/// Verifies a DAP/1 signature over [frame] (without `sig` field).
Future<bool> verifyFrame(
  Map<String, dynamic> frame,
  String sigB64,
  SimplePublicKey publicKey,
) async {
  final payload = await signingPayload(frame);
  final sig = Signature(
    base64Decode(sigB64),
    publicKey: publicKey,
  );
  return _ed25519.verify(utf8.encode(payload), signature: sig);
}

String hexEncode(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// Random lowercase hex string of [nChars] characters (nonce, ids).
String randomHex(int nChars) {
  const digits = '0123456789abcdef';
  return List.generate(
    nChars,
    (_) => digits[_random.nextInt(16)],
  ).join();
}

/// Opaque unique frame id, uuid-v4 shaped.
String newFrameId() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = hexEncode(b);
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
