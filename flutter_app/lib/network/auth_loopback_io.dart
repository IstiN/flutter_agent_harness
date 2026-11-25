// ignore_for_file: prefer_initializing_formals — named private
// parameters cannot be initializing formals in Dart.

// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/services.dart' show PlatformException;
import 'package:url_launcher/url_launcher.dart' as url_launcher;

import 'package:fa/services/openrouter_oauth_links_io.dart'
    show oauthDeepLinkRouter, sharedOAuthAppLinks;

import '../services/provider_auth_surface.dart';
import 'auth_deep_link.dart';
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
  Timer? _timer;

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
    _timer = Timer(timeout, () {
      _timer = null;
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
    _timer?.cancel();
    _timer = null;
    // Fire-and-forget: cancel/close futures resolve on the zone's event
    // queue — awaiting them inside a fake-async test wedges the runner.
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
    unawaited(_server.close(force: true));
  }
}

/// Callback receiver backed by iOS `ASWebAuthenticationSession` via the
/// shared `fah/web_auth_session` channel (the same system-browser auth sheet
/// used by ChatGPT / CodeMie / AIIN).
///
/// Because `ASWebAuthenticationSession` runs as an in-app sheet rather than
/// hopping out to external Safari, the Flutter process stays in the
/// foreground (no NSURLSession `-1005` socket drop on resume, no UIScene
/// deep-link routing race), shares Safari's cookies/passkeys, and delivers
/// the intercepted `fah://oauth/network?code=...&state=...` redirect directly
/// back to Dart.
final class WebAuthSessionOAuthReceiver implements OAuthCallbackReceiver {
  WebAuthSessionOAuthReceiver({
    required Future<String?> Function(Uri authUrl, String callbackScheme)
    authenticate,
    required Future<void> Function() cancel,
    Uri? redirectUri,
  }) : _authenticate = authenticate,
       _cancel = cancel,
       redirectUri = redirectUri ?? Uri.parse('fah://oauth/network');

  final Future<String?> Function(Uri authUrl, String callbackScheme)
  _authenticate;
  final Future<void> Function() _cancel;
  final Completer<Uri> _completer = Completer<Uri>();
  bool _closed = false;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  /// Presents the system auth sheet for [authUrl] and completes [callback]
  /// with the intercepted redirect URI.
  Future<void> present(Uri authUrl) async {
    if (_closed) return;
    try {
      final raw = await _authenticate(authUrl, redirectUri.scheme);
      if (_completer.isCompleted) return;
      if (raw == null || raw.isEmpty) {
        _completer.completeError(
          const AuthFlowException('sign-in was cancelled'),
        );
        return;
      }
      final uri = Uri.tryParse(raw);
      if (uri == null || !isNetworkOAuthDeepLink(uri)) {
        _completer.completeError(
          const AuthFlowException('sign-in returned an unexpected callback'),
        );
        return;
      }
      _completer.complete(uri);
    } on PlatformException catch (e) {
      if (_completer.isCompleted) return;
      _completer.completeError(
        AuthFlowException(e.message ?? 'could not open sign-in session'),
      );
    } on Object catch (e) {
      if (_completer.isCompleted) return;
      _completer.completeError(AuthFlowException('sign-in failed: $e'));
    }
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    if (_activeIosSessionReceiver == this) _activeIosSessionReceiver = null;
    unawaited(_cancel());
  }
}

/// The active iOS [WebAuthSessionOAuthReceiver] awaiting [openAuthUrlImpl]
/// (mirrors `WebOAuthReceiver._active` on web): [startOAuthCallbackReceiverImpl]
/// binds it so `/api/oauth-proxy/initiate` receives `fah://oauth/network`,
/// and [openAuthUrlImpl] presents the `ASWebAuthenticationSession` sheet.
WebAuthSessionOAuthReceiver? _activeIosSessionReceiver;

Future<String?> _invokeIosWebAuthSession(Uri authUrl, String callbackScheme) =>
    systemAuthSessionChannel.invokeMethod<String>('authenticate', {
      'url': authUrl.toString(),
      'callbackScheme': callbackScheme,
    });

Future<void> _cancelIosWebAuthSession() async {
  try {
    await systemAuthSessionChannel.invokeMethod<void>('cancel');
  } on Object {
    // Best-effort: the sheet may already be dismissed.
  }
}

/// Binds the receiver (production seam for the auth flow).
///
/// - **iOS**: `ASWebAuthenticationSession` via the shared
///   `fah/web_auth_session` channel (same mechanism as ChatGPT/CodeMie/AIIN).
/// - **Android**: `fah://oauth/network` deep-link callback via `AppLinks`.
/// - **Desktop**: RFC 8252 loopback server.
@visibleForTesting
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverForPlatform({
  required bool isIOS,
  required bool isAndroid,
  Future<String?> Function(Uri authUrl, String callbackScheme)? iosAuthenticate,
  Future<void> Function()? iosCancel,
}) async {
  if (isIOS) {
    final receiver = WebAuthSessionOAuthReceiver(
      authenticate: iosAuthenticate ?? _invokeIosWebAuthSession,
      cancel: iosCancel ?? _cancelIosWebAuthSession,
    );
    _activeIosSessionReceiver = receiver;
    return receiver;
  }
  if (isAndroid) {
    // The shared `fah://oauth/*` router owns the only AppLinks
    // subscription (issue #2395); a callback the OS delivered before this
    // registration replays from the router's buffer.
    return DeepLinkOAuthReceiver.bindWithRouter(oauthDeepLinkRouter);
  }
  return LoopbackOAuthReceiver.bind();
}

/// Binds the receiver (production seam for the auth flow).
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverImpl() =>
    startOAuthCallbackReceiverForPlatform(
      isIOS: Platform.isIOS,
      isAndroid: Platform.isAndroid,
    );

/// Reads the link that launched a fresh mobile process. Desktop boots do not
/// touch AppLinks; retrieval is best-effort because boot must never block on
/// a platform-channel failure.
Future<Uri?> getOAuthInitialLinkImpl() async {
  if (!Platform.isIOS && !Platform.isAndroid) return null;
  try {
    return await sharedOAuthAppLinks.getInitialLink();
  } on Object {
    return null;
  }
}

/// Opens [authUrl] in the system browser (production seam for the flow).
///
/// On iOS, when [startOAuthCallbackReceiverImpl] armed a
/// [WebAuthSessionOAuthReceiver], presents the in-app
/// `ASWebAuthenticationSession` sheet instead of hopping out to Safari.
Future<void> openAuthUrlImpl(Uri authUrl) async {
  final iosReceiver = _activeIosSessionReceiver;
  if (iosReceiver != null) {
    unawaited(iosReceiver.present(authUrl));
    return;
  }
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
