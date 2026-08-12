/// Local callback server and browser flow for ChatGPT's Codex OAuth client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../providers/chatgpt_oauth.dart';
import 'openrouter_oauth_server.dart' show openBrowser;

final class ChatGptOAuthCallback {
  const ChatGptOAuthCallback({
    this.code,
    this.state,
    this.error,
    this.errorDescription,
  });

  final String? code;
  final String? state;
  final String? error;
  final String? errorDescription;
}

final class ChatGptOAuthLocalCallbackServer {
  HttpServer? _server;
  Completer<ChatGptOAuthCallback?>? _result;
  Timer? _timer;

  String? get callbackUrl {
    final server = _server;
    return server == null
        ? null
        : 'http://127.0.0.1:${server.port}/auth/callback';
  }

  Future<String> start({Duration timeout = const Duration(minutes: 5)}) async {
    await close();
    _result = Completer<ChatGptOAuthCallback?>();
    Object? lastError;
    for (final port in const [1455, 1457]) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
        break;
      } on Object catch (error) {
        lastError = error;
      }
    }
    if (_server == null) {
      throw StateError(
        'Could not bind ChatGPT OAuth callback port: $lastError',
      );
    }
    _timer = Timer(timeout, () => _complete(null));
    _server!.listen(_handle, onDone: () => _complete(null));
    return callbackUrl!;
  }

  Future<ChatGptOAuthCallback?> waitForCallback() =>
      _result?.future ?? Future.value();

  void _handle(HttpRequest request) {
    if (request.method != 'GET' || request.uri.path != '/auth/callback') {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
      return;
    }
    final parameters = request.uri.queryParameters;
    final callback = ChatGptOAuthCallback(
      code: parameters['code'],
      state: parameters['state'],
      error: parameters['error'],
      errorDescription: parameters['error_description'],
    );
    final success =
        callback.code != null &&
        callback.code!.isNotEmpty &&
        callback.error == null;
    request.response.headers.contentType = ContentType.html;
    request.response.statusCode = success
        ? HttpStatus.ok
        : HttpStatus.badRequest;
    request.response.write(
      '<!doctype html><title>${success ? 'Authorized' : 'Authorization failed'}</title>'
      '<style>body{font-family:system-ui,sans-serif;max-width:36rem;margin:5rem auto;text-align:center}</style>'
      '<h1>${success ? 'Authorized' : 'Authorization failed'}</h1>'
      '<p>${success ? 'You can close this tab and return to Fa.' : const HtmlEscape().convert(callback.errorDescription ?? callback.error ?? 'No authorization code received.')}</p>',
    );
    unawaited(request.response.close());
    _complete(callback);
  }

  void _complete(ChatGptOAuthCallback? value) {
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

Future<ChatGptOAuthCredentials?> runChatGptOAuthCliFlow({
  required void Function(String) onStatus,
  Future<bool> Function(String) openBrowserFn = openBrowser,
  Future<ChatGptOAuthCredentials> Function({
        required String code,
        required String redirectUri,
        required String verifier,
      })
      exchangeFn =
      _defaultExchange,
}) async {
  final server = ChatGptOAuthLocalCallbackServer();
  final verifier = generateChatGptPkceVerifier();
  final state = generateChatGptState();
  final redirectUri = await server.start();
  final authUrl = buildChatGptAuthorizeUrl(
    redirectUri: redirectUri,
    codeChallenge: generateChatGptPkceChallenge(verifier),
    state: state,
  );
  onStatus('listening for ChatGPT OAuth callback on $redirectUri');
  if (await openBrowserFn(authUrl.toString())) {
    onStatus('browser opened; complete authorization with ChatGPT');
  } else {
    onStatus('could not open browser automatically');
    onStatus('open this URL manually: $authUrl');
  }
  final callback = await server.waitForCallback();
  if (callback == null) {
    onStatus('no authorization callback received (timeout or cancelled)');
    return null;
  }
  if (callback.error != null) {
    onStatus(
      'ChatGPT authorization failed: ${callback.errorDescription ?? callback.error}',
    );
    return null;
  }
  if (callback.state != state ||
      callback.code == null ||
      callback.code!.isEmpty) {
    onStatus('ChatGPT authorization callback was invalid');
    return null;
  }
  try {
    final credentials = await exchangeFn(
      code: callback.code!,
      redirectUri: redirectUri,
      verifier: verifier,
    );
    onStatus('ChatGPT authorized');
    return credentials;
  } on Object catch (error) {
    onStatus('ChatGPT authorization failed: $error');
    return null;
  }
}

Future<ChatGptOAuthCredentials> _defaultExchange({
  required String code,
  required String redirectUri,
  required String verifier,
}) => exchangeChatGptAuthorizationCode(
  code: code,
  redirectUri: redirectUri,
  codeVerifier: verifier,
);
