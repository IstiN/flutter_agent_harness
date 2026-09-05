// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:fa/services/aiin_oauth_web_stub.dart'
    if (dart.library.html) 'package:fa/services/aiin_oauth_web_impl.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// The hosted callback page handing the OAuth code back to the app
/// (postMessage / BroadcastChannel / localStorage — see the page source).
const aiinWebCallbackUrl = 'https://fa1.dev/oauth/aiin.html';

/// One-click AIIN sign-in for the web build, mirroring the OpenRouter flow.
/// The app opens the HOSTED AIIN sign-in page
/// (`auth.aiin.by/login?client_redirect_uri=…&state=…`) in a named popup —
/// the page lists every enabled provider (Apple once AIIN enables it),
/// runs the whole OAuth round-trip on their side (silent pass-through for
/// an existing AIIN session) and redirects back to our callback page with
/// `code` + our state. The coordinator validates the state (generated
/// CLIENT-side — the CSRF boundary now lives with us), then finishes the
/// exchange and registers the `sk-aiin-…` API key — all from the browser.
///
/// The popup is opened SYNCHRONOUSLY (before any await) — after an `await`
/// the browser loses the user-gesture context and silently blocks
/// `window.open`. The blank popup is navigated to the sign-in page
/// immediately.
///
/// The connect never leaves the page (no reload), so the caller keeps its
/// context and continues with model pick + provider save right after.
final class AiinWebAuthCoordinator {
  AiinWebAuthCoordinator({
    this.callbackUrl = aiinWebCallbackUrl,
    this.timeout = const Duration(minutes: 5),
  });

  /// The shared coordinator with the Fa defaults.
  static final instance = AiinWebAuthCoordinator();

  /// The redirect URI the hosted page redirects back to (allowlisted on
  /// the AIIN service).
  final String callbackUrl;

  /// How long to wait for the callback before giving up.
  final Duration timeout;

  Completer<AiinWebCallback>? _completer;

  /// Why the last [connect] returned null (null when it succeeded or has
  /// not run). Carries the service message verbatim for redirect-block
  /// detection ("client_redirect_uri is not allowed").
  String? lastFailure;

  /// Completes the in-flight flow with the delivered callback. Called by
  /// the web link listeners; safe to call with `null` (cancel).
  void complete({String? code, String? state}) {
    final completer = _completer;
    if (completer == null || completer.isCompleted) return;
    completer.complete(AiinWebCallback(code: code, state: state));
    closeAiinOAuthPopup();
  }

  void _reset() {
    _completer = null;
  }

  /// Runs the full web connect. Returns null on cancel, popup block,
  /// timeout, or a reported exchange failure (status goes through
  /// [onStatus]).
  ///
  /// [openFn] / [navigateFn] / [client] / [timeout] are injectable for
  /// tests.
  Future<AiinConnectResult?> connect({
    void Function(String)? onStatus,
    http.Client? client,
    bool Function()? openFn,
    void Function(String url)? navigateFn,
    Duration? timeout,
  }) async {
    lastFailure = null;
    onStatus?.call('Opening the AIIN sign-in…');
    // Inside the gesture: open the blank popup NOW, navigate it right
    // away (Safari breaks the gesture after any await).
    final opened = openFn != null ? openFn() : openAiinOAuthPopup();
    if (!opened) {
      lastFailure = 'popup_blocked';
      onStatus?.call('The browser blocked the sign-in popup — allow popups '
          'and try again.');
      return null;
    }
    // The state is OURS (one-time random) — the hosted page echoes it
    // through the whole round-trip and we verify it on the callback.
    final state = aiinGenerateState();
    final loginUrl = buildAiinLoginUrl(
      redirectUri: callbackUrl,
      state: state,
      clientType: 'web',
    ).toString();
    _completer = Completer<AiinWebCallback>();
    attachAiinOAuthLinks();
    if (navigateFn != null) {
      navigateFn(loginUrl);
    } else {
      navigateAiinOAuthPopup(loginUrl);
    }
    final AiinWebCallback callback;
    try {
      callback = await _completer!.future.timeout(timeout ?? this.timeout);
    } on TimeoutException {
      lastFailure = 'timeout';
      onStatus?.call('No AIIN callback received (timeout or cancelled)');
      _reset();
      return null;
    }
    _reset();
    if (callback.code == null || callback.code!.isEmpty) {
      lastFailure = 'cancelled';
      onStatus?.call('AIIN sign-in cancelled');
      return null;
    }
    if (callback.state != state) {
      lastFailure = 'state_mismatch';
      onStatus?.call('AIIN sign-in callback was invalid (state mismatch)');
      return null;
    }
    return _finish(
      code: callback.code!,
      state: state,
      onStatus: onStatus,
      client: client,
    );
  }

  Future<AiinConnectResult?> _finish({
    required String code,
    required String state,
    required void Function(String)? onStatus,
    required http.Client? client,
  }) async {
    try {
      final tokens = await exchangeAiinOAuthCode(
        code: code,
        state: state,
        client: client,
      );
      onStatus?.call('AIIN authorized — registering an API key…');
      final apiKey = await createAiinApiKey(
        accessToken: tokens.accessToken,
        client: client,
      );
      return AiinConnectResult(
        apiKey: apiKey,
        tokens: tokens,
        email: aiinJwtEmail(tokens.accessToken),
      );
    } on AiinAuthException catch (error) {
      lastFailure = error.message;
      onStatus?.call('AIIN setup failed: ${error.message}');
      return null;
    }
  }
}

/// One delivered OAuth callback from the hosted page.
final class AiinWebCallback {
  const AiinWebCallback({this.code, this.state});

  final String? code;
  final String? state;
}
