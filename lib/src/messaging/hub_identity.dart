/// DAP/1 agent identity for the hub-backed messaging fabric: an Ed25519
/// signing keypair plus a separate X25519 keypair for payload E2E (no
/// cross-algorithm key reuse) — `agentId = hex(sha256(ed25519_pubkey))[:16]`
/// per docs/protocol.md.
///
/// Pure Dart (the crypto comes from `package:cryptography`): generates and
/// holds keys, never touches files. Persistence is a host concern — the io
/// entry point (`lib/io.dart`) binds a file-backed loader so the app agent
/// keeps the same id across restarts (stable names/addressing).
library;

import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

final _ed25519 = Ed25519();
final _x25519 = X25519();
final _sha256 = Sha256();
final _random = Random.secure();

/// Random lowercase hex string of [nChars] characters (hello nonces).
String hubRandomHex(int nChars) =>
    List.generate(nChars, (_) => _random.nextInt(16).toRadixString(16)).join();

/// Opaque unique frame id, uuid-v4 shaped.
String newHubFrameId() {
  final b = List<int>.generate(16, (_) => _random.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// The hex-encoding shared by id derivation and signing payloads.
String hubHex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

/// The DAP/1 agent identity (signing + DH keypairs, derived agent id).
final class HubIdentity {
  HubIdentity._({
    required this.signingKeyPair,
    required this.signingPublicKey,
    required this.dhKeyPair,
    required this.dhPublicKey,
    required this.agentId,
  });

  final SimpleKeyPair signingKeyPair;
  final SimplePublicKey signingPublicKey;

  /// X25519 keypair used for payload encryption (never for signatures).
  final SimpleKeyPair dhKeyPair;
  final SimplePublicKey dhPublicKey;

  /// `hex(sha256(ed25519_pubkey_raw))[:16]` — the hub address.
  final String agentId;

  String get signingPubkeyB64 => base64Encode(signingPublicKey.bytes);
  String get dhPubkeyB64 => base64Encode(dhPublicKey.bytes);

  /// Generates a fresh identity (tests, first boot without a store).
  static Future<HubIdentity> generate() async => _build(
    signingKeyPair: await _ed25519.newKeyPair(),
    dhKeyPair: await _x25519.newKeyPair(),
  );

  /// Rebuilds an identity from persisted seeds — the stable-address path
  /// (hosts store the seeds, the id survives restarts).
  static Future<HubIdentity> fromSeeds({
    required List<int> ed25519Seed,
    required List<int> x25519Private,
  }) async => _build(
    signingKeyPair: await _ed25519.newKeyPairFromSeed(ed25519Seed),
    dhKeyPair: await _x25519.newKeyPairFromSeed(x25519Private),
  );

  static Future<HubIdentity> _build({
    required SimpleKeyPair signingKeyPair,
    required SimpleKeyPair dhKeyPair,
  }) async {
    final signingPub = await signingKeyPair.extractPublicKey();
    final dhPub = await dhKeyPair.extractPublicKey();
    final digest = await _sha256.hash(signingPub.bytes);
    return HubIdentity._(
      signingKeyPair: signingKeyPair,
      signingPublicKey: signingPub,
      dhKeyPair: dhKeyPair,
      dhPublicKey: dhPub,
      agentId: hubHex(digest.bytes).substring(0, 16),
    );
  }
}
