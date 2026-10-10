// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'auth_flow.dart';

/// The mobile OAuth callback receiver (iOS/Android): the browser cannot
/// reach an on-device loopback reliably, so the flow registers the app's
/// `fah://oauth/network` deep link as `client_redirect_uri` — the service
/// proxies the provider callback there, the OS routes the link back into
/// the app, and [callback] resolves with the full URI (code + state).
///
/// Pure seam: the AppLinks stream (and the initial link, for the race
/// where the OS delivered the link before the listener attached) are
/// injected, so the receiver is fully testable on the VM.
final class DeepLinkOAuthReceiver implements OAuthCallbackReceiver {
  DeepLinkOAuthReceiver._(this._links)
    : redirectUri = Uri.parse('fah://oauth/network');

  /// Wires the receiver to a platform link stream (AppLinks on device).
  static DeepLinkOAuthReceiver bind({
    required Stream<Uri> links,
    required Uri? initialLink,
    Duration timeout = const Duration(minutes: 3),
  }) {
    final receiver = DeepLinkOAuthReceiver._(links);
    receiver._listen(initialLink, timeout);
    return receiver;
  }

  final Stream<Uri> _links;
  final Completer<Uri> _completer = Completer<Uri>();
  StreamSubscription<Uri>? _subscription;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  bool _matches(Uri uri) =>
      uri.scheme == 'fah' && uri.host == 'oauth' && uri.path == '/network';

  void _complete(Uri uri) {
    if (!_completer.isCompleted) _completer.complete(uri);
  }

  void _listen(Uri? initialLink, Duration timeout) {
    if (initialLink != null && _matches(initialLink)) {
      _complete(initialLink);
      return;
    }
    _subscription = _links.where(_matches).listen(_complete);
    // The flow must not wait on the browser forever.
    Timer(timeout, () {
      if (!_completer.isCompleted) {
        _completer.completeError(
          const AuthFlowException(
            'timed out waiting for the sign-in redirect back to the app',
          ),
        );
      }
    });
  }

  @override
  void close() {
    // Fire-and-forget: cancel futures resolve on the zone's event queue —
    // awaiting them inside a fake-async test wedges the runner.
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }
}
