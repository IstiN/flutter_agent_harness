// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// ai-native OAuth-proxy client shared by the desktop CLI login flow.
/// The relay URL is deliberately NOT used here: `/api/oauth-proxy/*` and
/// `/api/auth/*` live on the auth service (`https://ai-native.cloud`).
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'network_account.dart';
import 'secret_redaction.dart';

/// Production ai-native auth service, matching the Flutter app config.
const networkAuthProductionUrl = 'https://ai-native.cloud';

/// Production fa_network relay, matching the Flutter app config.
const networkRelayProductionUrl = 'https://network.fa1.dev';

/// OAuth initiation result: open [authUrl] verbatim and require the callback
/// to echo [state].
final class NetworkOAuthInitiation {
  /// Builds an initiation result.
  const NetworkOAuthInitiation({
    required this.authUrl,
    required this.state,
    required this.expiresIn,
  });

  /// Provider authorization URL issued by the auth service.
  final Uri authUrl;

  /// Server-issued CSRF state.
  final String state;

  /// Server hint for the initiation lifetime.
  final int expiresIn;
}

/// Typed auth-client failure. Response bodies on error paths are bounded;
/// successful token documents are never included in exceptions.
final class NetworkAuthException implements Exception {
  /// Builds an auth failure.
  const NetworkAuthException(this.message, {this.statusCode});

  /// Human-readable failure.
  final String message;

  /// HTTP status, or null for a transport/decode failure.
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'NetworkAuthException: $message'
      : 'NetworkAuthException($statusCode): $message';
}

/// Pure HTTP OAuth and refresh client. Inject [httpClient] with
/// `http.testing.MockClient` in tests.
final class NetworkAccountClient {
  /// Builds a client for [baseUrl].
  NetworkAccountClient({
    this.baseUrl = networkAuthProductionUrl,
    http.Client? httpClient,
    DateTime Function()? clock,
  }) : _http = httpClient ?? http.Client(),
       _clock = clock ?? DateTime.now;

  /// Auth service root (no trailing slash required).
  final String baseUrl;

  final http.Client _http;
  final DateTime Function() _clock;

  /// Starts the desktop OAuth proxy flow for [provider].
  Future<NetworkOAuthInitiation> initiate({
    required String provider,
    required Uri redirectUri,
    String clientType = 'desktop',
    String environment = 'prod',
  }) async {
    final json = await _post('/api/oauth-proxy/initiate', {
      'provider': provider,
      'client_redirect_uri': redirectUri.toString(),
      'client_type': clientType,
      'environment': environment,
    });
    final authUrl = json['auth_url'];
    final state = json['state'];
    if (authUrl is! String ||
        authUrl.isEmpty ||
        state is! String ||
        state.isEmpty) {
      throw const NetworkAuthException(
        'OAuth initiation returned no auth_url/state',
      );
    }
    final expires = json['expires_in'];
    return NetworkOAuthInitiation(
      authUrl: Uri.parse(authUrl),
      state: state,
      expiresIn: expires is num ? expires.toInt() : 0,
    );
  }

  /// Exchanges a temporary loopback [code] and its CSRF [state].
  Future<NetworkAccount> exchange({
    required String code,
    required String state,
  }) => _tokens('/api/oauth-proxy/exchange', {'code': code, 'state': state});

  /// Refreshes an account using its long-lived [refreshToken].
  Future<NetworkAccount> refresh(String refreshToken) =>
      _tokens('/api/auth/refresh', {'refreshToken': refreshToken});

  Future<NetworkAccount> _tokens(
    String path,
    Map<String, Object?> request,
  ) async {
    final json = await _post(path, request);
    final access = json['accessToken'] ?? json['access_token'];
    if (access is! String || access.isEmpty) {
      throw const NetworkAuthException('token response has no access token');
    }
    final refresh = _nonEmpty(json['refreshToken'] ?? json['refresh_token']);
    final now = _clock().toUtc();
    final expiresIn = _seconds(json['expiresIn'] ?? json['expires_in']);
    final refreshExpiresIn = _seconds(
      json['refreshExpiresIn'] ?? json['refresh_expires_in'],
    );
    final pasted = NetworkAccount.fromJwt(access);
    return NetworkAccount(
      accessToken: access,
      refreshToken: refresh,
      expiresAt: expiresIn == null
          ? pasted.expiresAt
          : now.add(Duration(seconds: expiresIn)),
      refreshExpiresAt: refreshExpiresIn == null
          ? null
          : now.add(Duration(seconds: refreshExpiresIn)),
      subject: pasted.subject,
      email: pasted.email,
      displayName: pasted.displayName,
    );
  }

  Future<Map<String, Object?>> _post(
    String path,
    Map<String, Object?> body,
  ) async {
    http.Response response;
    try {
      response = await _http.post(
        Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}$path'),
        headers: {'content-type': 'application/json'},
        body: jsonEncode(body),
      );
    } on Object catch (error) {
      throw NetworkAuthException('auth request failed: $error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw NetworkAuthException(
        'auth request rejected: ${_snippet(response.body)}',
        statusCode: response.statusCode,
      );
    }
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map) return decoded.cast<String, Object?>();
      throw FormatException('expected object, got ${decoded.runtimeType}');
    } on FormatException catch (error) {
      throw NetworkAuthException('malformed auth response: $error');
    }
  }

  static int? _seconds(Object? value) => value is num ? value.toInt() : null;

  static String? _nonEmpty(Object? value) =>
      value is String && value.isNotEmpty ? value : null;

  static String _snippet(String body) {
    final flat = redactNetworkSecretText(body.replaceAll('\n', ' ').trim());
    return flat.length <= 120 ? flat : '${flat.substring(0, 120)}…';
  }
}
