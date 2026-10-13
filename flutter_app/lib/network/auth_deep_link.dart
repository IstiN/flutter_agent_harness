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
///
/// The initial-link ordering lives in [bindWithInitialLink], not in the
/// caller: the stream subscription must attach BEFORE `getInitialLink()`
/// is awaited, or a link delivered in between is dropped (broadcast
/// streams drop events with no listener) and the flow hangs until the
/// timeout.
final class DeepLinkOAuthReceiver implements OAuthCallbackReceiver {
  DeepLinkOAuthReceiver._(this._links)
    : redirectUri = Uri.parse('fah://oauth/network');

  /// Wires the receiver to a platform link stream (AppLinks on device).
  ///
  /// For the production ordering (subscribe, THEN check the initial
  /// link) use [bindWithInitialLink]; this constructor's [initialLink]
  /// check exists for tests and callers that already hold the initial
  /// link.
  static DeepLinkOAuthReceiver bind({
    required Stream<Uri> links,
    required Uri? initialLink,
    Duration timeout = const Duration(minutes: 3),
  }) {
    final receiver = DeepLinkOAuthReceiver._(links);
    receiver._listen(initialLink, timeout);
    return receiver;
  }

  /// Binds the receiver and then checks the initial link — in THAT
  /// order. `AppLinks.uriLinkStream` is a broadcast-style stream: a link
  /// delivered while no listener is attached (e.g. the OS fires
  /// `onNewIntent` during a warm resume while the platform-channel
  /// `getInitialLink()` call is still in flight) is dropped, and
  /// `getInitialLink()` returns null on a warm resume — so the callback
  /// would be missed and the flow would wait out the full timeout.
  /// Subscribing first closes that window; a link arriving on both paths
  /// is deduped by [complete]'s `isCompleted` guard.
  static Future<DeepLinkOAuthReceiver> bindWithInitialLink({
    required Stream<Uri> links,
    required Future<Uri?> Function() getInitialLink,
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final receiver = DeepLinkOAuthReceiver.bind(
      links: links,
      initialLink: null, // checked below, after the listener is attached
      timeout: timeout,
    );
    Uri? initial;
    try {
      initial = await getInitialLink();
    } on Object {
      // Best-effort: the stream listener is the primary path.
      initial = null;
    }
    if (initial != null && receiver.matches(initial)) {
      receiver.complete(initial);
    }
    return receiver;
  }

  final Stream<Uri> _links;
  final Completer<Uri> _completer = Completer<Uri>();
  StreamSubscription<Uri>? _subscription;
  Timer? _timer;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  /// The link predicate: which URIs answer this flow. Mirrors the
  /// platform registrations — Android routes `pathPrefix="/network"`
  /// links here, iOS registers the bare `fah` scheme (no filtering) —
  /// so `/network` and any sub-path match: every link the OS delivers
  /// into the app must be answered, never silently ignored.
  bool matches(Uri uri) =>
      uri.scheme == 'fah' &&
      uri.host == 'oauth' &&
      (uri.path == '/network' || uri.path.startsWith('/network/'));

  /// Completes the flow with [uri] when it matches — a no-op once the
  /// callback already completed (a link delivered on both the stream and
  /// the initial-link path is deduped here).
  void complete(Uri uri) {
    if (matches(uri)) _complete(uri);
  }

  void _complete(Uri uri) {
    if (!_completer.isCompleted) _completer.complete(uri);
  }

  void _listen(Uri? initialLink, Duration timeout) {
    if (initialLink != null && matches(initialLink)) {
      _complete(initialLink);
      return;
    }
    _subscription = _links.where(matches).listen(_complete);
    // The flow must not wait on the browser forever.
    _timer = Timer(timeout, () {
      _timer = null;
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
    _timer?.cancel();
    _timer = null;
    // Fire-and-forget: cancel futures resolve on the zone's event queue —
    // awaiting them inside a fake-async test wedges the runner.
    final subscription = _subscription;
    _subscription = null;
    if (subscription != null) unawaited(subscription.cancel());
  }
}
