// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'auth_flow.dart';

/// The desktop OAuth loopback listener (issue #955 iteration 3): binds an
/// ephemeral `127.0.0.1` port, opens [authUrl] in the system browser, and
/// waits for the provider to redirect to `/callback?code&state`.
///
/// The port is only known after binding, while `/initiate` already baked
/// a `redirect_uri` into [authUrl] — the listener rewrites that port in
/// the launched URL (the deploy allowlists any `127.0.0.1` port per
/// RFC 8252, and the exchange takes only `code`+`state`).
Future<Uri> waitForOAuthCallbackImpl(
  Uri authUrl, {
  Duration timeout = const Duration(minutes: 3),
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final completer = Completer<Uri>();
  final subscription = server.listen((request) {
    if (request.uri.path == '/callback') {
      if (!completer.isCompleted) completer.complete(request.uri);
      _writeCloseTabPage(request.response);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      unawaited(request.response.close());
    }
  });
  try {
    final launched = await url_launcher.launchUrl(
      _withLoopbackPort(authUrl, server.port),
      mode: url_launcher.LaunchMode.externalApplication,
    );
    if (!launched) {
      throw const AuthFlowException('could not open the browser for sign-in');
    }
    return await completer.future.timeout(
      timeout,
      onTimeout: () => throw const AuthFlowException(
        'timed out waiting for the browser sign-in callback',
      ),
    );
  } finally {
    // Fire-and-forget: this listener never runs inside testWidgets (tests
    // inject a fake waiter), but the same wedging rule applies anywhere
    // a fake event loop could be in charge.
    unawaited(subscription.cancel());
    unawaited(server.close(force: true));
  }
}

/// Replaces the port of the `redirect_uri` query parameter baked into
/// [authUrl] with the bound [port].
Uri _withLoopbackPort(Uri authUrl, int port) {
  final redirectParam = authUrl.queryParameters['redirect_uri'];
  final redirect = redirectParam != null ? Uri.tryParse(redirectParam) : null;
  if (redirect == null || redirect.port == port) return authUrl;
  final query = Map<String, String>.of(authUrl.queryParameters)
    ..['redirect_uri'] = redirect.replace(port: port).toString();
  return authUrl.replace(queryParameters: query);
}

void _writeCloseTabPage(HttpResponse response) {
  response.headers.contentType = ContentType.html;
  response.write(
    '<!doctype html><html><head><title>Signed in</title></head>'
    '<body><p>You can close this tab and return to Fa.</p>'
    '</body></html>',
  );
  unawaited(response.close());
}
