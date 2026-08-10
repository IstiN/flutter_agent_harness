// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:fa/services/openrouter_oauth_coordinator.dart';

/// Storage key used by the callback page as a last-resort fallback.
const _storageKey = 'openrouter_oauth_code';

/// Prefix for persisting the PKCE verifier keyed by OAuth `state`.
const _verifierPrefix = 'openrouter_oauth_verifier_';

/// Maximum age of a stored code (in seconds) that we will still accept.
const _storageMaxAgeSeconds = 90;

/// Extracts the OpenRouter authorization code from a JS object or Dart Map
/// delivered by `postMessage` or `BroadcastChannel`.
void _completeFromData(Object? data) {
  if (data == null) return;

  String? type;
  String? code;

  if (data is Map) {
    type = data['type'] as String?;
    code = data['code'] as String?;
  } else {
    // Messages from JS arrive as native objects in dart2js, not Dart Maps.
    // Use dynamic dispatch to read the fields.
    try {
      final dynamic jsData = data;
      type = jsData['type'] as String?;
      code = jsData['code'] as String?;
    } on Object {
      return;
    }
  }

  if (type != 'openrouter_oauth_code') return;
  OpenRouterOAuthCoordinator.instance.complete(code);
}

/// Polls `localStorage` for a code written by the callback page.
///
/// This is a last-resort fallback for browsers where both `postMessage` and
/// `BroadcastChannel` fail (older Safari, cross-origin partitioning, etc.).
/// The callback page writes a JSON object with `code`, `error`, and `ts`.
void _startStoragePolling() {
  Timer? timer;
  void check() {
    try {
      final raw = html.window.localStorage[_storageKey];
      if (raw == null || raw.isEmpty) return;
      html.window.localStorage.remove(_storageKey);

      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final type = decoded['type'] as String?;
      if (type != 'openrouter_oauth_code') return;

      final ts = decoded['ts'];
      if (ts is num) {
        final ageMs = DateTime.now().millisecondsSinceEpoch - ts.toInt();
        if (ageMs < 0 || ageMs > _storageMaxAgeSeconds * 1000) return;
      }

      final code = decoded['code'] as String?;
      OpenRouterOAuthCoordinator.instance.complete(code);
      timer?.cancel();
    } on Object {
      // Ignore parsing or storage-access errors.
    }
  }

  timer = Timer.periodic(const Duration(milliseconds: 500), (_) => check());
  // Run an immediate check in case the code was written before the listener
  // started.
  check();
}

/// Persists the PKCE verifier keyed by OAuth `state` for the redirect flow.
///
/// Mobile Safari/PWAs cannot reliably return the code through a popup, so the
/// verifier is stored locally before the browser is opened and looked up when
/// OpenRouter redirects back to the app URL.
void storeOpenRouterOAuthVerifier(String state, String verifier) {
  try {
    html.window.localStorage['$_verifierPrefix$state'] = verifier;
  } on Object {
    // Storage may be unavailable in private mode.
  }
}

/// If the app was launched from an OpenRouter redirect, exchanges the code
/// for an API key and returns it.
///
/// Returns `null` when there is no code in the URL, the verifier is missing,
/// or the exchange failed.
Future<String?> completeOpenRouterOAuthFromRedirect() async {
  try {
    final params = Uri.parse(html.window.location.href).queryParameters;
    final code = params['code'];
    final error = params['error'];
    final state = params['state'];
    if (code == null || code.isEmpty) {
      if (error != null && error.isNotEmpty) {
        // Surface a clear message without crashing boot.
        OpenRouterOAuthCoordinator.instance.complete(null);
      }
      return null;
    }

    String? verifier;
    if (state != null && state.isNotEmpty) {
      final key = '$_verifierPrefix$state';
      verifier = html.window.localStorage[key];
      html.window.localStorage.remove(key);
    }
    if (verifier == null || verifier.isEmpty) {
      return null;
    }

    // Strip the OAuth query parameters from the URL so a reload does not
    // re-trigger the flow.
    final cleaned = Uri.parse(
      html.window.location.href,
    ).replace(queryParameters: {});
    html.window.history.replaceState(null, '', cleaned.toString());

    final key = await exchangeOpenRouterCode(code, codeVerifier: verifier);
    return key.key;
  } on Object {
    return null;
  }
}

/// Listens for the OpenRouter authorization code delivered either by
/// `postMessage` from the callback page (Chrome/Firefox), by
/// `BroadcastChannel` (Safari fallback, because ITP may strip `window.opener`
/// after the cross-origin OpenRouter redirect), or by `localStorage` polling
/// for older browsers.
Future<void> attachOpenRouterOAuthLinks() async {
  html.window.onMessage.listen((event) => _completeFromData(event.data));

  try {
    final channel = html.BroadcastChannel('openrouter_oauth');
    channel.onMessage.listen((event) => _completeFromData(event.data));
  } on Object {
    // BroadcastChannel is not supported on very old browsers; the postMessage
    // and localStorage paths above cover those.
  }

  _startStoragePolling();
}
