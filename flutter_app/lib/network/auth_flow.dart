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

/// A bound callback receiver for the OAuth flow: the [redirectUri] is
/// handed to `/api/oauth-proxy/initiate` as `client_redirect_uri`
/// BEFORE the auth URL exists (the port is ephemeral per RFC 8252), and
/// [callback] resolves with the final `/callback?code&state` URI once the
/// browser lands back. [close] releases the listener (idempotent).
abstract interface class OAuthCallbackReceiver {
  /// The loopback URI the client registered for this flow.
  Uri get redirectUri;

  /// Resolves with the callback URI (or throws on timeout).
  Future<Uri> get callback;

  /// Tears the listener down (never awaited inside fake-async tests).
  void close();
}

/// The ai-native.cloud OAuth sign-in flow (issue #955 iteration 3),
/// pure sequencing with the platform seams injected:
///
/// 1. [startReceiver] binds the callback endpoint — the ephemeral port is
///    known HERE, so `/initiate` receives the real `client_redirect_uri`.
/// 2. `POST /api/oauth-proxy/initiate` for [provider] → the provider's
///    authorization URL + the CSRF `state`. The returned URL is opened
///    VERBATIM — its baked `redirect_uri` is the auth service's own
///    provider callback (`{BaseURL}/login/oauth2/code/<provider>`), the
///    only URI the provider's OAuth app allows; the browser finally lands
///    on our loopback via the service's proxy redirect.
/// 3. [openUrl] opens the authorization URL in the system browser.
/// 4. The callback's `state` must match the initiate state (CSRF guard).
/// 5. `POST /api/oauth-proxy/exchange` swaps the temporary code for the
///    token bundle.
final class NetworkAuthFlow {
  const NetworkAuthFlow({required FaNetworkClient client}) : _client = client;

  final FaNetworkClient _client;

  /// Runs the flow and returns the token bundle. Throws
  /// [AuthFlowException] on a callback error/state mismatch/missing code,
  /// [FaNetworkException] on a server round-trip failure.
  Future<TokenBundle> signIn({
    required String provider,
    String clientType = 'desktop',
    String environment = 'prod',
    required Future<OAuthCallbackReceiver> Function() startReceiver,
    required Future<void> Function(Uri authUrl) openUrl,
  }) async {
    final receiver = await startReceiver();
    try {
      final initiated = await _client.oauthInitiate(
        provider: provider,
        redirectUri: receiver.redirectUri,
        clientType: clientType,
        environment: environment,
      );
      await openUrl(initiated.authUrl);
      final callback = await receiver.callback;
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
      return await _client.oauthExchange(code: code, state: initiated.state);
    } finally {
      receiver.close();
    }
  }
}
