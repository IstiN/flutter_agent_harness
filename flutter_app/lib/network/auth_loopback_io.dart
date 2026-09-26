// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'auth_flow.dart';

/// The desktop OAuth loopback receiver (issue #955 iteration 3): binds an
/// ephemeral `127.0.0.1` port BEFORE the flow starts — the port goes into
/// `/api/oauth-proxy/initiate` as `client_redirect_uri` (allowlisted at any
/// port per RFC 8252), and the provider's authorization URL returned by the
/// service is opened VERBATIM (its baked `redirect_uri` is the service's
/// own provider callback — rewriting it is a Google
/// `redirect_uri_mismatch` 400).
final class LoopbackOAuthReceiver implements OAuthCallbackReceiver {
  LoopbackOAuthReceiver._(this._server)
    : redirectUri = Uri.parse('http://127.0.0.1:${_server.port}/callback');

  /// Binds the loopback listener on an ephemeral port.
  static Future<LoopbackOAuthReceiver> bind({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final receiver = LoopbackOAuthReceiver._(server);
    receiver._listen(timeout);
    return receiver;
  }

  final HttpServer _server;
  final Completer<Uri> _completer = Completer<Uri>();
  StreamSubscription<HttpRequest>? _subscription;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  void _listen(Duration timeout) {
    _subscription = _server.listen((request) {
      if (request.uri.path == '/callback') {
        if (!_completer.isCompleted) _completer.complete(request.uri);
        _writeCloseTabPage(request.response);
      } else {
        request.response.statusCode = HttpStatus.notFound;
        unawaited(request.response.close());
      }
    });
    // The flow must not wait on the browser forever.
    Timer(timeout, () {
      if (!_completer.isCompleted) {
        _completer.completeError(
          const AuthFlowException(
            'timed out waiting for the browser sign-in callback',
          ),
        );
      }
    });
  }

  @override
  void close() {
    // Fire-and-forget: cancel/close futures resolve on the zone's event
    // queue — awaiting them inside a fake-async test wedges the runner.
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    unawaited(_server.close(force: true));
  }
}

/// Binds the loopback receiver (production seam for the auth flow).
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverImpl() =>
    LoopbackOAuthReceiver.bind();

/// Opens [authUrl] in the system browser (production seam for the flow).
Future<void> openAuthUrlImpl(Uri authUrl) async {
  final launched = await url_launcher.launchUrl(
    authUrl,
    mode: url_launcher.LaunchMode.externalApplication,
  );
  if (!launched) {
    throw const AuthFlowException('could not open the browser for sign-in');
  }
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
