/// GitHub OAuth device flow for the Copilot connect flow (`/provider
/// copilot`): the device-code request, the prompt-free polling loop, and
/// the typed errors the CLI surfaces.
///
/// Protocol per goal/copilot_provider.md (migrated from copilot-proxy-go
/// internal/auth/device_flow.go). Phase-0 live finding: GitHub routes the
/// device endpoints but rejects this app's device flow with
/// 404 {"error":"Not Found"} (identical for a garbage client id) — that
/// state surfaces as [CopilotDeviceFlowErrorKind.endpointDisabled] naming
/// the client id, and the CLI always offers the paste-an-existing-token
/// fallback alongside the flow. The client id stays overridable (parameter
/// + the `FA_COPILOT_CLIENT_ID` env name at the CLI layer).
///
/// Pure Dart: no `dart:io`. Timings are injectable — the poller takes a
/// REQUIRED `delay` function (tests fake it; the CLI passes a real one).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'provider_common.dart';

/// The public client id of the VS Code Copilot Chat plugin
/// (goal/copilot_provider.md, internal/api/config.go).
const copilotDeviceClientId = 'Iv1.b507a08c87ecfe98';

/// The device-code request endpoint.
const copilotDeviceGrantUrl = 'https://github.com/login/device/code';

/// The token-poll endpoint.
const copilotDevicePollUrl = 'https://github.com/login/oauth/access_token';

/// The device-flow scope (enough to resolve the login and mint Copilot
/// tokens).
const copilotDeviceScope = 'read:user';

/// The extra second the proxy adds to the server-reported base interval.
const _pollIntervalSlack = Duration(seconds: 1);

/// The `slow_down` penalty (RFC 8628 / the proxy's device_flow.go).
const _slowDownPenalty = Duration(seconds: 5);

/// One granted device-code session: what the user sees ([userCode] at
/// [verificationUri]) plus what the poller needs ([deviceCode],
/// [expiresIn], [interval]).
final class CopilotDeviceGrant {
  /// Creates a grant.
  const CopilotDeviceGrant({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.expiresIn,
    required this.interval,
  });

  /// The server-side device code (sent only to the poll endpoint).
  final String deviceCode;

  /// The human-typed code shown to the user.
  final String userCode;

  /// Where the user enters [userCode].
  final String verificationUri;

  /// The code's lifetime in seconds (the polling deadline).
  final int expiresIn;

  /// The server-recommended base polling interval in seconds.
  final int interval;
}

/// Why a device flow failed. [endpointDisabled] is the Phase-0 live state:
/// GitHub routes the endpoint but rejects the app's flow (404 JSON error).
enum CopilotDeviceFlowErrorKind { expired, denied, transport, endpointDisabled }

/// A typed device-flow failure; the CLI prints [message] verbatim.
final class CopilotDeviceFlowError implements Exception {
  /// Creates an error.
  const CopilotDeviceFlowError(this.kind, this.message);

  /// The failure class.
  final CopilotDeviceFlowErrorKind kind;

  /// The human-readable explanation (never carries secrets).
  final String message;

  @override
  String toString() => message;
}

/// Requests a device code (goal: device_flow.go `requestDeviceCode`).
///
/// Throws [CopilotDeviceFlowError] with kind [CopilotDeviceFlowErrorKind
/// .endpointDisabled] when GitHub rejects the app's device flow (a 404 or
/// a JSON error body — the Phase-0 live finding), naming [clientId] and
/// the paste-a-token fallback; transport errors carry the HTTP detail.
Future<CopilotDeviceGrant> requestCopilotDeviceGrant({
  String clientId = copilotDeviceClientId,
  String scope = copilotDeviceScope,
  http.Client? client,
}) async {
  final transport = client ?? sharedProviderHttpClient();
  final http.Response response;
  try {
    response = await transport
        .post(
          Uri.parse(copilotDeviceGrantUrl),
          headers: const {'accept': 'application/json'},
          body: {'client_id': clientId, 'scope': scope},
        )
        .timeout(effectiveProviderConnectTimeout);
  } on CopilotDeviceFlowError {
    rethrow;
  } on Object catch (error) {
    throw CopilotDeviceFlowError(
      CopilotDeviceFlowErrorKind.transport,
      'Copilot device-code request failed: $error',
    );
  }
  final body = _decodeJsonObject(response);
  if (body == null) {
    throw CopilotDeviceFlowError(
      CopilotDeviceFlowErrorKind.transport,
      'Copilot device-code request returned a non-JSON response '
      '(HTTP ${response.statusCode}): ${response.body.trim()}',
    );
  }
  final errorField = body['error'];
  if (response.statusCode != 200 ||
      (errorField is String && errorField.isNotEmpty)) {
    throw _endpointDisabled(clientId, response.statusCode, response.body);
  }
  final deviceCode = body['device_code'];
  final userCode = body['user_code'];
  if (deviceCode is! String || userCode is! String) {
    throw CopilotDeviceFlowError(
      CopilotDeviceFlowErrorKind.transport,
      'Copilot device-code response had an unexpected shape: '
      '${response.body.trim()}',
    );
  }
  return CopilotDeviceGrant(
    deviceCode: deviceCode,
    userCode: userCode,
    verificationUri: switch (body['verification_uri']) {
      final String uri when uri.isNotEmpty => uri,
      _ => 'https://github.com/login/device',
    },
    expiresIn: switch (body['expires_in']) {
      final int n => n,
      _ => 900,
    },
    interval: switch (body['interval']) {
      final int n => n,
      _ => 5,
    },
  );
}

/// Polls for the GitHub token until the user authorizes (goal:
/// device_flow.go `pollAccessToken`).
///
/// [delay] is REQUIRED and injectable — tests fake it, the CLI passes a
/// real one; the poller never sleeps on its own. The base wait is the
/// server `interval` + 1s (proxy semantics); `slow_down` adds 5s
/// cumulatively; the loop is bounded by the grant's `expires_in`.
/// [onStatus] receives prompt-free waiting lines.
///
/// Throws [CopilotDeviceFlowError]: expired (code lifetime exhausted or
/// GitHub said so), denied, endpointDisabled (404/JSON error at the poll
/// endpoint), or transport.
Future<String> pollCopilotDeviceGrant({
  required CopilotDeviceGrant grant,
  required String clientId,
  required Future<void> Function(Duration delay) delay,
  void Function(String status)? onStatus,
  http.Client? client,
}) async {
  final transport = client ?? sharedProviderHttpClient();
  var interval = Duration(seconds: grant.interval) + _pollIntervalSlack;
  var waited = Duration.zero;
  while (true) {
    await delay(interval);
    waited += interval;
    if (waited.inSeconds >= grant.expiresIn) {
      throw const CopilotDeviceFlowError(
        CopilotDeviceFlowErrorKind.expired,
        'the device code expired before the authorization completed — '
        'start again',
      );
    }
    final http.Response response;
    try {
      response = await transport
          .post(
            Uri.parse(copilotDevicePollUrl),
            headers: const {'accept': 'application/json'},
            body: {
              'client_id': clientId,
              'device_code': grant.deviceCode,
              'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
            },
          )
          .timeout(effectiveProviderConnectTimeout);
    } on CopilotDeviceFlowError {
      rethrow;
    } on Object catch (error) {
      throw CopilotDeviceFlowError(
        CopilotDeviceFlowErrorKind.transport,
        'Copilot device-flow poll failed: $error',
      );
    }
    if (response.statusCode == 404) {
      throw _endpointDisabled(clientId, response.statusCode, response.body);
    }
    final body = _decodeJsonObject(response);
    if (body == null) {
      throw CopilotDeviceFlowError(
        CopilotDeviceFlowErrorKind.transport,
        'Copilot device-flow poll returned a non-JSON response '
        '(HTTP ${response.statusCode}): ${response.body.trim()}',
      );
    }
    final token = body['access_token'];
    if (token is String && token.isNotEmpty) return token;
    switch (body['error']) {
      case 'authorization_pending':
        onStatus?.call(
          'waiting for authorization... (${waited.inSeconds}s elapsed)',
        );
      case 'slow_down':
        interval += _slowDownPenalty;
      case 'expired_token':
        throw const CopilotDeviceFlowError(
          CopilotDeviceFlowErrorKind.expired,
          'the device code expired (GitHub: expired_token) — start again',
        );
      case 'access_denied':
        throw const CopilotDeviceFlowError(
          CopilotDeviceFlowErrorKind.denied,
          'the authorization was denied (GitHub: access_denied)',
        );
      case final Object other:
        throw CopilotDeviceFlowError(
          CopilotDeviceFlowErrorKind.transport,
          'Copilot device-flow poll failed: ${response.body.trim()} '
          '(error: $other)',
        );
      default:
        throw CopilotDeviceFlowError(
          CopilotDeviceFlowErrorKind.transport,
          'Copilot device-flow poll returned no token and no error: '
          '${response.body.trim()}',
        );
    }
  }
}

/// The endpoint-rejection carrier (the Phase-0 live finding: GitHub routes
/// the device endpoints but the app's flow is disabled or its id changed —
/// a 404 or a JSON error body). The message names [clientId] and points at
/// the paste-a-token fallback.
CopilotDeviceFlowError _endpointDisabled(
  String clientId,
  int status,
  String body,
) {
  return CopilotDeviceFlowError(
    CopilotDeviceFlowErrorKind.endpointDisabled,
    'GitHub rejected the Copilot device flow (HTTP $status, '
    '"${body.trim()}") for client id $clientId — the GitHub app may be '
    'disabled or its id changed; paste an existing GitHub token instead '
    '(or override the id with FA_COPILOT_CLIENT_ID)',
  );
}

/// The response body as a JSON object, or null when it is not one (HTML
/// error pages and plain-text rejections both land here).
Map<String, Object?>? _decodeJsonObject(http.Response response) {
  final Object? decoded;
  try {
    decoded = jsonDecode(response.body);
  } on Object {
    return null;
  }
  return decoded is Map<String, Object?> ? decoded : null;
}
