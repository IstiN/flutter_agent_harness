/// DAP/1 agent identity: an Ed25519 signing keypair plus a separate X25519
/// keypair for payload E2E (no cross-algorithm key reuse).
///
/// `agentId = hex(sha256(ed25519_pubkey_raw))[:16]` per docs/protocol.md.
library;

import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';

import 'canonical.dart';

class HubIdentity {
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

  /// `hex(sha256(ed25519_pubkey_raw))[:16]`.
  final String agentId;

  String get signingPubkeyB64 => base64Encode(signingPublicKey.bytes);
  String get dhPubkeyB64 => base64Encode(dhPublicKey.bytes);

  /// Generates a fresh identity.
  static Future<HubIdentity> generate() async {
    final signing = await Ed25519().newKeyPair();
    final dh = await X25519().newKeyPair();
    return _build(
      signingKeyPair: signing,
      dhKeyPair: dh,
    );
  }

  static Future<HubIdentity> _build({
    required SimpleKeyPair signingKeyPair,
    required SimpleKeyPair dhKeyPair,
  }) async {
    final signingPub = await signingKeyPair.extractPublicKey();
    final dhPub = await dhKeyPair.extractPublicKey();
    final digest = await Sha256().hash(signingPub.bytes);
    return HubIdentity._(
      signingKeyPair: signingKeyPair,
      signingPublicKey: signingPub,
      dhKeyPair: dhKeyPair,
      dhPublicKey: dhPub,
      agentId: hexEncode(digest.bytes).substring(0, 16),
    );
  }

  /// Loads the identity persisted at [keyPath], creating it (mode 0600) on
  /// first use. File format: `ed25519:<seed b64>`, `x25519:<priv b64>`,
  /// `x25519pub:<pub b64>`, one per line. The `x25519pub:` line is
  /// informational only — the public key is always re-derived from the
  /// private scalar, so a torn or legacy write can never pair a mismatched
  /// pub with this priv (the agent would advertise the stored pub while
  /// decrypting with the priv: outbound fine, every inbound DM
  /// undecryptable).
  static Future<HubIdentity> load(String keyPath) async {
    final file = File(keyPath);
    if (await file.exists()) {
      return _parse(await file.readAsString());
    }
    final identity = await generate();
    final signingSeed = await identity.signingKeyPair.extractPrivateKeyBytes();
    final dhPriv = await identity.dhKeyPair.extractPrivateKeyBytes();
    // Default paths nest (~/.dap/keys/fah/…) — create parents on demand.
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    // Atomic create via temp + rename: a crashed direct write could tear
    // the file mid-line and break every later load.
    final tmp = File('$keyPath.tmp');
    await tmp.writeAsString(
      'ed25519:${base64Encode(signingSeed)}\n'
      'x25519:${base64Encode(dhPriv)}\n'
      'x25519pub:${identity.dhPubkeyB64}\n',
      flush: true,
    );
    await tmp.rename(keyPath);
    // ponytail: dart:io has no chmod; best-effort 0600 via system chmod
    try {
      await Process.run('chmod', ['600', file.path]);
    } on Object {
      // non-POSIX platform — umask governs
    }
    return identity;
  }

  static Future<HubIdentity> _parse(String contents) async {
    final fields = <String, String>{};
    for (final line in contents.split('\n')) {
      final idx = line.indexOf(':');
      if (idx > 0) fields[line.substring(0, idx)] = line.substring(idx + 1);
    }
    final signing =
        await Ed25519().newKeyPairFromSeed(base64Decode(fields['ed25519']!));
    // Never trust the stored `x25519pub:` line — derive from the scalar.
    final dh = await X25519().newKeyPairFromSeed(base64Decode(fields['x25519']!));
    return _build(signingKeyPair: signing, dhKeyPair: dh);
  }
}
