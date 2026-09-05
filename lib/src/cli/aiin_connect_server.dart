// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Local callback server and browser flow for the AIIN (aiin.by) sign-in.
///
/// The AIIN OAuth proxy flow accepts any client redirect URI, so the server
/// binds an EPHEMERAL loopback port — no fixed-port collisions with other
/// local tools (unlike the ChatGPT Codex flow, whose registered redirect
/// pins ports 1455/1457).
library;

import 'dart:async';
import 'dart:convert' show HtmlEscape;
import 'dart:io';

import 'package:http/http.dart' as http;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'openrouter_oauth_server.dart' show openBrowser;

/// One OAuth proxy redirect caught by [AiinCallbackServer].
final class AiinCallback {
  const AiinCallback({
    this.code,
    this.state,
    this.error,
    this.errorDescription,
  });

  final String? code;
  final String? state;
  final String? error;
  final String? errorDescription;

  /// Whether the redirect carries a usable authorization code.
  bool get succeeded =>
      code != null && code!.isNotEmpty && error == null;
}

/// Loopback HTTP server catching the AIIN OAuth proxy redirect.
final class AiinCallbackServer {
  HttpServer? _server;
  Completer<AiinCallback?>? _result;
  Timer? _timer;

  /// The redirect URI to register with [initiateAiinOAuth]
  /// (`http://127.0.0.1:<ephemeral-port>/callback`).
  String? get callbackUrl {
    final server = _server;
    return server == null ? null : 'http://127.0.0.1:${server.port}/callback';
  }

  /// Binds the loopback server and returns the redirect URI.
  Future<String> start({Duration timeout = const Duration(minutes: 5)}) async {
    await close();
    _result = Completer<AiinCallback?>();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _timer = Timer(timeout, () => _complete(null));
    _server!.listen(_handle, onDone: () => _complete(null));
    return callbackUrl!;
  }

  Future<AiinCallback?> waitForCallback() =>
      _result?.future ?? Future.value();

  Future<void> _handle(HttpRequest request) async {
    if (request.method != 'GET' || request.uri.path != '/callback') {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
      return;
    }
    final callback = AiinCallback(
      code: request.uri.queryParameters['code'],
      state: request.uri.queryParameters['state'],
      error: request.uri.queryParameters['error'],
      errorDescription: request.uri.queryParameters['error_description'],
    );
    request.response.headers.contentType = ContentType.html;
    request.response.statusCode = callback.succeeded
        ? HttpStatus.ok
        : HttpStatus.badRequest;
    request.response.write(_callbackPage(callback));
    // Flush the page before _complete force-closes the server, or the
    // browser may see a truncated response.
    await request.response.close();
    _complete(callback);
  }

  void _complete(AiinCallback? value) {
    final completer = _result;
    if (completer != null && !completer.isCompleted) completer.complete(value);
    unawaited(close());
  }

  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    final server = _server;
    _server = null;
    if (server != null) await server.close(force: true);
  }
}

/// Renders the HTML page shown in the browser after the redirect.
String _callbackPage(AiinCallback callback) {
  final success = callback.succeeded;
  final title = success ? 'AIIN connected' : 'AIIN sign-in failed';
  final message = success
      ? 'You can close this tab and return to Fa.'
      : const HtmlEscape().convert(
          callback.errorDescription ??
              callback.error ??
              'No authorization code received.',
        );
  return '<!doctype html><title>$title</title>'
      '<style>body{font-family:system-ui,sans-serif;max-width:36rem;margin:5rem auto;text-align:center}</style>'
      '<h1>$title</h1><p>$message</p>';
}

/// The outcome of a completed AIIN connect flow.
final class AiinConnectResult {
  const AiinConnectResult({
    required this.apiKey,
    required this.tokens,
    required this.email,
  });

  /// The freshly registered `sk-aiin-…` API key (the durable credential).
  final AiinApiKey apiKey;

  /// The AIIN JWTs from the sign-in (kept for future silent re-auth).
  final AiinOAuthTokens tokens;

  /// The account email (from the access JWT), or null when absent — used
  /// to name the provider entry so several AIIN accounts coexist.
  final String? email;
}

/// Runs the full AIIN connect flow for CLI/desktop hosts:
///
/// 1. binds the loopback callback server (ephemeral port),
/// 2. initiates the OAuth proxy flow for [provider],
/// 3. opens the system browser at the sign-in URL ([openBrowserFn]),
/// 4. catches the redirect, exchanges the code for JWTs,
/// 5. registers an API key with the access JWT.
///
/// Returns null on timeout/cancel or a reported service error (status is
/// printed through [onStatus]); throws [AiinAuthException] never — service
/// failures surface through [onStatus] so callers can treat null as "not
/// connected".
Future<AiinConnectResult?> runAiinConnectCliFlow({
  required String provider,
  required void Function(String) onStatus,
  Future<bool> Function(String) openBrowserFn = openBrowser,
  http.Client? client,
  String authBaseUrl = aiinAuthBaseUrl,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final server = AiinCallbackServer();
  final redirectUri = await server.start(timeout: timeout);
  try {
    final initiate = await initiateAiinOAuth(
      provider: provider,
      redirectUri: redirectUri,
      client: client,
      authBaseUrl: authBaseUrl,
    );
    onStatus('listening for the AIIN callback on $redirectUri');
    await _openAiinBrowser(initiate.authUrl, provider, openBrowserFn, onStatus);
    final callback = await server.waitForCallback();
    return await _settleAiinCallback(
      callback,
      initiate,
      client: client,
      authBaseUrl: authBaseUrl,
      onStatus: onStatus,
    );
  } on AiinAuthException catch (error) {
    onStatus('AIIN sign-in failed: ${error.message}');
    return null;
  } finally {
    await server.close();
  }
}

/// Opens the system browser, falling back to printing the URL when no
/// browser is available (headless hosts).
Future<void> _openAiinBrowser(
  String authUrl,
  String provider,
  Future<bool> Function(String) openBrowserFn,
  void Function(String) onStatus,
) async {
  if (await openBrowserFn(authUrl)) {
    onStatus('browser opened; sign in with your $provider account');
  } else {
    onStatus('could not open browser automatically');
    onStatus('open this URL manually: $authUrl');
  }
}

/// Validates the caught redirect and finishes the connect. Null = the
/// callback never arrived, reported a provider error, or failed the
/// state check.
Future<AiinConnectResult?> _settleAiinCallback(
  AiinCallback? callback,
  AiinOAuthInitiate initiate, {
  required http.Client? client,
  required String authBaseUrl,
  required void Function(String) onStatus,
}) async {
  if (callback == null) {
    onStatus('no AIIN callback received (timeout or cancelled)');
    return null;
  }
  if (!callback.succeeded) {
    onStatus(
      'AIIN sign-in failed: ${callback.errorDescription ?? callback.error}',
    );
    return null;
  }
  if (callback.state != initiate.state) {
    onStatus('AIIN sign-in callback was invalid (state mismatch)');
    return null;
  }
  return _finishAiinConnect(
    callback.code!,
    initiate,
    client: client,
    authBaseUrl: authBaseUrl,
    onStatus: onStatus,
  );
}

/// Exchanges the code for JWTs and registers the durable `sk-aiin-...`
/// key. Null = a reported exchange/registration failure.
Future<AiinConnectResult?> _finishAiinConnect(
  String code,
  AiinOAuthInitiate initiate, {
  required http.Client? client,
  required String authBaseUrl,
  required void Function(String) onStatus,
}) async {
  try {
    final tokens = await exchangeAiinOAuthCode(
      code: code,
      state: initiate.state,
      client: client,
      authBaseUrl: authBaseUrl,
    );
    onStatus('AIIN authorized - registering an API key...');
    final apiKey = await createAiinApiKey(
      accessToken: tokens.accessToken,
      client: client,
    );
    return AiinConnectResult(
      apiKey: apiKey,
      tokens: tokens,
      email: aiinJwtEmail(tokens.accessToken),
    );
  } on AiinAuthException catch (error) {
    onStatus('AIIN setup failed: ${error.message}');
    return null;
  }
}
