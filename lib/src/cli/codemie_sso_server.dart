/// Local callback server and browser flow for CodeMie SSO login.
///
/// Unlike fixed-port OAuth apps, CodeMie bakes the callback port into the
/// login URL (`/v1/auth/login/<port>`), so the server binds a RANDOM free
/// port and the URL is built afterwards.
library;

import 'dart:async';
import 'dart:io';

import '../providers/codemie_sso.dart';
import 'openrouter_oauth_server.dart'
    show
        authorizationUrlPrefix,
        defaultBrowserLaunchPolicy,
        openAuthUrlWithStatus,
        openBrowser;

final class CodeMieSsoCallbackServer {
  HttpServer? _server;
  Completer<String?>? _result;
  Timer? _timer;

  /// The bound port (null before [start]).
  int? get port => _server?.port;

  /// Starts the server on a random free loopback port; resolves the port.
  Future<int> start({Duration timeout = const Duration(minutes: 5)}) async {
    await close();
    _result = Completer<String?>();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _timer = Timer(timeout, () => _complete(null));
    _server!.listen(_handle, onDone: () => _complete(null));
    return port!;
  }

  /// Resolves the raw `token` query parameter of the callback (null on
  /// timeout/cancel).
  Future<String?> waitForToken() => _result?.future ?? Future.value();

  void _handle(HttpRequest request) {
    final token = request.uri.queryParameters['token'];
    final success = token != null && token.isNotEmpty;
    request.response.headers.contentType = ContentType.html;
    request.response.statusCode = success
        ? HttpStatus.ok
        : HttpStatus.badRequest;
    request.response.write(
      '<!doctype html><title>${success ? 'Authorized' : 'Authorization failed'}</title>'
      '<style>body{font-family:system-ui,sans-serif;max-width:36rem;margin:5rem auto;text-align:center}</style>'
      '<h1>${success ? 'Authorized' : 'Authorization failed'}</h1>'
      '<p>${success ? 'You can close this tab and return to Fa.' : 'No token parameter in the callback.'}</p>',
    );
    request.response.close().then((_) {
      if (success) {
        _complete(token);
      }
      // A tokenless hit (favicon, probe) keeps the server waiting.
    });
  }

  void _complete(String? value) {
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

/// Runs the CodeMie SSO login: starts the callback server, opens (or
/// prints) the organization's login URL, waits for the token, and decodes
/// it into [CodeMieSsoCredentials]. Returns null on cancel/timeout/failure.
///
/// The authorization URL is printed in EVERY outcome (gh-1450) — launch
/// attempted, failed, skipped (a `false` [shouldOpenBrowserFn]: the
/// `--no-browser` flag / `FA_NO_BROWSER` env / headless auto-detect), and
/// timeout. [openBrowserFn], [shouldOpenBrowserFn] and [timeout] are
/// injectable for tests.
Future<CodeMieSsoCredentials?> runCodeMieSsoCliFlow({
  required String codeMieUrl,
  required void Function(String) onStatus,
  Future<bool> Function(String) openBrowserFn = openBrowser,
  bool Function() shouldOpenBrowserFn = defaultBrowserLaunchPolicy,
  Duration timeout = const Duration(minutes: 5),
}) async {
  final server = CodeMieSsoCallbackServer();
  final port = await server.start(timeout: timeout);
  final ssoUrl = buildCodeMieSsoUrl(codeMieUrl, port);
  onStatus('listening for the CodeMie SSO callback on port $port');
  await openAuthUrlWithStatus(
    url: ssoUrl,
    launchBrowser: shouldOpenBrowserFn(),
    openBrowserFn: openBrowserFn,
    onStatus: onStatus,
    openedMessage: 'browser opened; complete the CodeMie sign-in',
  );
  final token = await () async {
    // The CodeMie page often signs in BY ITSELF (existing browser session →
    // instant redirect) — wait patiently with a live status line, and bail
    // only after a generous timeout instead of hanging forever.
    onStatus(
      'waiting for the CodeMie SSO callback (the page may sign in by '
      'itself)…',
    );
    final wait = timeout;
    final statusTimer = Timer.periodic(const Duration(seconds: 15), (t) {
      onStatus('still waiting for the SSO callback… (${t.tick * 15}s)');
    });
    try {
      return await server.waitForToken().timeout(wait, onTimeout: () => null);
    } finally {
      statusTimer.cancel();
    }
  }();
  if (token == null) {
    onStatus('no SSO callback received (timeout or cancelled)');
    // Last-chance rescue (gh-1450 AC4): the URL one more time, as the
    // final line a returning user can still act on.
    onStatus('$authorizationUrlPrefix$ssoUrl');
    return null;
  }
  try {
    final cookies = decodeCodeMieSsoToken(token);
    final credentials = CodeMieSsoCredentials(
      cookies: cookies,
      apiUrl: codeMieApiBase(codeMieUrl),
      expiresAt: deriveCodeMieExpiresAt(cookies),
    );
    if (credentials.authToken.isEmpty) {
      onStatus('CodeMie SSO callback carried no cookies');
      return null;
    }
    onStatus('CodeMie authorized');
    return credentials;
  } on FormatException catch (error) {
    onStatus('CodeMie SSO failed: ${error.message}');
    return null;
  }
}
