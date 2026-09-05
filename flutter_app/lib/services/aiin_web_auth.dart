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

/// One-click AIIN sign-in for the web build, mirroring the OpenRouter flow:
/// the app opens the authorization page in a named popup, the hosted
/// callback page posts the code back, and the coordinator finishes the
/// OAuth-proxy exchange and registers the `sk-aiin-…` API key — all from
/// the browser (auth.aiin.by and api.aiin.by send `access-control-allow-origin: *`).
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

  /// The redirect URI registered with [initiateAiinOAuth].
  final String callbackUrl;

  /// How long to wait for the callback before giving up.
  final Duration timeout;

  Completer<AiinWebCallback>? _completer;

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
  /// timeout, or a reported service error (status goes through [onStatus]).
  ///
  /// [launchFn] / [client] are injectable for tests.
  Future<AiinConnectResult?> connect({
    required String provider,
    void Function(String)? onStatus,
    http.Client? client,
    bool Function(String url)? launchFn,
  }) async {
    onStatus?.call('Opening the AIIN sign-in…');
    _completer = Completer<AiinWebCallback>();
    attachAiinOAuthLinks();
    final AiinOAuthInitiate initiate;
    try {
      initiate = await initiateAiinOAuth(
        provider: provider,
        redirectUri: callbackUrl,
        client: client,
      );
    } on AiinAuthException catch (error) {
      onStatus?.call('AIIN sign-in failed: ${error.message}');
      _reset();
      return null;
    }
    final launched = launchFn != null
        ? launchFn(initiate.authUrl)
        : launchAiinOAuthPopup(initiate.authUrl);
    if (!launched) {
      onStatus?.call('The browser blocked the sign-in popup — allow popups '
          'and try again.');
      _reset();
      return null;
    }
    final AiinWebCallback callback;
    try {
      callback = await _completer!.future.timeout(timeout);
    } on TimeoutException {
      onStatus?.call('No AIIN callback received (timeout or cancelled)');
      _reset();
      return null;
    }
    _reset();
    if (callback.code == null || callback.code!.isEmpty) {
      onStatus?.call('AIIN sign-in cancelled');
      return null;
    }
    // The proxy echoes the SERVER-issued state (initiate) into the
    // redirect — that is the value to validate against.
    if (callback.state != initiate.state) {
      onStatus?.call('AIIN sign-in callback was invalid (state mismatch)');
      return null;
    }
    return _finish(code: callback.code!, initiate: initiate, onStatus: onStatus, client: client);
  }

  Future<AiinConnectResult?> _finish({
    required String code,
    required AiinOAuthInitiate initiate,
    required void Function(String)? onStatus,
    required http.Client? client,
  }) async {
    try {
      final tokens = await exchangeAiinOAuthCode(
        code: code,
        state: initiate.state,
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

