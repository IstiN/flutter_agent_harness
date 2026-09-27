// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:html' as html;

import 'auth_flow.dart';

/// The browser OAuth receiver: the sandbox cannot bind a loopback HTTP
/// server, so the sign-in runs in a popup window instead. The popup
/// navigates the SAME authorization URL as the desktop flow; the auth
/// service's proxy redirect lands it back on our origin
/// (`{origin}/oauth/callback?code=…&state=…`) — same-origin, so this
/// frame may read its location and finish the flow without an app
/// restart.
final class WebOAuthReceiver implements OAuthCallbackReceiver {
  WebOAuthReceiver._()
    : redirectUri = Uri.parse('${html.window.location.origin}/oauth/callback');

  /// The most recently bound receiver — [openAuthUrlImpl] attaches the
  /// popup it opens here. A single sign-in runs at a time (the dialog
  /// serializes providers through one busy slot).
  static WebOAuthReceiver? _active;

  /// Binds the receiver. Nothing listens yet — [trackPopup] starts the
  /// poll once the popup exists.
  static Future<WebOAuthReceiver> bind({
    Duration timeout = const Duration(minutes: 3),
  }) async {
    final receiver = WebOAuthReceiver._();
    _active = receiver;
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

  final Completer<Uri> _completer = Completer<Uri>();
  Timer? _poll;
  Timer? _timeout;

  @override
  final Uri redirectUri;

  @override
  Future<Uri> get callback => _completer.future;

  /// Polls [popup] until the proxy redirect lands it on our origin (the
  /// location read THROWS while the popup is still on the provider's
  /// cross-origin pages — that throw IS the not-yet signal), the user
  /// closes it, or the flow times out.
  void trackPopup(html.WindowBase popup) {
    _poll = Timer.periodic(const Duration(milliseconds: 300), (_) {
      if (popup.closed ?? false) {
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
          popup.close();
          if (!_completer.isCompleted) _completer.complete(Uri.parse(href));
        }
      } on Object {
        // Cross-origin until the redirect lands — keep polling.
      }
    });
  }

  @override
  void close() {
    _poll?.cancel();
    _timeout?.cancel();
    _active = null;
  }
}

/// Binds the web receiver (production seam for the auth flow).
Future<OAuthCallbackReceiver> startOAuthCallbackReceiverImpl() =>
    WebOAuthReceiver.bind();

/// Opens the provider authorization URL in a centered popup. A full-tab
/// navigation would tear the Flutter app down mid-flow; the popup keeps
/// it alive and returns same-origin where [WebOAuthReceiver.trackPopup]
/// can observe the callback.
Future<void> openAuthUrlImpl(Uri authUrl) async {
  final popup = html.window.open(
    authUrl.toString(),
    'fa_oauth',
    'width=560,height=720,menubar=no,toolbar=no,status=no',
  );
  // A blocked popup reports itself closed immediately; a live one does
  // not (dart:html types [html.window.open] non-nullable, so the null
  // signal has to be read off `closed` instead).
  if (popup.closed ?? false) {
    throw const AuthFlowException(
      'the sign-in popup was blocked by the browser',
    );
  }
  WebOAuthReceiver._active?.trackPopup(popup);
}
