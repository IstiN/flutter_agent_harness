// Ed25519 envelope verification, timestamp window, and the replay caches.
//
// Port of the Go hub's auth.go: signedPayloadFor, verifySignature, tsFresh,
// nonceCache, sendIDCache.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';

import 'canonical_json.dart';
import 'frames.dart';

/// Spec: timestamps must be within ±300 s of the hub clock.
const tsWindowMs = 300000;

/// Hello nonces are held for the full ts window plus a minute.
const replayKeepMs = tsWindowMs + 60000;
const nonceSweepEveryMs = 60000;
const nonceMinLength = 16;

/// The per-sender send-id dedupe ring capacity.
const sendIdCap = 4096;

final _ed25519 = Ed25519();

/// Builds the canonical signing payload:
/// `dap1|<op>|<ts>|hex(sha256(canonicalJSON(frame minus sig)))`.
///
/// Throws [DapProtoError] with `bad_signature` when `sig` is absent.
String signedPayloadFor(DapFrame frame) {
  if (frame.sig.isEmpty) {
    throw const DapProtoError(DapCodes.badSignature, 'missing sig');
  }
  final clone = Map<String, Object?>.of(frame.raw)..remove('sig');
  final sum = sha256.convert(utf8.encode(canonicalJson(clone)));
  return 'dap1|${frame.op}|${frame.ts}|$sum';
}

/// Checks the Ed25519 signature over the canonical payload. [pubkeyB64] is
/// the signing key: self-declared in hello, the authenticated connection
/// key for every later frame. Returns a [DapProtoError] on failure.
Future<DapProtoError?> verifySignature(
  DapFrame frame,
  String pubkeyB64,
) async {
  final String payload;
  try {
    payload = signedPayloadFor(frame);
  } on DapProtoError catch (e) {
    return e;
  }
  final List<int> pub;
  try {
    pub = base64.decode(pubkeyB64);
  } on Object {
    return const DapProtoError(DapCodes.badSignature, 'bad pubkey');
  }
  if (pub.length != 32) {
    return const DapProtoError(DapCodes.badSignature, 'bad pubkey');
  }
  final List<int> sig;
  try {
    sig = base64.decode(frame.sig);
  } on Object {
    return const DapProtoError(DapCodes.badSignature, 'bad sig encoding');
  }
  final ok = await _ed25519.verify(
    utf8.encode(payload),
    signature: Signature(
      sig,
      publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519),
    ),
  );
  if (!ok) {
    return const DapProtoError(DapCodes.badSignature, 'verification failed');
  }
  return null;
}

/// Whether [ts] is inside the ±300 s window of [nowMs].
bool tsFresh(int ts, int nowMs) => (nowMs - ts).abs() <= tsWindowMs;

/// Remembers hello nonces per pubkey for the replay window
/// (port of the Go nonceCache).
final class NonceCache {
  final Map<String, Map<String, int>> _seen = {};
  var _lastSweep = 0;

  /// Records [nonce] for [pubkey]; false means it was already seen.
  bool check(String pubkey, String nonce, int nowMs) {
    final perPub = _seen.putIfAbsent(pubkey, () => {});
    final expiry = perPub[nonce];
    if (expiry != null && nowMs < expiry) return false;
    perPub[nonce] = nowMs + replayKeepMs;
    perPub.removeWhere((_, exp) => nowMs >= exp);
    if (nowMs - _lastSweep >= nonceSweepEveryMs) _sweep(nowMs);
    return true;
  }

  void _sweep(int nowMs) {
    _lastSweep = nowMs;
    _seen.removeWhere((_, perPub) {
      perPub.removeWhere((_, exp) => nowMs >= exp);
      return perPub.isEmpty;
    });
  }
}

/// A bounded per-sender FIFO of ACCEPTED send-frame ids (port of the Go
/// sendIDCache). Membership never latches — ids latch only after the
/// routing decision succeeds, so a rejected send can be retried with the
/// same id. The dedupe window is "last [sendIdCap] accepted sends": a
/// safety net against client id reuse, not a cryptographic guarantee.
final class SendIdCache {
  final Map<String, List<String>> _ids = {};
  final Map<String, int> _next = {};

  /// Whether [pubkey] already sent [id] (no side effects).
  bool seen(String pubkey, String id) => _ids[pubkey]?.contains(id) ?? false;

  /// Latches [id] for [pubkey], overwriting the oldest entry once full.
  void add(String pubkey, String id) {
    final ring = _ids.putIfAbsent(pubkey, () => []);
    if (ring.length < sendIdCap) {
      ring.add(id);
      return;
    }
    final next = _next[pubkey] ?? 0;
    ring[next] = id;
    _next[pubkey] = (next + 1) % sendIdCap;
  }
}
