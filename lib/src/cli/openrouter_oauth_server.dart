/// IO-backed helpers for the OpenRouter OAuth PKCE flow: a localhost HTTP
/// callback server and a cross-platform browser launcher.
///
/// This file lives under `lib/src/cli/` because it needs `dart:io`; the pure
/// Dart PKCE math and exchange code live in `lib/src/providers/openrouter_oauth.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../providers/openrouter_oauth.dart';

/// A one-shot HTTP server that captures the OpenRouter OAuth callback on
/// localhost.
///
/// Binds to `127.0.0.1:0` (any free port), serves a small success/error page,
/// and completes with the authorization code from the first `GET /?code=...`
/// request. The server closes itself automatically after the code is captured
/// or after a timeout.
final class OpenRouterOAuthLocalCallbackServer {
  /// Creates a server that will bind to an ephemeral localhost port.
  OpenRouterOAuthLocalCallbackServer();

  HttpServer? _server;
  Completer<String?>? _codeCompleter;
  Timer? _timeoutTimer;

  /// The callback URL to pass to OpenRouter, or null before [start].
  String? get callbackUrl {
    final server = _server;
    if (server == null) return null;
    return 'http://${server.address.host}:${server.port}/';
  }

  /// Starts the server and returns the URL OpenRouter should redirect to.
  ///
  /// [timeout] caps how long the server waits for the callback; after it
  /// elapses the server closes and [waitForCode] completes with null.
  Future<String> start({Duration timeout = const Duration(minutes: 5)}) async {
    await _closeExisting();
    _codeCompleter = Completer<String?>();

    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final server = _server!;
    final url = 'http://127.0.0.1:${server.port}/';

    _timeoutTimer = Timer(timeout, () {
      if (_codeCompleter case final c? when !c.isCompleted) {
        c.complete(null);
      }
      unawaited(close());
    });

    server.listen(_handleRequest, onDone: _onDone);

    return url;
  }

  void _handleRequest(HttpRequest request) {
    final code = request.uri.queryParameters['code'];
    final error = request.uri.queryParameters['error'];

    if (code != null && code.isNotEmpty) {
      _complete(code);
      _writePage(request.response, success: true);
    } else if (error != null && error.isNotEmpty) {
      _complete(null);
      _writePage(
        request.response,
        success: false,
        message: request.uri.queryParameters['error_description'] ?? error,
      );
    } else {
      _writePage(
        request.response,
        success: false,
        message:
            'Missing authorization code. Please close this page and '
            'try again in the terminal.',
        statusCode: 400,
      );
    }
  }

  void _complete(String? code) {
    final completer = _codeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(code);
    }
    unawaited(close());
  }

  void _onDone() {
    final completer = _codeCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(null);
    }
  }

  void _writePage(
    HttpResponse response, {
    required bool success,
    String? message,
    int statusCode = 200,
  }) {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.html;
    final title = success ? 'Authorized' : 'Authorization failed';
    final body = success
        ? '<p>You can close this tab and return to Fa.</p>'
        : '<p>${_htmlEscape(message ?? 'Unknown error')}</p>';
    response.write(
      '<!DOCTYPE html><html><head><title>$title</title>'
      '<style>body{font-family:system-ui,sans-serif;max-width:600px;margin:4rem auto;text-align:center;}'
      'h1{color:${success ? '#16a34a' : '#dc2626'};}</style></head>'
      '<body><h1>$title</h1>$body</body></html>',
    );
    unawaited(response.close());
  }

  String _htmlEscape(String text) {
    return const HtmlEscape().convert(text);
  }

  /// Waits for the callback and returns the authorization code, or null on
  /// timeout/error.
  Future<String?> waitForCode() async {
    final completer = _codeCompleter;
    if (completer == null) return null;
    return completer.future;
  }

  /// Closes the server and cancels the timeout.
  Future<void> close() async {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;
    final server = _server;
    _server = null;
    if (server != null) await server.close();
  }

  Future<void> _closeExisting() async {
    final server = _server;
    if (server != null) {
      _server = null;
      await server.close();
    }
  }
}

/// Opens [url] in the user's default browser.
///
/// Uses `open` on macOS, `xdg-open` on Linux, and `start` on Windows. Returns
/// true when the launch command was invoked (not whether the browser actually
/// opened).
Future<bool> openBrowser(String url) async {
  String executable;
  List<String> args;
  if (Platform.isMacOS) {
    executable = 'open';
    args = [url];
  } else if (Platform.isLinux) {
    executable = 'xdg-open';
    args = [url];
  } else if (Platform.isWindows) {
    executable = 'start';
    args = ['', url];
  } else {
    return false;
  }
  try {
    final result = await Process.run(executable, args);
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}

/// Runs the full automatic OAuth flow for the CLI: starts a localhost server,
/// opens the browser, waits for the callback, and exchanges the code.
///
/// [onStatus] receives human-readable status lines ("open this URL", "waiting",
/// etc.). [openBrowserFn] and [exchangeFn] are injectable for tests.
Future<OpenRouterOAuthKey?> runOpenRouterOAuthCliFlow({
  required void Function(String) onStatus,
  Future<bool> Function(String) openBrowserFn = openBrowser,
  Future<OpenRouterOAuthKey> Function({
        required String code,
        required String codeVerifier,
        String? label,
      })
      exchangeFn =
      _defaultExchange,
  String keyLabel = openRouterDefaultKeyLabel,
}) async {
  final verifier = generateOpenRouterCodeVerifier();
  final challenge = generateOpenRouterCodeChallenge(verifier);
  final server = OpenRouterOAuthLocalCallbackServer();

  final callbackUrl = await server.start();
  onStatus('listening for OAuth callback on $callbackUrl');

  final authUrl = buildOpenRouterAuthUrl(
    codeChallenge: challenge,
    callbackUrl: callbackUrl,
    keyLabel: keyLabel,
  );

  final opened = await openBrowserFn(authUrl.toString());
  if (opened) {
    onStatus('browser opened; complete authorization on the OpenRouter page');
  } else {
    onStatus('could not open browser automatically');
    onStatus('open this URL manually: $authUrl');
  }

  final code = await server.waitForCode();
  if (code == null || code.isEmpty) {
    onStatus('no authorization code received (timeout or cancelled)');
    return null;
  }
  onStatus('authorization code received, exchanging for API key...');

  try {
    final key = await exchangeFn(
      code: code,
      codeVerifier: verifier,
      label: keyLabel,
    );
    onStatus('OpenRouter authorized');
    return key;
  } on Exception catch (e) {
    onStatus('authorization failed: $e');
    return null;
  }
}

Future<OpenRouterOAuthKey> _defaultExchange({
  required String code,
  required String codeVerifier,
  String? label,
}) => exchangeOpenRouterCode(code, codeVerifier: codeVerifier, label: label);
