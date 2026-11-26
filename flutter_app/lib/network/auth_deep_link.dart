// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:fa/network/auth_flow.dart';
import 'package:fa/services/oauth_deep_link_router.dart';

/// Whether [uri] is the network OAuth callback registered on iOS/Android.
bool isNetworkOAuthDeepLink(Uri uri) =>
    uri.scheme == 'fah' &&
    uri.host == 'oauth' &&
    (uri.path == '/network' || uri.path.startsWith('/network/'));

/// The mobile OAuth callback receiver (iOS/Android): the browser cannot
/// reach an on-device loopback reliably, so the flow registers the app's
/// `fah://oauth/network` deep link as `client_redirect_uri` — the service
/// proxies the provider callback there, the OS routes the link back into
/// the app, and [callback] resolves with the full URI (code + state).
///
/// Links arrive through the shared [OAuthDeepLinkRouter] (issue #2395):
/// the receiver never touches the AppLinks stream itself. A link the OS
/// delivered BEFORE [bindWithRouter] registered (cold-start race) is
/// replayed by the router at registration time.
final class DeepLinkOAuthReceiver implements OAuthCallbackReceiver {
  DeepLinkOAuthReceiver._(this._router)
    : redirectUri = Uri.parse('fah://oauth/network');

  final OAuthDeepLinkRouter _router;

  /// Registers the receiver on [router] and starts the flow timeout.
  ///
  /// Production: `bindWithRouter(oauthDeepLinkRouter)` from the Android
  /// branch of the auth flow. A callback buffered on the router (delivered
  /// before this registration — the cold-start race) replays here
  /// synchronously inside [OAuthDeepLinkRouter.register] into the
  /// PRE-ARRIVAL slot, not into [callback]: the flow checks its state
  /// after initiate and answers only a matching pre-arrival, so a dead
  /// attempt's replayed callback can never fail a later flow.
  static DeepLinkOAuthReceiver bindWithRouter(
    OAuthDeepLinkRouter router, {
    Duration timeout = const Duration(minutes: 3),
  }) {
    final receiver = DeepLinkOAuthReceiver._(router);
    receiver._binding = true;
    router.register(
      OAuthDeepLinkRoute(
        flow: _flow,
        matches: receiver.matches,
        onLink: receiver.complete,
      ),
    );
    receiver._binding = false;
    // The flow must not wait on the browser forever.
    receiver._timer = Timer(timeout, () {
      receiver._timer = null;
      if (!receiver._completer.isCompleted) {
        receiver._completer.completeError(
          const AuthFlowException(
            'timed out waiting for the sign-in redirect back to the app',
          ),
        );
      }
    });
    return receiver;
  }

  static const _flow = 'network';

  final Completer<Uri> _completer = Completer<Uri>();
  Timer? _timer;

  /// Set while [bindWithRouter] registers on the router: the register
  /// call replays buffered links synchronously, and those land in the
  /// pre-arrival slot instead of completing the flow.
  bool _binding = false;
  Uri? _preArrived;

  @override
  Uri? get preArrivedCallback => _preArrived;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  /// The link predicate: which URIs answer this flow. Mirrors the
  /// platform registrations — Android routes `pathPrefix="/network"`
  /// links here, iOS registers the bare `fah` scheme (no filtering) —
  /// so `/network` and any sub-path match: every link the OS delivers
  /// into the app must be answered, never silently ignored.
  bool matches(Uri uri) => isNetworkOAuthDeepLink(uri);

  /// Completes the flow with [uri] when it matches. During
  /// [bindWithRouter]'s registration the router's replay lands in the
  /// PRE-ARRIVAL slot instead — a link that outlived its flow must not
  /// complete a later one (the flow state-checks the slot after
  /// initiate). A live dispatch completes the callback — a no-op once
  /// already completed (a link delivered twice is deduped here).
  void complete(Uri uri) {
    if (!matches(uri)) return;
    if (_binding) {
      _preArrived ??= uri;
      return;
    }
    _complete(uri);
  }

  void _complete(Uri uri) {
    if (!_completer.isCompleted) _completer.complete(uri);
  }

  @override
  void close() {
    _timer?.cancel();
    _timer = null;
    _router.unregister(_flow);
  }
}
