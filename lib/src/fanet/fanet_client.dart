/// Pure-Dart REST client for a fa_network server.
///
/// Used by the CLI network mode (`FA_NETWORK_URL` / `FA_NETWORK_PASSWORD` /
/// `FA_CHANNEL_URL` / `FA_AGENT_NAME` env) to join a network and mint a DAP
/// session. HTTP goes through an injectable `package:http` client
/// (`MockClient` in tests); the library never touches `dart:io` directly.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'fanet_models.dart';

/// Base class for fa_network REST failures. Sealed so consumers can
/// exhaustively switch on the failure kind (shaped after
/// `AgentHarnessException` in `lib/src/exceptions.dart`).
sealed class FanetException implements Exception {
  /// Creates a [FanetException] with a human-readable [message].
  const FanetException(this.message);

  /// Human-readable description of what went wrong.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// The fa_network server answered with an unexpected HTTP status.
final class FanetApiException extends FanetException {
  /// Creates a [FanetApiException] for [statusCode], carrying a truncated
  /// [bodyExcerpt] of the response body for diagnostics.
  const FanetApiException(
    super.message, {
    required this.statusCode,
    required this.bodyExcerpt,
  });

  /// The HTTP status code returned by the server.
  final int statusCode;

  /// Truncated response body, for diagnostics.
  final String bodyExcerpt;
}

/// REST client for a fa_network server.
final class FanetClient {
  /// Creates a client against [baseUrl] (the server origin, e.g.
  /// `https://network.fa1.dev`; a trailing slash is tolerated).
  ///
  /// When [client] is omitted a default `package:http` client is created
  /// and owned by this instance; [close] closes only an owned client.
  FanetClient({required String baseUrl, http.Client? client})
    : baseUrl = baseUrl.endsWith('/')
          ? baseUrl.substring(0, baseUrl.length - 1)
          : baseUrl,
      _client = client ?? http.Client(),
      _ownsClient = client == null;

  /// The server origin all endpoints are resolved against.
  final String baseUrl;

  final http.Client _client;
  final bool _ownsClient;

  static const _bodyExcerptLimit = 500;

  /// Closes the underlying HTTP client when this instance owns it.
  void close() {
    if (_ownsClient) _client.close();
  }

  /// Joins [networkId] with [password] (and optional [displayName]).
  ///
  /// `POST /api/networks/{id}/join` with body
  /// `{password, displayName?}`; expects `200`.
  Future<FanetJoinResult> joinNetwork(
    String networkId, {
    required String password,
    String? displayName,
  }) async {
    final response = await _client.post(
      _uri('/api/networks/${Uri.encodeComponent(networkId)}/join'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'password': password, 'displayName': ?displayName}),
    );
    _expectStatus(response, const {200}, 'joinNetwork($networkId)');
    return FanetJoinResult.fromJson(_jsonObject(response));
  }

  /// Enrolls an agent [name] in [networkId], authenticated with an
  /// owner/admin-class [token] (management JWT or owner/admin sessionToken —
  /// a plain member sessionToken gets `403`).
  ///
  /// `POST /api/networks/{id}/agents/enroll` with body `{name}`; expects
  /// `201` only. There is no revoke/delete endpoint: to rotate (and thereby
  /// revoke) an agent's secret, call [enrollAgent] again with the same
  /// [name] — re-enrollment silently returns a fresh `201` enrollment and
  /// the old secret dies. A `503` means the hub is offline (the error body
  /// may carry `hub_unavailable`); invalid names (`FanetAgentName.isValid`)
  /// get `400` with `invalid_credentials`.
  Future<FanetAgentEnrollment> enrollAgent(
    String networkId, {
    required String token,
    required String name,
  }) async {
    final response = await _client.post(
      _uri('/api/networks/${Uri.encodeComponent(networkId)}/agents/enroll'),
      headers: {
        'content-type': 'application/json',
        'authorization': 'Bearer $token',
      },
      body: jsonEncode({'name': name}),
    );
    _expectStatus(response, const {201}, 'enrollAgent($name)');
    return FanetAgentEnrollment.fromJson(_jsonObject(response));
  }

  Uri _uri(String path) => Uri.parse('$baseUrl$path');

  static void _expectStatus(
    http.Response response,
    Set<int> expected,
    String operation,
  ) {
    if (expected.contains(response.statusCode)) return;
    final body = response.body;
    final excerpt = body.length <= _bodyExcerptLimit
        ? body
        : '${body.substring(0, _bodyExcerptLimit)}…';
    throw FanetApiException(
      'fa_network $operation failed: HTTP ${response.statusCode}',
      statusCode: response.statusCode,
      bodyExcerpt: excerpt,
    );
  }

  static Map<String, Object?> _jsonObject(http.Response response) {
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException catch (e) {
      throw FormatException(
        'fa_network response is not valid JSON: ${e.message}',
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException(
        'fa_network response is not a JSON object: $decoded',
      );
    }
    return decoded;
  }
}
