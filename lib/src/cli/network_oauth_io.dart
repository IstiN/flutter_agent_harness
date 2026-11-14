// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Loopback receiver for the desktop ai-native OAuth flow. This is the IO
/// adapter only; sequencing and CSRF validation live in `network_commands`.
library;

import 'dart:async';
import 'dart:io';

import 'network_commands.dart';
import 'openrouter_oauth_server.dart';

/// One ephemeral localhost HTTP server with a `/callback` endpoint.
final class NetworkOAuthLoopback implements NetworkOAuthCallbackReceiver {
  NetworkOAuthLoopback._(this._server, this.redirectUri) {
    _subscription = _server.listen(_handle);
  }

  final HttpServer _server;
  final _result = Completer<Uri>();
  late final StreamSubscription<HttpRequest> _subscription;
  var _closed = false;

  /// Binds an ephemeral IPv4 loopback port.
  static Future<NetworkOAuthLoopback> bind() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return NetworkOAuthLoopback._(
      server,
      Uri.parse('http://127.0.0.1:${server.port}/callback'),
    );
  }

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _result.future.timeout(
    const Duration(minutes: 3),
    onTimeout: () {
      close();
      throw TimeoutException('OAuth loopback timed out after 3 minutes');
    },
  );

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription.cancel();
    await _server.close(force: true);
  }

  void _handle(HttpRequest request) {
    final response = request.response;
    if (request.method != 'GET' || request.uri.path != '/callback') {
      response
        ..statusCode = HttpStatus.notFound
        ..headers.contentType = ContentType.text;
      response.write('Not found');
      request.drain<void>().whenComplete(() => response.close());
      return;
    }
    response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.html
      ..write(
        '''<!doctype html>
<html><head><meta charset="utf-8"><title>fa network login</title></head>
<body><h1>fa network login complete</h1>
<p>You can close this browser tab and return to the terminal.</p></body></html>''',
      );
    if (!_result.isCompleted) _result.complete(request.uri);
    request.drain<void>().whenComplete(() => response.close());
  }
}

/// Opens [authUrl] using the CLI's standard browser policy. The URL is
/// always printed, including headless/SSH sessions and failed launches.
Future<void> openNetworkAuthUrl(
  Uri authUrl, {
  required void Function(String line) onStatus,
}) => openAuthUrlWithStatus(
  url: authUrl.toString(),
  launchBrowser: shouldLaunchBrowser(),
  openBrowserFn: openBrowser,
  onStatus: onStatus,
  openedMessage: 'browser opened; finish sign-in there',
  skippedMessage: 'browser launch skipped; open the authorization URL below',
);
