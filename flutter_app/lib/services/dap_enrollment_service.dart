// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Composer DAP enrollment parsing and its small, secret-free result type.
///
/// The raw paste is never retained, logged, sent to analytics, or written
/// to a session. Only the parsed bundle crosses into the native join and
/// dedicated enrollment store.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fa/services/keychain_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'project_mount_env.dart';

/// One terminal enrollment outcome.
enum DapEnrollmentStatus { joined, failed, unsupported }

/// A localized-UI-ready outcome; deliberately carries no raw error text.
final class DapEnrollmentResult {
  const DapEnrollmentResult(
    this.status,
    this.channel, {
    this.plaintextStorage = false,
  });

  final DapEnrollmentStatus status;
  final String channel;

  /// True only when the successful join actually used the unencrypted
  /// fallback (not merely when the platform could support a Keychain).
  final bool plaintextStorage;
}

/// A synchronously recognized paste with its asynchronous join operation.
final class DapEnrollmentAttempt {
  const DapEnrollmentAttempt(this.channel, this.result);

  final String channel;
  final Future<DapEnrollmentResult> result;
}

typedef DapEnrollmentJoin = Future<void> Function(DapJoinBundle bundle);

/// Reports whether the just-completed join persisted through the plaintext
/// fallback. Extension-hosted joins provide a constant-false probe because
/// their service worker owns a different store.
typedef DapEnrollmentStorageProbe = Future<bool> Function();

/// Parses only bundles accepted by the CLI parser, then delegates the join.
final class DapEnrollmentService {
  factory DapEnrollmentService({
    required DapEnrollmentJoin join,
    required bool supported,
    DapEnrollmentStorageProbe? plaintextStorage,
  }) => DapEnrollmentService._(join, supported, plaintextStorage);

  const DapEnrollmentService._(
    this._join,
    this._supported,
    this._plaintextStorage,
  );

  final DapEnrollmentJoin _join;
  final bool _supported;
  final DapEnrollmentStorageProbe? _plaintextStorage;

  /// Returns null for ordinary text (including prose that mentions DAP).
  /// Recognition is synchronous, so the composer can clear a secret-bearing
  /// draft before the first network await.
  DapEnrollmentAttempt? startPaste(String raw, {String? defaultHubUrl}) {
    final DapJoinBundle bundle;
    try {
      bundle = parseDapJoinBundle(raw, defaultHubUrl: defaultHubUrl);
    } on FormatException {
      return null;
    }
    // Defer the first join/store operation until the composer has cleared
    // the secret-bearing controller and discarded any staged paste chip.
    return DapEnrollmentAttempt(
      bundle.invite.channel,
      Future(() => _run(bundle)),
    );
  }

  Future<DapEnrollmentResult> _run(DapJoinBundle bundle) async {
    final channel = bundle.invite.channel;
    if (!_supported) {
      return DapEnrollmentResult(DapEnrollmentStatus.unsupported, channel);
    }
    if (!_validHubUrl(bundle.hubUrl)) {
      return DapEnrollmentResult(DapEnrollmentStatus.failed, channel);
    }
    try {
      await _join(bundle);
      var plaintext = false;
      try {
        plaintext = await _plaintextStorage?.call() ?? false;
      } on Object {
        // A failed storage probe fails safe: warn rather than risk hiding
        // an unencrypted fallback after an otherwise successful join.
        plaintext = true;
      }
      return DapEnrollmentResult(
        DapEnrollmentStatus.joined,
        channel,
        plaintextStorage: plaintext,
      );
    } on Object {
      // Exception strings can contain transport-supplied text. Do not carry
      // them into the UI/logs; the localized failure is the safe boundary.
      return DapEnrollmentResult(DapEnrollmentStatus.failed, channel);
    }
  }

  static bool _validHubUrl(String value) {
    final uri = Uri.tryParse(value);
    return uri != null &&
        (uri.scheme == 'wss' || uri.scheme == 'ws') &&
        uri.host.isNotEmpty &&
        uri.fragment.isEmpty;
  }
}

/// Stable short scope shared by the enrollment record and identity path.
/// Mirroring the CLI, the same project keeps its address while two working
/// directories cannot evict one another's hub connection.
String dapEnrollmentProjectScope(String projectCwd) =>
    sha256.convert(utf8.encode(projectCwd)).toString().substring(0, 10);

/// Stable identity-path scope for an enrollment. A nonempty instance replaces
/// the project cwd as the digest input, so independent configs cannot share
/// an Ed25519 key and one config keeps its identity across projects/restarts.
/// Null/empty is byte-for-byte the legacy project behavior.
String dapEnrollmentIdentityScope(String projectCwd, String? agentInstance) =>
    dapEnrollmentProjectScope(
      agentInstance == null || agentInstance.isEmpty
          ? projectCwd
          : agentInstance,
    );

/// One active enrollment per project, persisted through the app's existing
/// secure-store/filesystem mechanisms. Keychain/Keystore is preferred when
/// available. Otherwise [save] writes PLAINTEXT, unencrypted JSON to
/// `fa_dap_enrollment_<sha256(projectCwd)[:10]>.json` at the app-storage root
/// (`env.appStorageCwd`): the invite `priv`, hub `clientSecret`, and non-secret
/// `agentInstance` are persisted so reconnect restores the same credential
/// and identity. Web always uses this
/// fallback and mirrors the sandbox file into origin-scoped IndexedDB;
/// Linux and Windows always use the sandbox JSON file. Sandbox/origin
/// isolation is not encryption.
///
/// This is intentionally a single record: [AgentNetworkController] owns one
/// live hub connection. A new paste replaces that connection and its record.
final class DapEnrollmentStore {
  DapEnrollmentStore._(
    this._write,
    this._clear, [
    this.enrollment,
    this.isPlaintext = false,
  ]);

  /// Non-persistent test seam.
  DapEnrollmentStore.inMemory([this.enrollment])
    : _write = null,
      _clear = null,
      isPlaintext = false;

  static const _version = 1;

  final Future<void> Function(String json)? _write;
  final Future<void> Function()? _clear;

  /// The record restored for reconnect; never includes the raw paste.
  DapJoinBundle? enrollment;

  /// Whether this store writes verbatim JSON instead of using Keychain.
  final bool isPlaintext;

  static String storageName(String projectCwd) =>
      'fa_dap_enrollment_${dapEnrollmentProjectScope(projectCwd)}';

  static String fileName(String projectCwd) =>
      '${storageName(projectCwd)}.json';

  static Future<DapEnrollmentStore> load(
    ExecutionEnv env, {
    required String projectCwd,
    KeychainStore keychain = const KeychainStore(),
  }) async {
    final name = storageName(projectCwd);
    final path = '${env.appStorageCwd}/${fileName(projectCwd)}';
    if (await keychain.isAvailable()) {
      final stored = _decode((await keychain.readAll())[name]);
      return DapEnrollmentStore._(
        (json) async {
          if (!await keychain.set(name, json)) {
            throw StateError('secure enrollment store write failed');
          }
        },
        () async {
          if (!await keychain.delete(name)) {
            throw StateError('secure enrollment store delete failed');
          }
        },
        stored,
      );
    }

    final stored = _decode((await env.readTextFile(path)).valueOrNull);
    return DapEnrollmentStore._(
      (json) async {
        final result = await env.writeFile(path, json);
        if (result case Err(:final error)) throw error;
      },
      () async {
        final result = await env.remove(path);
        if (result case Err(:final error)) {
          if (error.code != FileErrorCode.notFound) throw error;
        }
      },
      stored,
      true,
    );
  }

  Future<void> save(DapJoinBundle bundle) async {
    await _write?.call(_encode(bundle));
    enrollment = bundle;
  }

  Future<void> clear() async {
    await _clear?.call();
    enrollment = null;
  }

  static String _encode(DapJoinBundle bundle) => jsonEncode({
    'version': _version,
    'hubUrl': bundle.hubUrl,
    'inviteHubUrl': bundle.invite.hubUrl,
    'channel': bundle.invite.channel,
    if (bundle.invite.pub != null) 'pub': bundle.invite.pub,
    if (bundle.invite.priv != null) 'priv': bundle.invite.priv,
    if (bundle.clientSecret != null) 'clientSecret': bundle.clientSecret,
    if (bundle.agentName != null) 'agentName': bundle.agentName,
    if (bundle.agentInstance != null) 'agentInstance': bundle.agentInstance,
  });

  static DapJoinBundle? _decode(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic> || decoded['version'] != _version) {
        return null;
      }
      final invite = DapInviteImport(
        hubUrl: decoded['inviteHubUrl'] as String,
        channel: decoded['channel'] as String,
        pub: decoded['pub'] as String?,
        priv: decoded['priv'] as String?,
      );
      return DapJoinBundle(
        invite: invite,
        hubUrl: decoded['hubUrl'] as String,
        clientSecret: decoded['clientSecret'] as String?,
        agentName: decoded['agentName'] as String?,
        agentInstance: decoded['agentInstance'] as String?,
      );
    } on Object {
      // A corrupt store must not block app boot. It is never logged because
      // the document contains credentials.
      return null;
    }
  }
}
