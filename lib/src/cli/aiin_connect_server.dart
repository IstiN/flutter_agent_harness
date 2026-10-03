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
  bool get succeeded => code != null && code!.isNotEmpty && error == null;
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

  Future<AiinCallback?> waitForCallback() => _result?.future ?? Future.value();

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

/// The mobile auth-session surface closed WITHOUT a callback — a user
/// cancel (iOS swipe-dismissal). Thrown by [runAiinConnectCliFlow] under
/// `cancelWhenOpenSettles`; the app's mobile branch catches it and falls
/// straight to the paste-key fallback.
final class AiinSurfaceClosedException implements Exception {
  const AiinSurfaceClosedException();

  @override
  String toString() =>
      'AiinSurfaceClosedException: the sign-in surface closed without a '
      'callback (user cancel)';
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
  required void Function(String) onStatus,
  Future<bool> Function(String) openBrowserFn = openBrowser,
  http.Client? client,
  String authBaseUrl = aiinAuthBaseUrl,
  Duration timeout = const Duration(minutes: 5),

  /// Called once the callback wait settles — when the callback lands OR
  /// the timeout/cancel path gives up — before the exchange/return. The
  /// mobile auth-session sheet dismisses itself here (a stale sheet
  /// closes too): the session does not intercept the `http://localhost`
  /// redirect (it loads the callback server for real), so the sheet must
  /// be closed programmatically to hand the user back to the app.
  /// Optional — desktop callers skip it.
  void Function()? onCallback,

  /// Treats a successful open completion before any callback as a user
  /// cancel — throws [AiinSurfaceClosedException] — instead of waiting
  /// out [timeout]. For auth-session surfaces that resolve only when the
  /// sheet CLOSES (iOS `ASWebAuthenticationSession`): a user
  /// swipe-dismissal must short-circuit to the caller's fallback, not
  /// leave dead air. Desktop browser launches resolve immediately, so
  /// they must leave this off (default false).
  bool cancelWhenOpenSettles = false,
}) async {
  final server = AiinCallbackServer();
  final redirectUri = await server.start(timeout: timeout);
  try {
    // The hosted sign-in page: AIIN lists every provider, runs the whole
    // round-trip (silent for an existing session) and redirects back with
    // the code + our state.
    final state = aiinGenerateState();
    final loginUrl = buildAiinLoginUrl(
      redirectUri: redirectUri,
      state: state,
      // `desktop` is the client_type whose redirect shape is an arbitrary
      // localhost loopback URI — the mobile apps use the same shape. There
      // is no `mobile` value in AIIN's contract (the web build sends
      // `web`), so desktop parity is deliberate here.
      clientType: 'desktop',
      authBaseUrl: authBaseUrl,
    );
    onStatus('listening for the AIIN callback on $redirectUri');
    // Arm the callback wait and the browser surface CONCURRENTLY: the
    // mobile auth session resolves its open future only when the sheet
    // CLOSES, and the sheet is dismissed through [onCallback] — awaiting
    // the open first would deadlock the mobile flow. Open FAILURES (the
    // session cannot start) surface promptly through the race instead of
    // stalling until the callback timeout.
    final callbackFuture = server.waitForCallback();
    final opened = _openAiinBrowser(
      loginUrl.toString(),
      openBrowserFn,
      onStatus,
    );
    final callback = await _firstCallbackOrOpenError(
      callbackFuture,
      opened,
      cancelWhenOpenSettles: cancelWhenOpenSettles,
    );
    onCallback?.call();
    try {
      await opened;
    } on Object {
      // Late open failure after the callback won: the flow is settling
      // and the open surface is already gone (e.g. the native side fails
      // the pending session when the dismissal tears it down). Swallow —
      // the landed callback must always settle the flow.
    }
    return await _settleAiinCallback(
      callback,
      state,
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

/// Resolves with the first of [callbackFuture] (a landed callback or the
/// timeout), an [opened] failure, or — when [cancelWhenOpenSettles] — a
/// successful [opened] completion ([AiinSurfaceClosedException]): an
/// auth-session sheet that closed WITHOUT a callback is a user cancel,
/// not a reason to wait out the callback timeout. A late open error after
/// the callback won is dropped from the race here and swallowed by the
/// caller's `await opened` — the landed callback always settles the flow.
Future<AiinCallback?> _firstCallbackOrOpenError(
  Future<AiinCallback?> callbackFuture,
  Future<void> opened, {
  required bool cancelWhenOpenSettles,
}) {
  final openError = Completer<Never>();
  final surfaceClosed = Completer<Never>();
  unawaited(
    opened.then(
      (_) {
        if (cancelWhenOpenSettles && !surfaceClosed.isCompleted) {
          surfaceClosed.completeError(const AiinSurfaceClosedException());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!openError.isCompleted) openError.completeError(error, stackTrace);
      },
    ),
  );
  openError.future.ignore();
  surfaceClosed.future.ignore();
  return Future.any([callbackFuture, openError.future, surfaceClosed.future]);
}

/// Opens the system browser, falling back to printing the URL when no
/// browser is available (headless hosts).
Future<void> _openAiinBrowser(
  String authUrl,
  Future<bool> Function(String) openBrowserFn,
  void Function(String) onStatus,
) async {
  if (await openBrowserFn(authUrl)) {
    onStatus('browser opened; sign in on the AIIN page');
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
  String expectedState, {
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
  if (callback.state != expectedState) {
    onStatus('AIIN sign-in callback was invalid (state mismatch)');
    return null;
  }
  return _finishAiinConnect(
    callback.code!,
    expectedState,
    client: client,
    authBaseUrl: authBaseUrl,
    onStatus: onStatus,
  );
}

/// Exchanges the code for JWTs and registers the durable `sk-aiin-...`
/// key. Null = a reported exchange/registration failure.
Future<AiinConnectResult?> _finishAiinConnect(
  String code,
  String state, {
  required http.Client? client,
  required String authBaseUrl,
  required void Function(String) onStatus,
}) async {
  try {
    final tokens = await exchangeAiinOAuthCode(
      code: code,
      state: state,
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
