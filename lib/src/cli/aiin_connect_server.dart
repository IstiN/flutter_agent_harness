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

  /// Parses a redirect URL that never reached the loopback server — the
  /// `ASWebAuthenticationSession` scheme interception
  /// (`callbackScheme: 'http'`, gh-1044 AC9) hands the callback URL
  /// straight back to the caller, so the same `code`/`state`/`error`
  /// query the server would see arrives as a string instead of an HTTP
  /// request.
  factory AiinCallback.fromRedirectUrl(String url) {
    final query =
        Uri.tryParse(url)?.queryParameters ?? const <String, String>{};
    return AiinCallback(
      code: query['code'],
      state: query['state'],
      error: query['error'],
      errorDescription: query['error_description'],
    );
  }
}

/// Loopback HTTP server catching the AIIN OAuth redirect.
///
/// Dual-stack on the loopback interface (gh-1044 review): the primary
/// IPv4 listener plus a best-effort IPv6 listener on the same port, so
/// the fallback leg (an in-sheet redirect that loads the server for
/// real) is reachable no matter how the client resolves the host — a
/// `localhost` label may answer `::1`, and the literal `127.0.0.1` needs
/// the IPv4 listener. The IPv6 listener is optional: hosts without IPv6
/// loopback skip it (debugPrint) and the flow keeps working over IPv4.
final class AiinCallbackServer {
  HttpServer? _server;
  HttpServer? _server6;
  Completer<AiinCallback?>? _result;
  Timer? _timer;

  /// The host the callback URL advertises. The flow advertises the
  /// literal `127.0.0.1` on every surface (scheme interception ignores
  /// the host; the fallback leg needs an address that reaches the IPv4
  /// bind without resolver ambiguity); other values only for tests.
  String callbackHost = '127.0.0.1';

  /// The redirect URI to register with [initiateAiinOAuth]
  /// (`http://<host>:<ephemeral-port>/callback`).
  String? get callbackUrl {
    final server = _server;
    return server == null
        ? null
        : 'http://$callbackHost:${server.port}/callback';
  }

  /// Binds the loopback server and returns the redirect URI.
  Future<String> start({
    Duration timeout = const Duration(minutes: 5),
    String callbackHost = '127.0.0.1',
  }) async {
    this.callbackHost = callbackHost;
    await close();
    _result = Completer<AiinCallback?>();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _timer = Timer(timeout, () => _complete(null));
    _server!.listen(_handle, onDone: () => _complete(null));
    // Best-effort IPv6 loopback on the same port: a redirect addressed
    // `localhost` can resolve to `::1` (gh-1044 review) — the fallback
    // leg must answer there too. Optional: no IPv6, no problem.
    try {
      _server6 = await HttpServer.bind(
        InternetAddress.loopbackIPv6,
        _server!.port,
        v6Only: true,
      );
      _server6!.listen(_handle, onDone: () => _complete(null));
    } on IOException catch (error) {
      _server6 = null;
      stderr.writeln(
        '[AIIN] no IPv6 loopback listener (the fallback leg stays '
        'IPv4-only): $error',
      );
    }
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
    final server6 = _server6;
    _server = null;
    _server6 = null;
    if (server != null) await server.close(force: true);
    if (server6 != null) await server6.close(force: true);
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
/// `cancelWhenOpenSettles`; the app's mobile branch catches it and
/// surfaces the visible failure state (gh-1044 I4 — SSO is the only
/// path, never a paste sheet).
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
  /// closes too): the session intercepts the `http://` redirect
  /// (`callbackScheme: 'http'`, gh-1044 AC9) and hands the callback URL
  /// back through [interceptedCallback] instead of navigating it, so
  /// the sheet must be closed programmatically to hand the user back to
  /// the app. Optional — desktop callers skip it.
  void Function()? onCallback,

  /// Treats a successful open completion before any callback as a user
  /// cancel — throws [AiinSurfaceClosedException] — instead of waiting
  /// out [timeout]. For surfaces that resolve without a completion value
  /// (an external browser launch): when the launch future settles with no
  /// callback and no [interceptedCallback] channel, a user abandonment
  /// must short-circuit, not leave dead air. When [interceptedCallback]
  /// IS present the sheet's resolution rides it alone (its null IS the
  /// cancel) and this flag is ignored — the two signals come from the
  /// same resolution, and the open-settle path would only race the
  /// callback URL's delivery. Desktop callers leave this off (default
  /// false).
  bool cancelWhenOpenSettles = false,

  /// The host the callback URL advertises: the literal `127.0.0.1` on
  /// every surface (scheme interception ignores the host; the fallback
  /// leg needs an address that reaches the IPv4 bind without resolver
  /// ambiguity) — other values only for tests.
  String callbackHost = '127.0.0.1',

  /// The auth-session surface's completion value (gh-1044 AC9): resolves
  /// with the callback URL the native scheme interception caught
  /// (`callbackScheme: 'http'`), or null when the sheet closed without
  /// one (user cancel). When it delivers a URL the flow settles from it
  /// directly — completion no longer depends on the redirect loading the
  /// loopback server inside the sheet. The loopback server stays armed as
  /// the fallback leg (older surfaces still navigate the redirect for
  /// real); whichever leg lands first wins the race. This future is the
  /// sheet's single completion channel — the
  /// [cancelWhenOpenSettles] open-settle cancel does not apply while it
  /// exists.
  Future<String?> Function()? interceptedCallback,
}) async {
  final server = AiinCallbackServer();
  final redirectUri = await server.start(
    timeout: timeout,
    callbackHost: callbackHost,
  );
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
    final intercepted = interceptedCallback?.call();
    AiinCallback? callback;
    try {
      final (won, source) = await _firstCallbackOrOpenError(
        callbackFuture,
        opened,
        cancelWhenOpenSettles: cancelWhenOpenSettles,
        intercepted: intercepted,
      );
      callback = won;
      // gh-1044 AC2: the winning leg is answerable from the log alone —
      // interception (the fixed path) vs a real loopback hit (the
      // fallback leg) discriminates F2 from F1 without a device debugger.
      // A null callback (timeout) keeps _settleAiinCallback's message.
      if (callback != null) {
        onStatus(switch (source) {
          _AiinCallbackSource.interceptedRedirect =>
            'AIIN redirect intercepted by the sign-in sheet (callback URL '
                'returned to the flow)',
          _AiinCallbackSource.loopbackServer =>
            'AIIN callback landed on the loopback server',
        });
      }
    } on AiinSurfaceClosedException {
      onStatus(
        'the sign-in sheet closed without completing the sign-in '
        '(no callback returned — user cancel)',
      );
      rethrow;
    }
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

/// Where the winning callback came from — the gh-1044 AC2 discriminator
/// (interception vs a real loopback hit).
enum _AiinCallbackSource { loopbackServer, interceptedRedirect }

/// Resolves with the first of [callbackFuture] (a landed callback or the
/// timeout), an [intercepted] callback URL (gh-1044 AC9), an [opened]
/// failure, or — when [cancelWhenOpenSettles] — a successful [opened]
/// completion, or an [intercepted] null ([AiinSurfaceClosedException]): an
/// auth-session sheet that closed WITHOUT returning a callback URL is a
/// user cancel, not a reason to wait out the callback timeout. A late
/// open error after the callback won is dropped from the race here and
/// swallowed by the caller's `await opened` — the landed callback always
/// settles the flow.
///
/// When [intercepted] is present it is the sheet's SINGLE completion
/// channel — both the callback URL and the cancel (null) ride it — so the
/// [opened] settle never duplicates the cancel (gh-1044): the mobile
/// wrapper resolves `opened` and [intercepted] from the SAME sheet
/// resolution, and a Dart async function's `return` completes its future
/// SYNCHRONOUSLY (VM `_returnAsyncNotFuture` → `_completeWithValue`) while
/// `Completer.complete` defers its listeners to a LATER microtask — an
/// `opened`-settle cancel evaluated in that cascade would always judge
/// the pending [interceptedCallback] incomplete and steal the race from a
/// callback URL sitting in the very next microtask. With no [intercepted]
/// channel (an external browser that gives no completion value),
/// [cancelWhenOpenSettles] keeps its original meaning.
Future<(AiinCallback?, _AiinCallbackSource)> _firstCallbackOrOpenError(
  Future<AiinCallback?> callbackFuture,
  Future<void> opened, {
  required bool cancelWhenOpenSettles,
  Future<String?>? intercepted,
}) {
  final openError = Completer<Never>();
  final surfaceClosed = Completer<Never>();
  final interceptedCallback = Completer<(AiinCallback?, _AiinCallbackSource)>();
  if (intercepted != null) {
    _wireInterceptedChannel(
      intercepted: intercepted,
      openError: openError,
      surfaceClosed: surfaceClosed,
      interceptedCallback: interceptedCallback,
    );
  }
  unawaited(
    opened.then(
      (_) {
        // With an intercepted channel the sheet's resolution is reported
        // through it alone (null = user cancel) — never duplicated here.
        // See the doc comment for the scheduling asymmetry that makes the
        // duplication a lost race for the intercepted URL.
        if (cancelWhenOpenSettles &&
            intercepted == null &&
            !surfaceClosed.isCompleted &&
            !interceptedCallback.isCompleted) {
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
  return Future.any([
    callbackFuture.then(
      (callback) => (callback, _AiinCallbackSource.loopbackServer),
    ),
    openError.future,
    surfaceClosed.future,
    interceptedCallback.future,
  ]);
}

/// Arms the intercepted-callback channel's listeners (gh-1044 AC9) on the
/// shared completers of [_firstCallbackOrOpenError]: a callback URL wins
/// the race as [_AiinCallbackSource.interceptedRedirect]; a null is the
/// user cancel — [AiinSurfaceClosedException] on [surfaceClosed] — and a
/// channel error surfaces on [openError] ahead of the callback timeout
/// (the same prompt-failure contract as an open failure). Only the first
/// settle wins: every completion checks its completer first.
void _wireInterceptedChannel({
  required Future<String?> intercepted,
  required Completer<Never> openError,
  required Completer<Never> surfaceClosed,
  required Completer<(AiinCallback?, _AiinCallbackSource)> interceptedCallback,
}) {
  unawaited(
    intercepted.then(
      (url) {
        if (url != null) {
          if (!interceptedCallback.isCompleted) {
            interceptedCallback.complete((
              AiinCallback.fromRedirectUrl(url),
              _AiinCallbackSource.interceptedRedirect,
            ));
          }
          return;
        }
        // The sheet closed without returning a callback URL — a user
        // cancel (the same semantics as cancelWhenOpenSettles).
        if (!surfaceClosed.isCompleted && !interceptedCallback.isCompleted) {
          surfaceClosed.completeError(const AiinSurfaceClosedException());
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!openError.isCompleted) {
          openError.completeError(error, stackTrace);
        }
      },
    ),
  );
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
