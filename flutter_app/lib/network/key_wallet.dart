// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Device-only key wallet for fa_network.
///
/// Contents (JSON v1): the device identity X25519 keypair, per-channel
/// X25519 keypairs keyed `'<networkId>/<channel>'`, and per-network join
/// metadata keyed `'<networkId>'`. Session tokens are NEVER stored here
/// (memory-only per contract E7).
///
/// Invariant I2: key material is never logged — nothing in this file
/// prints or logs `priv` values.
library;

import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:fa_ui/fa_ui.dart' show KeychainStore;
// The harness barrel pulls dart:io transitively; the ExecutionEnv interface
// itself is pure Dart, so import it directly to keep lib/network web-safe.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/env/execution_env.dart';

import 'envelope_codec.dart';

/// Storage abstraction for [KeyWallet]: one JSON document in, one out.
abstract interface class WalletBackend {
  /// The stored wallet JSON, or `null` when nothing was stored yet.
  Future<String?> read();

  /// Persists [json], replacing any previous content.
  Future<void> write(String json);
}

/// Stores the wallet in the platform keychain via fa_ui's [KeychainStore].
///
/// [KeychainStore] has no interface, so the three operations are injected
/// as closures (defaulting to a real [KeychainStore] instance) — tests
/// inject in-memory fakes.
final class KeychainWalletBackend implements WalletBackend {
  /// Creates a backend; with no closures injected, a real [KeychainStore]
  /// is used.
  KeychainWalletBackend({
    Future<Map<String, String>> Function()? readAll,
    Future<bool> Function(String name, String value)? setValue,
    Future<bool> Function(String name)? deleteValue,
  }) : _readAll = readAll ?? const KeychainStore().readAll,
       _setValue = setValue ?? const KeychainStore().set,
       _deleteValue = deleteValue ?? const KeychainStore().delete;

  /// The keychain entry name the wallet JSON is stored under.
  static const storageName = 'fa_network_wallet';

  final Future<Map<String, String>> Function() _readAll;
  final Future<bool> Function(String name, String value) _setValue;
  // ignore: unused_field -- kept for future wallet reset support
  final Future<bool> Function(String name) _deleteValue;

  @override
  Future<String?> read() async => (await _readAll())[storageName];

  @override
  Future<void> write(String json) => _setValue(storageName, json);
}

/// Stores the wallet in `<cwd>/network_wallet.json` via an [ExecutionEnv].
///
/// Best effort on permissions: the harness [FileSystem] interface has no
/// chmod, so the file relies on the platform default (0600-class on mobile
/// sandboxes); callers on desktop should treat the file as sensitive.
final class FileWalletBackend implements WalletBackend {
  /// Creates a backend rooted at [env]'s working directory.
  FileWalletBackend(this._env, {this.fileName = 'network_wallet.json'});

  final ExecutionEnv _env;

  /// The wallet file name inside the environment's cwd.
  final String fileName;

  Future<String> get _path async =>
      (await _env.joinPath([_env.cwd, fileName])).getOrThrow();

  @override
  Future<String?> read() async {
    final result = await _env.readTextFile(await _path);
    return switch (result) {
      Ok(:final value) => value,
      Err(:final error) when error.code == FileErrorCode.notFound => null,
      Err(:final error) => throw error,
    };
  }

  @override
  Future<void> write(String json) async {
    final result = await _env.writeFile(await _path, json);
    if (result case Err(:final error)) throw error;
  }
}

/// In-memory backend — for tests and web until an IndexedDB backend lands.
final class MemoryWalletBackend implements WalletBackend {
  /// The stored JSON (null until first write).
  String? stored;

  @override
  Future<String?> read() async => stored;

  @override
  Future<void> write(String json) async => stored = json;
}

/// The device identity keypair.
final class WalletIdentity {
  /// Creates an identity from base64-encoded X25519 keys.
  const WalletIdentity({
    required this.pub,
    required this.priv,
    this.displayName = '',
  });

  /// Base64 X25519 public key (32 bytes decoded).
  final String pub;

  /// Base64 X25519 private key (32 bytes decoded). Never logged.
  final String priv;

  /// Human-readable name shown to other members.
  final String displayName;

  /// Tolerant parse: throws [FormatException] when pub/priv are missing.
  factory WalletIdentity.fromJson(Map<String, Object?> json) {
    final pub = json['pub'];
    final priv = json['priv'];
    if (pub is! String || priv is! String) {
      throw const FormatException('wallet identity missing pub/priv');
    }
    return WalletIdentity(
      pub: pub,
      priv: priv,
      displayName: json['displayName'] is String
          ? json['displayName']! as String
          : '',
    );
  }

  /// Serializes to JSON.
  Map<String, Object?> toJson() => {
    'pub': pub,
    'priv': priv,
    'displayName': displayName,
  };
}

/// X25519 keys for one channel.
final class ChannelKeys {
  /// Creates channel keys from base64-encoded X25519 keys.
  const ChannelKeys({required this.pub, required this.priv});

  /// Base64 X25519 public key.
  final String pub;

  /// Base64 X25519 private key. Never logged.
  final String priv;

  /// Tolerant parse; returns `null` when the entry is malformed.
  static ChannelKeys? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final pub = json['pub'];
    final priv = json['priv'];
    if (pub is! String || priv is! String) return null;
    return ChannelKeys(pub: pub, priv: priv);
  }

  /// Serializes to JSON.
  Map<String, Object?> toJson() => {'pub': pub, 'priv': priv};
}

/// Join metadata for one network.
final class NetworkEntry {
  /// Creates a network entry.
  const NetworkEntry({
    required this.name,
    required this.joinedAt,
    this.memberClass = 'member',
    this.displayName = '',
    this.password,
  });

  /// The network's display name.
  final String name;

  /// ISO-8601 join timestamp.
  final String joinedAt;

  /// Member class: owner|admin|member|guest|agent.
  final String memberClass;

  /// Our display name within this network.
  final String displayName;

  /// The network password, stored so a relaunch can silently re-join
  /// (the contract's sessionToken is memory-only, E7). The wallet is the
  /// device's only secret store, so this lives here and nowhere else.
  final String? password;

  /// Tolerant parse; returns `null` when the entry is malformed.
  static NetworkEntry? tryFromJson(Object? json) {
    if (json is! Map) return null;
    final name = json['name'];
    if (name is! String) return null;
    return NetworkEntry(
      name: name,
      joinedAt: json['joinedAt'] is String ? json['joinedAt']! as String : '',
      memberClass: json['memberClass'] is String
          ? json['memberClass']! as String
          : 'member',
      displayName: json['displayName'] is String
          ? json['displayName']! as String
          : '',
      password: json['password'] is String ? json['password']! as String : null,
    );
  }

  /// Serializes to JSON.
  Map<String, Object?> toJson() => {
    'name': name,
    'joinedAt': joinedAt,
    'memberClass': memberClass,
    'displayName': displayName,
    if (password != null) 'password': password,
  };
}

/// The device-only fa_network key wallet. Mutations update the in-memory
/// state and, when a [WalletBackend] is attached, persist automatically.
final class KeyWallet {
  KeyWallet._({
    WalletBackend? backend,
    WalletIdentity? identity,
    Map<String, ChannelKeys>? channels,
    Map<String, NetworkEntry>? networks,
  })
    // ignore: prefer_initializing_formals
    : _backend = backend,
       // ignore: prefer_initializing_formals
       _identity = identity,
       _channels = Map.of(channels ?? const {}),
       _networks = Map.of(networks ?? const {});

  WalletBackend? _backend;
  WalletIdentity? _identity;
  final Map<String, ChannelKeys> _channels;
  final Map<String, NetworkEntry> _networks;

  /// Loads the wallet from [backend]. With no stored data, returns an
  /// empty wallet (call [createIfMissing] next). Throws [FormatException]
  /// on corrupted JSON — never silently wipes keys.
  static Future<KeyWallet> load(WalletBackend backend) async {
    final json = await backend.read();
    if (json == null || json.trim().isEmpty) {
      return KeyWallet._(backend: backend);
    }
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('wallet JSON root is not an object');
    }
    return KeyWallet._(
      backend: backend,
      identity: _parseIdentity(decoded['identity']),
      channels: _parseChannels(decoded['channels']),
      networks: _parseNetworks(decoded['networks']),
    );
  }

  /// Parses wallet JSON (tolerant: missing optional sections default to
  /// empty; malformed channel/network entries are skipped).
  factory KeyWallet.fromJson(Map<String, Object?> json) => KeyWallet._(
    identity: _parseIdentity(json['identity']),
    channels: _parseChannels(json['channels']),
    networks: _parseNetworks(json['networks']),
  );

  /// Parses a wallet JSON string. Throws [FormatException] on garbage.
  static KeyWallet fromJsonString(String jsonString) {
    final decoded = jsonDecode(jsonString);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('wallet JSON root is not an object');
    }
    return KeyWallet.fromJson(decoded);
  }

  static WalletIdentity? _parseIdentity(Object? json) {
    if (json is! Map<String, Object?>) return null;
    try {
      return WalletIdentity.fromJson(json);
    } on FormatException {
      return null;
    }
  }

  static Map<String, ChannelKeys> _parseChannels(Object? json) {
    if (json is! Map) return {};
    return {
      for (final entry in json.entries)
        if (entry.key is String)
          // ignore: use_null_aware_elements
          if (ChannelKeys.tryFromJson(entry.value) case final keys?)
            entry.key as String: keys,
    };
  }

  static Map<String, NetworkEntry> _parseNetworks(Object? json) {
    if (json is! Map) return {};
    return {
      for (final entry in json.entries)
        if (entry.key is String)
          // ignore: use_null_aware_elements
          if (NetworkEntry.tryFromJson(entry.value) case final network?)
            entry.key as String: network,
    };
  }

  /// Whether an identity keypair exists.
  bool get hasIdentity => _identity != null;

  /// Base64 identity public key, or null before [createIfMissing].
  String? get identityPub => _identity?.pub;

  /// Base64 identity private key (never logged — invariant I2).
  String? get identityPriv => _identity?.priv;

  /// The identity display name.
  String get displayName => _identity?.displayName ?? '';

  /// Unmodifiable view of network metadata, keyed by networkId.
  Map<String, NetworkEntry> get networks => Map.unmodifiable(_networks);

  /// Serializes the wallet to JSON v1.
  Map<String, Object?> toJson() => {
    'v': 1,
    if (_identity case final identity?) 'identity': identity.toJson(),
    'channels': {
      for (final entry in _channels.entries) entry.key: entry.value.toJson(),
    },
    'networks': {
      for (final entry in _networks.entries) entry.key: entry.value.toJson(),
    },
  };

  /// The wallet as a JSON string.
  String serialize() => jsonEncode(toJson());

  /// Attaches [backend] and persists the current state to it.
  Future<void> saveTo(WalletBackend backend) {
    _backend = backend;
    return _persist();
  }

  /// Generates the identity keypair when missing (idempotent) and persists.
  Future<void> createIfMissing({String displayName = ''}) async {
    if (_identity != null) return;
    final pair = await EnvelopeCodec.newX25519KeyPair();
    _identity = WalletIdentity(
      pub: pair.pub,
      priv: pair.priv,
      displayName: displayName,
    );
    await _persist();
  }

  /// Records membership of a network and persists.
  Future<void> addNetwork({
    required String networkId,
    required String name,
    String memberClass = 'member',
    String? displayName,
    String? password,
    DateTime? joinedAt,
  }) async {
    _networks[networkId] = NetworkEntry(
      name: name,
      joinedAt: (joinedAt ?? DateTime.now()).toUtc().toIso8601String(),
      memberClass: memberClass,
      displayName: displayName ?? _identity?.displayName ?? '',
      password: password ?? _networks[networkId]?.password,
    );
    await _persist();
  }

  /// Stores channel keys under `<networkId>/<channel>` and persists.
  Future<void> addChannelKeys({
    required String networkId,
    required String channel,
    required String pub,
    required String priv,
  }) async {
    _channels['$networkId/$channel'] = ChannelKeys(pub: pub, priv: priv);
    await _persist();
  }

  /// Removes a network and all of its channel keys, then persists.
  Future<void> removeNetwork(String networkId) async {
    _networks.remove(networkId);
    _channels.removeWhere((key, _) => key.startsWith('$networkId/'));
    await _persist();
  }

  /// Replaces the whole contents with [other]'s and persists (wallet
  /// import): the live wallet object stays in place, so every holder
  /// (session manager, UI) sees the imported identity/keys/memberships
  /// without a restart.
  Future<void> replaceWith(KeyWallet other) async {
    _identity = other._identity;
    _channels
      ..clear()
      ..addAll(other._channels);
    _networks
      ..clear()
      ..addAll(other._networks);
    await _persist();
  }

  /// The stored keys for `<networkId>/<channel>`, or null.
  ({String pub, String priv})? channelKeysFor(
    String networkId,
    String channel,
  ) {
    final keys = _channels['$networkId/$channel'];
    return keys == null ? null : (pub: keys.pub, priv: keys.priv);
  }

  /// The identity as a cryptography [SimpleKeyPair].
  Future<SimpleKeyPair> identityKeyPair() async {
    final identity = _identity;
    if (identity == null) {
      throw StateError('wallet has no identity; call createIfMissing first');
    }
    return const EnvelopeCodec().keyPairFromPriv(identity.priv);
  }

  /// The channel keys for `<networkId>/<channel>` as a [SimpleKeyPair].
  Future<SimpleKeyPair> channelKeyPair(String networkId, String channel) async {
    final keys = _channels['$networkId/$channel'];
    if (keys == null) {
      throw StateError('no channel keys for $networkId/$channel');
    }
    return const EnvelopeCodec().keyPairFromPriv(keys.priv);
  }

  Future<void> _persist() async {
    final backend = _backend;
    if (backend != null) await backend.write(serialize());
  }
}
