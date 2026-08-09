// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A one-shot localhost HTTP server that captures the OpenRouter OAuth
/// callback for desktop builds.
///
/// Binds to `127.0.0.1:0`, serves a small success page, and completes with the
/// authorization code from the first `GET /?code=...` request. The server
/// closes itself after the code is captured or after a timeout.
final class OpenRouterOAuthCallbackServer {
  /// Creates a server that will bind to an ephemeral localhost port.
  OpenRouterOAuthCallbackServer();

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
    final url = callbackUrl!;

    _timeoutTimer = Timer(timeout, () {
      final completer = _codeCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(null);
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
            'try again in the app.',
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
        : '<p>${const HtmlEscape().convert(message ?? 'Unknown error')}</p>';
    response.write(
      '<!DOCTYPE html><html><head><title>$title</title>'
      '<style>body{font-family:system-ui,sans-serif;max-width:600px;margin:4rem auto;text-align:center;}'
      'h1{color:${success ? '#16a34a' : '#dc2626'};}</style></head>'
      '<body><h1>$title</h1>$body</body></html>',
    );
    unawaited(response.close());
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
