// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Per-agent X25519 DM key provisioning for the machine connector (§7).
///
/// Keys are keyed by the full `<agentName>@<deviceId>` address. Persistence
/// is a host concern: production stores the private-key map in the same
/// secure credential document as the enrolled device token. This file stays
/// pure Dart and performs no file, keychain, or socket IO itself.
library;

import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';

import '../../messaging/hub_crypto.dart';

/// Secure persistence for DM private seeds, keyed by full agent address.
///
/// Values are base64-encoded 32-byte X25519 private keys. Implementations
/// replace the complete map atomically; [DeviceDmKeyProvider] serializes its
/// read-modify-write operations so provisioning two agents cannot lose one.
abstract interface class DeviceDmKeyStore {
  /// Reads the current private-key map (empty before first provisioning).
  Future<Map<String, String>> readDmPrivateKeys();

  /// Persists the complete private-key map alongside enrollment credentials.
  Future<void> writeDmPrivateKeys(Map<String, String> keys);
}

/// In-memory [DeviceDmKeyStore], useful for ephemeral connectors and tests.
final class MemoryDeviceDmKeyStore implements DeviceDmKeyStore {
  /// Creates an empty store, or wraps [initial] with a defensive copy.
  MemoryDeviceDmKeyStore([Map<String, String> initial = const {}])
    : keys = Map.of(initial);

  /// Current map; production credential stores keep the equivalent private.
  final Map<String, String> keys;

  /// Number of completed writes.
  var writes = 0;

  @override
  Future<Map<String, String>> readDmPrivateKeys() async => Map.of(keys);

  @override
  Future<void> writeDmPrivateKeys(Map<String, String> keys) async {
    this.keys
      ..clear()
      ..addAll(keys);
    writes++;
  }
}

/// One provisioned agent DM keypair and its persistable wire encodings.
final class DeviceDmKeyPair {
  const DeviceDmKeyPair._({
    required this.keyPair,
    required this.privateKey,
    required this.publicKey,
  });

  /// X25519 keypair for fanet1 ECDH/decryption.
  final SimpleKeyPair keyPair;

  /// Base64-encoded 32-byte private seed. Secret: never log this value.
  final String privateKey;

  /// Base64-encoded X25519 public key published as roster `dmPub`.
  final String publicKey;
}

/// Loads or creates the single DM keypair for each full agent address.
final class DeviceDmKeyProvider {
  /// Builds a provider over the host's secure credential-backed [store].
  DeviceDmKeyProvider(this._store);

  final DeviceDmKeyStore _store;
  final _cache = <String, DeviceDmKeyPair>{};
  final _pending = <String, Future<DeviceDmKeyPair>>{};
  Future<void> _writes = Future<void>.value();

  /// Returns the stable keypair for [agentAddress], creating and persisting
  /// it only on first use. Concurrent calls for one address share one result;
  /// a new device id naturally produces a new address and therefore new keys.
  Future<DeviceDmKeyPair> loadOrCreate(String agentAddress) {
    if (agentAddress.isEmpty) {
      throw ArgumentError.value(
        agentAddress,
        'agentAddress',
        'must not be empty',
      );
    }
    final cached = _cache[agentAddress];
    if (cached != null) return Future.value(cached);
    final pending = _pending[agentAddress];
    if (pending != null) return pending;
    final operation = _serialize(() => _loadOrCreate(agentAddress));
    _pending[agentAddress] = operation;
    return operation.whenComplete(() => _pending.remove(agentAddress));
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _writes.then((_) => operation());
    _writes = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<DeviceDmKeyPair> _loadOrCreate(String agentAddress) async {
    final stored = await _store.readDmPrivateKeys();
    final restored = await _restore(stored[agentAddress]);
    if (restored != null) {
      _cache[agentAddress] = restored;
      return restored;
    }
    final created = await _fromKeyPair(await hubGenerateX25519KeyPair());
    final latest = await _store.readDmPrivateKeys();
    await _store.writeDmPrivateKeys({
      ...latest,
      agentAddress: created.privateKey,
    });
    _cache[agentAddress] = created;
    return created;
  }

  Future<DeviceDmKeyPair?> _restore(String? privateKey) async {
    if (privateKey == null) return null;
    try {
      return await _fromKeyPair(
        await hubX25519KeyPairFromSeed(base64Decode(privateKey)),
      );
    } on Object {
      // Corrupt local material cannot decrypt future mail. Replace it through
      // the normal create+persist path rather than breaking device presence.
      return null;
    }
  }

  static Future<DeviceDmKeyPair> _fromKeyPair(SimpleKeyPair keyPair) async {
    final privateKey = await keyPair.extractPrivateKeyBytes();
    final publicKey = await keyPair.extractPublicKey();
    return DeviceDmKeyPair._(
      keyPair: keyPair,
      privateKey: base64Encode(privateKey),
      publicKey: base64Encode(publicKey.bytes),
    );
  }
}
