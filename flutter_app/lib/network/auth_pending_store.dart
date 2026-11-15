// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

// The ExecutionEnv interface itself is pure Dart; importing it directly
// keeps the network authentication code web-safe.
// ignore: implementation_imports
import 'package:flutter_agent_harness/src/env/execution_env.dart';

/// The process-independent half of an OAuth sign-in. The authorization
/// code is deliberately absent: it arrives later on the callback URI.
final class PendingOAuthFlow {
  const PendingOAuthFlow({
    required this.provider,
    required this.clientType,
    required this.environment,
    required this.redirectUri,
    required this.state,
    required this.createdAt,
  });

  static const maxAge = Duration(minutes: 10);

  final String provider;
  final String clientType;
  final String environment;
  final Uri redirectUri;
  final String state;
  final DateTime createdAt;

  bool isFreshAt(DateTime now) {
    final age = now.toUtc().difference(createdAt);
    return !age.isNegative && age <= maxAge;
  }

  Map<String, Object?> toJson() => {
    'provider': provider,
    'clientType': clientType,
    'environment': environment,
    'redirectUri': redirectUri.toString(),
    'state': state,
    'createdAt': createdAt.toUtc().toIso8601String(),
  };

  static PendingOAuthFlow? tryFromJson(Object? value) {
    if (value is! Map) return null;
    final provider = _nonEmptyString(value['provider']);
    final clientType = _nonEmptyString(value['clientType']);
    final environment = _nonEmptyString(value['environment']);
    final redirectUri = _parseRedirectUri(value['redirectUri']);
    final state = _nonEmptyString(value['state']);
    final createdAt = _parseCreatedAt(value['createdAt']);
    if (provider == null ||
        clientType == null ||
        environment == null ||
        redirectUri == null ||
        state == null ||
        createdAt == null) {
      return null;
    }
    return PendingOAuthFlow(
      provider: provider,
      clientType: clientType,
      environment: environment,
      redirectUri: redirectUri,
      state: state,
      createdAt: createdAt.toUtc(),
    );
  }

  static String? _nonEmptyString(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return value;
  }

  static Uri? _parseRedirectUri(Object? value) {
    if (value is! String) return null;
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme) return null;
    return uri;
  }

  static DateTime? _parseCreatedAt(Object? value) =>
      value is String ? DateTime.tryParse(value) : null;
}

/// One pending OAuth document in, one out. Implementations are injectable so
/// authentication tests never touch platform storage.
abstract interface class PendingOAuthStore {
  Future<void> save(PendingOAuthFlow flow);
  Future<PendingOAuthFlow?> read();
  Future<void> clear();
}

/// Stores the pending flow at `<cwd>/pending_oauth.json` (the mobile app's
/// cwd is its `fah_sandbox` directory).
final class FilePendingOAuthStore implements PendingOAuthStore {
  FilePendingOAuthStore(this._env);

  static const fileName = 'pending_oauth.json';

  final ExecutionEnv _env;

  Future<String> get _path async =>
      (await _env.joinPath([_env.cwd, fileName])).getOrThrow();

  @override
  Future<void> save(PendingOAuthFlow flow) async {
    final result = await _env.writeFile(await _path, jsonEncode(flow.toJson()));
    if (result case Err(:final error)) throw error;
  }

  @override
  Future<PendingOAuthFlow?> read() async {
    final result = await _env.readTextFile(await _path);
    final text = switch (result) {
      Ok(:final value) => value,
      Err(:final error) when error.code == FileErrorCode.notFound => null,
      Err(:final error) => throw error,
    };
    if (text == null || text.trim().isEmpty) return null;
    try {
      final flow = PendingOAuthFlow.tryFromJson(jsonDecode(text));
      if (flow == null) await clear();
      return flow;
    } on FormatException {
      await clear();
      return null;
    }
  }

  @override
  Future<void> clear() async {
    final result = await _env.remove(await _path, force: true);
    if (result case Err(:final error)) throw error;
  }
}

/// In-memory pending storage for tests and hosts without a filesystem.
final class MemoryPendingOAuthStore implements PendingOAuthStore {
  PendingOAuthFlow? _flow;

  @override
  Future<void> save(PendingOAuthFlow flow) async => _flow = flow;

  @override
  Future<PendingOAuthFlow?> read() async => _flow;

  @override
  Future<void> clear() async => _flow = null;
}
