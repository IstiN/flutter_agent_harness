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
import 'pi_mode.dart' show isTruthyEnvValue;

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

/// The env var that skips the automatic browser launch of the OAuth/SSO
/// login flows (gh-1450). Truthy per [isTruthyEnvValue] — the same
/// convention as `FA_NO_FORMAT`.
const noBrowserEnvVar = 'FA_NO_BROWSER';

/// The consistent prefix of the authorization-URL output line (gh-1450):
/// every family flow prints `$authorizationUrlPrefix<url>` in EVERY
/// outcome (launch attempted, launch failed, launch skipped, timeout), so
/// the line is greppable and the URL always copyable.
const authorizationUrlPrefix = 'authorization URL: ';

/// The status line printed when a flow skips the automatic browser launch
/// (the `--no-browser` flag, a truthy `FA_NO_BROWSER`, or the
/// headless/remote auto-detect). The [authorizationUrlPrefix] line always
/// follows it.
const browserLaunchSkippedMessage =
    'browser launch skipped; open the authorization URL manually';

/// Whether the current session looks headless or remote (gh-1450): no
/// graphical display on Linux, an SSH session marker, or a non-interactive
/// stdout. Such sessions cannot show a browser window the user controls —
/// exactly the incident's setting (the launch "succeeds" into a browser
/// the user never sees) — so flows skip the automatic launch and print the
/// authorization URL prominently instead.
///
/// [environment]/[stdoutHasTerminal]/[isLinux] are injectable seams for
/// tests; production resolves them from `Platform.environment`,
/// `stdout.hasTerminal`, and `Platform.isLinux`.
bool isHeadlessOrRemoteSession({
  Map<String, String>? environment,
  bool? stdoutHasTerminal,
  bool? isLinux,
}) {
  String? value(String name) {
    final v = (environment ?? Platform.environment)[name]?.trim();
    return v == null || v.isEmpty ? null : v;
  }

  if (isLinux ?? Platform.isLinux) {
    // Linux: a graphical display is mandatory for a visible browser.
    if (value('DISPLAY') == null && value('WAYLAND_DISPLAY') == null) {
      return true;
    }
  }
  if (value('SSH_TTY') != null || value('SSH_CONNECTION') != null) {
    return true;
  }
  return !(stdoutHasTerminal ?? stdout.hasTerminal);
}

/// Whether an OAuth/SSO flow may auto-launch the system browser (gh-1450).
///
/// Precedence: an explicit [noBrowserFlag] (`--no-browser`) beats the
/// truthy `FA_NO_BROWSER` env var, which beats the headless/remote
/// auto-detect ([isHeadlessOrRemoteSession]). `false` means the flow skips
/// the launch ([openBrowserFn] is never called) and prints the
/// authorization URL prominently instead — the URL is never suppressed.
bool shouldLaunchBrowser({
  bool noBrowserFlag = false,
  Map<String, String>? environment,
  bool? stdoutHasTerminal,
  bool? isLinux,
}) {
  if (noBrowserFlag) return false;
  if (isTruthyEnvValue(
    (environment ?? Platform.environment)[noBrowserEnvVar],
  )) {
    return false;
  }
  return !isHeadlessOrRemoteSession(
    environment: environment,
    stdoutHasTerminal: stdoutHasTerminal,
    isLinux: isLinux,
  );
}

/// The default launch-policy resolver the OAuth/SSO flows use: resolves
/// [shouldLaunchBrowser] from the real process environment and stdout.
bool defaultBrowserLaunchPolicy() => shouldLaunchBrowser();

/// Runs the browser-launch step shared by every OAuth/SSO CLI flow
/// (gh-1450): prints the skip/opened/could-not-open status line, then
/// ALWAYS the consistent `authorization URL:` line — the URL is a
/// first-class output line in every outcome, because a launch that exited
/// 0 says nothing about which browser (or whether any) opened. A throwing
/// [openBrowserFn] degrades to the failure branch and still prints the URL.
///
/// [openedMessage] is the flow's success hint (kept verbatim from the
/// pre-gh-1450 texts); [skippedMessage] overrides
/// [browserLaunchSkippedMessage].
Future<void> openAuthUrlWithStatus({
  required String url,
  required bool launchBrowser,
  required Future<bool> Function(String) openBrowserFn,
  required void Function(String) onStatus,
  required String openedMessage,
  String skippedMessage = browserLaunchSkippedMessage,
}) async {
  var opened = false;
  if (launchBrowser) {
    try {
      opened = await openBrowserFn(url);
    } on Object {
      opened = false;
    }
  }
  if (!launchBrowser) {
    onStatus(skippedMessage);
  } else if (opened) {
    onStatus(openedMessage);
  } else {
    onStatus('could not open browser automatically');
  }
  onStatus('$authorizationUrlPrefix$url');
}

/// Opens [url] in the user's default browser.
///
/// Uses `open` on macOS, `xdg-open` on Linux, and `start` on Windows.
///
/// The result means "launch ATTEMPTED" (the command was invoked and exited
/// 0), never "a browser window opened": SSH, headless, and
/// wrong-default-profile sessions report true without anything the user
/// can see. Callers must therefore never gate the authorization URL on
/// this result — the OAuth/SSO flows print the URL in every outcome
/// (gh-1450); this boolean only chooses the accompanying hint line.
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
/// [onStatus] receives human-readable status lines ("authorization URL",
/// "waiting", etc.). [openBrowserFn], [exchangeFn], [shouldOpenBrowserFn]
/// and [timeout] are injectable for tests. The authorization URL is printed
/// in every outcome (gh-1450); a `false` [shouldOpenBrowserFn] skips the
/// launch entirely (the `--no-browser` flag / `FA_NO_BROWSER` env /
/// headless auto-detect precedence resolves upstream).
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
  bool Function() shouldOpenBrowserFn = defaultBrowserLaunchPolicy,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final verifier = generateOpenRouterCodeVerifier();
  final challenge = generateOpenRouterCodeChallenge(verifier);
  final server = OpenRouterOAuthLocalCallbackServer();

  final callbackUrl = await server.start(timeout: timeout);
  onStatus('listening for OAuth callback on $callbackUrl');

  final authUrl = buildOpenRouterAuthUrl(
    codeChallenge: challenge,
    callbackUrl: callbackUrl,
    keyLabel: keyLabel,
  );

  await openAuthUrlWithStatus(
    url: authUrl.toString(),
    launchBrowser: shouldOpenBrowserFn(),
    openBrowserFn: openBrowserFn,
    onStatus: onStatus,
    openedMessage:
        'browser opened; complete authorization on the OpenRouter page',
  );

  final code = await server.waitForCode();
  if (code == null || code.isEmpty) {
    onStatus('no authorization code received (timeout or cancelled)');
    onStatus('$authorizationUrlPrefix$authUrl');
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
