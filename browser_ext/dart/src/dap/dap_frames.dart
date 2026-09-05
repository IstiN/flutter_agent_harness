/// Pure DAP/1 pieces, VM-testable (no js_interop, no dart:io):
/// identity keypairs + the key-file format, frame builders, DM payload
/// encrypt/decrypt wrappers, reconnect backoff, and the shared mail
/// deduper. Crypto primitives come from fa_hub_client's pure slice —
/// nothing is re-implemented here (docs/dap.md is the wire spec).
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa_hub_client/src/hub/canonical.dart';
import 'package:fa_hub_client/src/hub/payload_crypto.dart';

/// DAP/1 identity: an Ed25519 signing keypair plus a separate X25519
/// keypair for payload E2E (no cross-algorithm key reuse).
///
/// `agentId = hex(sha256(ed25519_pubkey_raw))[:16]` — same key, same id on
/// every hub. Serialized in the `~/.dap` key-file format so an exported
/// identity is byte-compatible with the CLI's (`ed25519:<seed b64>`,
/// `x25519:<priv b64>`, `x25519pub:<pub b64>` — that last line is
/// informational; the public key is always re-derived from the scalar).
final class DapIdentity {
  DapIdentity._({
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

  /// `hex(sha256(ed25519_pubkey_raw))[:16]`.
  final String agentId;

  String get signingPubkeyB64 => base64Encode(signingPublicKey.bytes);
  String get dhPubkeyB64 => base64Encode(dhPublicKey.bytes);

  static Future<DapIdentity> generate() async => _build(
    signingKeyPair: await Ed25519().newKeyPair(),
    dhKeyPair: await X25519().newKeyPair(),
  );

  /// Restores an identity from [toKeyFile] output (or a CLI-written key
  /// file). Never trusts the stored `x25519pub:` line — the public key is
  /// re-derived from the private scalar.
  static Future<DapIdentity> fromKeyFile(String contents) async {
    final fields = <String, String>{};
    for (final line in contents.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) fields[line.substring(0, idx)] = line.substring(idx + 1);
    }
    final seed = fields['ed25519'];
    final dhPriv = fields['x25519'];
    if (seed == null || dhPriv == null) {
      throw ArgumentError('key file missing ed25519:/x25519: lines');
    }
    return _build(
      signingKeyPair: await Ed25519().newKeyPairFromSeed(base64Decode(seed)),
      dhKeyPair: await X25519().newKeyPairFromSeed(base64Decode(dhPriv)),
    );
  }

  static Future<DapIdentity> _build({
    required SimpleKeyPair signingKeyPair,
    required SimpleKeyPair dhKeyPair,
  }) async {
    final signingPub = await signingKeyPair.extractPublicKey();
    final dhPub = await dhKeyPair.extractPublicKey();
    final digest = await Sha256().hash(signingPub.bytes);
    return DapIdentity._(
      signingKeyPair: signingKeyPair,
      signingPublicKey: signingPub,
      dhKeyPair: dhKeyPair,
      dhPublicKey: dhPub,
      agentId: hexEncode(digest.bytes).substring(0, 16),
    );
  }

  /// Key-file serialization (see [fromKeyFile]).
  Future<String> toKeyFile() async {
    final seed = await signingKeyPair.extractPrivateKeyBytes();
    final dhPriv = await dhKeyPair.extractPrivateKeyBytes();
    return 'ed25519:${base64Encode(seed)}\n'
        'x25519:${base64Encode(dhPriv)}\n'
        'x25519pub:$dhPubkeyB64\n';
  }
}

/// Signed `hello` frame (docs/dap.md §3.1): fresh ts, ≥16-char random hex
/// nonce, signature over the frame without `sig`.
Future<Map<String, dynamic>> helloFrame(
  DapIdentity identity, {
  String? name,
  DateTime? now,
}) async {
  final frame = <String, dynamic>{
    'op': 'hello',
    'v': 1,
    'pubkey': identity.signingPubkeyB64,
    'x25519': identity.dhPubkeyB64,
    'nonce': randomHex(16),
    'ts': (now ?? DateTime.now()).millisecondsSinceEpoch,
    if (name != null && name.isNotEmpty) 'name': name,
  };
  frame['sig'] = await signFrame(frame, identity.signingKeyPair);
  return frame;
}

/// Signed `send` frame carrying an already-encrypted DM payload.
Future<Map<String, dynamic>> sendFrame({
  required DapIdentity from,
  required String to,
  required String ciphertext,
  String? frameId,
  int? ts,
}) async {
  final frame = <String, dynamic>{
    'op': 'send',
    'to': to,
    'id': frameId ?? newFrameId(),
    'ts': ts ?? DateTime.now().millisecondsSinceEpoch,
    'ciphertext': ciphertext,
  };
  frame['sig'] = await signFrame(frame, from.signingKeyPair);
  return frame;
}

/// Unsigned `whois` request — the hub never verifies these.
Map<String, dynamic> whoisFrame(String agentId) => {
  'op': 'whois',
  'agentId': agentId,
};

/// Unsigned `presence_query`. The hub echoes [frameId] back as `replyTo`,
/// letting the client match answers to waiters.
Map<String, dynamic> presenceQueryFrame(String frameId) => {
  'op': 'presence_query',
  'id': frameId,
};

/// Unsigned `flush` — drains the hub-side offline mailbox.
Map<String, dynamic> flushFrame() => {'op': 'flush'};

/// Signed `join`. Kept for wire completeness; the extension carries no
/// channel key store, so channels v1 stays unimplemented and this builder
/// has no caller today.
Future<Map<String, dynamic>> joinFrame({
  required DapIdentity identity,
  required String channel,
  required String chanPubkey,
}) async {
  final frame = <String, dynamic>{
    'op': 'join',
    'channel': channel,
    'chanPubkey': chanPubkey,
  };
  frame['sig'] = await signFrame(frame, identity.signingKeyPair);
  return frame;
}

/// Encrypts a DM payload for the holder of [peerX25519B64]. [to] (the
/// recipient agentId) is the AAD target, binding the payload to its route.
Future<String> encryptDm(
  DapIdentity from,
  String peerX25519B64,
  String frameId,
  String to,
  String plaintext,
) {
  return encryptPayload(
    senderDhKeyPair: from.dhKeyPair,
    recipientDhPubkey: SimplePublicKey(
      base64Decode(peerX25519B64),
      type: KeyPairType.x25519,
    ),
    frameId: frameId,
    aadTarget: to,
    plaintext: plaintext,
  );
}

/// Reconnect backoff (docs/dap.md): 1 s doubling, capped at 30 s. The cap
/// is clamped BEFORE the shift so far-out attempts can never overflow.
Duration reconnectBackoff(int attempt) {
  final shift = attempt.clamp(1, 6) - 1; // clamp before shift (cap 30 s)
  return Duration(seconds: 1 << shift > 30 ? 30 : 1 << shift);
}

/// Decrypts a DM produced by [encryptDm]. The AAD target is the DM
/// recipient id on both sides — i.e. the decrypting identity's own
/// agentId — so a payload cross-posted to another agent fails the AEAD
/// tag. Throws on wrong key or tampered payload.
Future<String> decryptDm(
  DapIdentity me,
  String senderX25519B64,
  String frameId,
  String ciphertextB64,
) {
  return decryptPayload(
    recipientDhKeyPair: me.dhKeyPair,
    senderDhPubkey: SimplePublicKey(
      base64Decode(senderX25519B64),
      type: KeyPairType.x25519,
    ),
    frameId: frameId,
    aadTarget: me.agentId,
    ciphertextB64: ciphertextB64,
  );
}

/// Placeholder delivered instead of dropping a payload we cannot decrypt —
/// key missing, peer unknown, or a broken/tampered box (never silent loss).
String undecryptableText(String from) =>
    '[hub] undecryptable message from $from';

/// Sliding seen-set over `(from, text)` pairs, shared by the bridge and
/// DAP mail paths so one peer message arriving on both links is delivered
/// once (AC18 — the bridge copy lands first and the DAP copy is dropped).
/// ponytail: insertion-ordered set as LRU ring; no timestamps needed.
final class MailDeduper {
  MailDeduper({this.capacity = 512});

  final int capacity;
  final _seen = <String>{};

  /// Whether [from]/[text] was not seen recently (and is now recorded).
  bool first(String from, String text) {
    final key = '$from\u0000$text';
    if (!_seen.add(key)) return false;
    if (_seen.length > capacity) _seen.remove(_seen.first);
    return true;
  }
}
