// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// ignore_for_file: prefer_initializing_formals — named private
// parameters cannot be initializing formals in Dart.

import 'fa_network_client.dart';
import 'models.dart';

/// A failure of the OAuth sign-in flow itself (state mismatch, a callback
/// without a code, a loopback timeout). Server round-trip failures surface
/// as [FaNetworkException] instead.
final class AuthFlowException implements Exception {
  const AuthFlowException(this.message);

  /// The human-readable failure reason.
  final String message;

  @override
  String toString() => 'AuthFlowException: $message';
}

/// The ai-native.cloud OAuth sign-in flow (issue #955 iteration 3),
/// pure sequencing with the platform seam injected:
///
/// 1. `POST /api/oauth-proxy/initiate` for [provider] → the provider's
///    authorization URL + the CSRF `state`.
/// 2. [waitForCallback] opens the URL and resolves with the loopback
///    callback URI (`?code&state`) — the desktop loopback listener is the
///    production implementation; tests inject a fake.
/// 3. The callback's `state` must match the initiate state (CSRF guard).
/// 4. `POST /api/oauth-proxy/exchange` swaps the temporary code for the
///    token bundle.
final class NetworkAuthFlow {
  const NetworkAuthFlow({required FaNetworkClient client}) : _client = client;

  final FaNetworkClient _client;

  /// The loopback redirect placeholder handed to `/initiate`. The real
  /// port is only known once the loopback listener binds (ephemeral port
  /// per RFC 8252), so the listener rewrites the port inside the
  /// launched URL — the deploy allowlists any `127.0.0.1` port and the
  /// exchange takes only `code`+`state`.
  static final Uri defaultRedirectUri = Uri.parse(
    'http://127.0.0.1:0/callback',
  );

  /// Runs the flow and returns the token bundle. Throws
  /// [AuthFlowException] on a callback error/state mismatch/missing code,
  /// [FaNetworkException] on a server round-trip failure.
  Future<TokenBundle> signIn({
    required String provider,
    String clientType = 'desktop',
    String environment = 'prod',
    Uri? redirectUri,
    required Future<Uri> Function(Uri authUrl) waitForCallback,
  }) async {
    final initiated = await _client.oauthInitiate(
      provider: provider,
      redirectUri: redirectUri ?? defaultRedirectUri,
      clientType: clientType,
      environment: environment,
    );
    final callback = await waitForCallback(initiated.authUrl);
    final error = callback.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      throw AuthFlowException(
        callback.queryParameters['error_description'] ?? error,
      );
    }
    final state = callback.queryParameters['state'];
    if (state != initiated.state) {
      throw const AuthFlowException(
        'sign-in state mismatch — the callback did not come from this flow',
      );
    }
    final code = callback.queryParameters['code'];
    if (code == null || code.isEmpty) {
      throw const AuthFlowException('the sign-in callback carried no code');
    }
    return _client.oauthExchange(code: code, state: initiated.state);
  }
}
