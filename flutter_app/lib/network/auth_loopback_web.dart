// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;

import 'auth_flow.dart';
import 'oauth_callback_message.dart';

/// The browser OAuth receiver: the sandbox cannot bind a loopback HTTP
/// server, so the sign-in runs in a popup window instead. The popup
/// navigates the SAME authorization URL as the desktop flow; the auth
/// service's proxy redirect lands it back on our origin
/// (`{origin}/oauth/callback?code=…&state=…`). The grant reaches this
/// receiver two ways (issue #1117): the `/oauth/callback` page posts it
/// to `window.opener` / broadcasts it — the path that works even when
/// this window cannot read the popup (extension/Office pane embeds,
/// throttled poll timers) — and the same-origin location poll remains
/// as the fast path.
///
/// Popup blockers key off the transient user activation of the click
/// that started the flow: `NetworkAuthFlow.signIn` awaits the
/// `/initiate` round-trip BEFORE the auth URL exists, and a
/// `window.open` after that await is rejected as not user-initiated
/// (the opener is a null-backed `WindowBase` — touching any member
/// throws "Attempting to use a null window in Window.open"). So the
/// popup is opened EAGERLY in [WebOAuthReceiver.bind] — still inside the
/// button's gesture — on `about:blank`, and [openAuthUrlImpl] only
/// navigates the already-open window once the auth URL arrives.
final class WebOAuthReceiver implements OAuthCallbackReceiver {
  WebOAuthReceiver._() : redirectUri = _originCallback();

  static Uri _originCallback() =>
      Uri.parse('${html.window.location.origin}/oauth/callback');

  /// Window features for the sign-in popup: a centered narrow dialog
  /// without browser chrome.
  static const String _popupFeatures =
      'width=560,height=720,menubar=no,toolbar=no,status=no';

  /// The most recently bound receiver — [openAuthUrlImpl] navigates the
  /// popup it opened here. A single sign-in runs at a time (the dialog
  /// serializes providers through one busy slot).
  static WebOAuthReceiver? _active;

  /// Binds the receiver and EAGERLY opens the `about:blank` popup while
  /// the click's transient activation is still valid. Nothing listens
  /// yet — [trackPopup] starts the poll once the popup is navigated to
  /// the auth URL.
  static Future<WebOAuthReceiver> bind({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final receiver = WebOAuthReceiver._();
    _active = receiver;
    receiver._popup = _tryOpenPopup('about:blank', _popupFeatures);
    // The callback page hands the grant back via postMessage /
    // BroadcastChannel (issue #1117) — the only channel that works when
    // this window cannot same-origin-read the popup (extension and
    // Office pane embeds) or its poll timers are throttled.
    receiver._messages = html.window.onMessage.listen(receiver._onMessage);
    try {
      receiver._channel = html.BroadcastChannel(faOAuthBroadcastChannel)
        ..onMessage.listen(receiver._onMessage);
    } on Object {
      // Very old browsers; the postMessage path covers them.
    }
    receiver._timeout = Timer(timeout, () {
      if (!receiver._completer.isCompleted) {
        receiver._completer.completeError(
          const AuthFlowException(
            'timed out waiting for the browser sign-in callback',
          ),
        );
      }
    });
    return receiver;
  }

  /// Opens [url] in a popup, returning null (never throwing) when the
  /// browser blocked it — a blocked popup reports itself as a null-backed
  /// `WindowBase` whose member access throws.
  static html.WindowBase? _tryOpenPopup(String url, String features) {
    try {
      final popup = html.window.open(url, 'fa_oauth', features);
      return _isUsable(popup) ? popup : null;
    } on Object {
      return null;
    }
  }

  /// Whether [popup] is a real, open window: a null-backed `WindowBase`
  /// (blocked popup) throws on ANY member access, so probe defensively.
  static bool _isUsable(html.WindowBase? popup) {
    if (popup == null) return false;
    try {
      return !(popup.closed ?? true);
    } on Object {
      return false;
    }
  }

  final Completer<Uri> _completer = Completer<Uri>();
  Timer? _poll;
  Timer? _timeout;
  StreamSubscription<html.MessageEvent>? _messages;
  html.BroadcastChannel? _channel;
  html.WindowBase? _popup;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  /// Polls [popup] until the proxy redirect lands it on our origin (the
  /// location read THROWS while the popup is still on the provider's
  /// cross-origin pages — that throw IS the not-yet signal), the user
  /// closes it, or the flow times out. Same-origin fast path only: the
  /// callback page's postMessage hand-off covers the cross-origin cases
  /// via [_onMessage].
  void trackPopup(html.WindowBase popup) {
    _poll = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (!_isUsable(popup)) {
        if (!_completer.isCompleted) {
          _completer.completeError(
            const AuthFlowException('the sign-in window was closed'),
          );
        }
        return;
      }
      try {
        final location = popup.location as html.Location?;
        final href = location?.href;
        if (href != null &&
            href.startsWith(html.window.location.origin) &&
            (Uri.parse(href).queryParameters.containsKey('code') ||
                Uri.parse(href).queryParameters.containsKey('error'))) {
          _completeGrant(Uri.parse(href));
        }
      } on Object {
        // Cross-origin until the redirect lands — keep polling; the
        // callback page's message delivers the grant instead.
      }
    });
  }

  /// Handles a callback-page hand-off (postMessage or BroadcastChannel):
  /// foreign/undecodable messages and untrusted origins are ignored; a
  /// trusted grant completes the flow with the same callback URI shape
  /// the same-origin poll would have produced.
  void _onMessage(html.MessageEvent event) {
    if (_completer.isCompleted) return;
    final message = decodeOAuthCallbackMessage(event.data);
    if (message == null) return;
    if (!isTrustedCallbackOrigin(event.origin, html.window.location.origin)) {
      return;
    }
    _completeGrant(message.toUri(event.origin));
  }

  /// Completes the flow with [callbackUri] exactly once: stops polling
  /// and closes the popup — including from the message path, where the
  /// popup may sit cross-origin on the callback page but is still a
  /// window this page opened (`popup.close()` is allowed for those).
  void _completeGrant(Uri callbackUri) {
    if (_completer.isCompleted) return;
    _poll?.cancel();
    _poll = null;
    final popup = _popup;
    if (popup != null && _isUsable(popup)) {
      try {
        popup.close();
      } on Object {
        // Already gone — nothing to clean up.
      }
    }
    _completer.complete(callbackUri);
  }

  @override
  void close() {
    _poll?.cancel();
    _timeout?.cancel();
    unawaited(_messages?.cancel());
    _messages = null;
    try {
      _channel?.close();
    } on Object {
      // Already gone.
    }
    _channel = null;
    // Abandoned flows (initiate failed, timeout, …) must not leave a
    // stray blank popup behind; a completed flow already closed its own.
    final popup = _popup;
    if (popup != null && _isUsable(popup)) {
      try {
        popup.close();
      } on Object {
        // Already gone — nothing to clean up.
      }
    }
    _popup = null;
    if (_active == this) _active = null;
  }
}

/// Binds the web receiver (production seam for the auth flow).
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverImpl() =>
    WebOAuthReceiver.bind();

/// Navigates the eager popup [WebOAuthReceiver.bind] opened to the
/// provider authorization URL. Navigating an already-open window needs
/// no user activation, so the `/initiate` round-trip between the click
/// and this call is safe. When the eager open was blocked (no gesture
/// context at bind time), retries a direct open — the transient
/// activation may still be alive — before giving up.
Future<void> openAuthUrlImpl(Uri authUrl) async {
  final receiver = WebOAuthReceiver._active;
  final eager = receiver?._popup;
  if (eager != null && WebOAuthReceiver._isUsable(eager)) {
    try {
      eager.location.href = authUrl.toString();
    } on Object {
      // Fall through to the retry below.
      receiver?._popup = null;
    }
    if ((receiver?._popup) != null) {
      receiver?.trackPopup(eager);
      return;
    }
  }
  final popup = WebOAuthReceiver._tryOpenPopup(
    authUrl.toString(),
    WebOAuthReceiver._popupFeatures,
  );
  if (popup == null) {
    throw const AuthFlowException(
      'the sign-in popup was blocked by the browser',
    );
  }
  receiver?._popup = popup;
  receiver?.trackPopup(popup);
}
