// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:fa/services/aiin_web_auth.dart';

html.WindowBase? _aiinOAuthPopup;

/// Opens a blank NAMED popup synchronously — this MUST run inside the tap
/// handler: after any `await` the browser loses the user-gesture context
/// and silently blocks `window.open`. The coordinator navigates the blank
/// popup to the authorization URL once the server-side initiate resolves.
///
/// Returns false when the browser blocked the popup (`window.open` null).
bool openAiinOAuthPopup() {
  _aiinOAuthPopup?.close();
  _aiinOAuthPopup = html.window.open(
    'about:blank',
    'aiin_oauth',
    'width=520,height=720,scrollbars=yes,resizable=yes',
  );
  return _aiinOAuthPopup != null;
}

/// Navigates the blank popup to [url] (same-origin about:blank → auth page).
void navigateAiinOAuthPopup(String url) {
  try {
    _aiinOAuthPopup?.location.href = url;
  } on Object {
    // The popup was closed by the user before the initiate resolved.
  }
}

/// Closes the AIIN OAuth popup, if any.
void closeAiinOAuthPopup() {
  try {
    _aiinOAuthPopup?.close();
  } on Object {
    // Ignore cross-origin or already-closed errors.
  }
  _aiinOAuthPopup = null;
}

/// Extracts `{type, code, state, error}` from a postMessage/BroadcastChannel
/// payload (JS objects arrive as native objects in dart2js, not Dart Maps).
(Map<String, String?>, String type)? _decodePayload(Object? data) {
  if (data == null) return null;
  String type;
  String? code;
  String? state;
  String? error;
  try {
    final dynamic js = data;
    type = js['type'] as String? ?? '';
    code = js['code'] as String?;
    state = js['state'] as String?;
    error = js['error'] as String?;
  } on Object {
    return null;
  }
  return ({'code': code, 'state': state, 'error': error}, type);
}

/// Routes a delivered payload into the coordinator.
void _completeFromData(Object? data) {
  final decoded = _decodePayload(data);
  if (decoded == null || decoded.$2 != 'aiin_oauth_code') return;
  AiinWebAuthCoordinator.instance
      .complete(code: decoded.$1['code'], state: decoded.$1['state']);
}

/// Starts the localStorage fallback poll (older browsers where neither
/// postMessage nor BroadcastChannel survives the redirect).
Timer _startStoragePolling() {
  void check() {
    try {
      final raw = html.window.localStorage['aiin_oauth_code'];
      if (raw == null || raw.isEmpty) return;
      html.window.localStorage.remove('aiin_oauth_code');
      final dynamic decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['type'] != 'aiin_oauth_code') return;
      final ts = decoded['ts'];
      if (ts is num) {
        final ageMs = DateTime.now().millisecondsSinceEpoch - ts.toInt();
        if (ageMs < 0 || ageMs > 90 * 1000) return;
      }
      AiinWebAuthCoordinator.instance.complete(
        code: decoded['code'] as String?,
        state: decoded['state'] as String?,
      );
    } on Object {
      // Ignore parsing or storage-access errors.
    }
  }

  final timer = Timer.periodic(const Duration(milliseconds: 500), (_) => check());
  check();
  return timer;
}

bool _linksAttached = false;

/// Listens for the authorization code delivered by the callback page:
/// postMessage (Chrome/Firefox), BroadcastChannel (Safari fallback), or
/// localStorage polling (older browsers). Idempotent.
void attachAiinOAuthLinks() {
  if (_linksAttached) return;
  _linksAttached = true;
  html.window.onMessage.listen((event) => _completeFromData(event.data));
  try {
    final channel = html.BroadcastChannel('aiin_oauth');
    channel.onMessage.listen((event) => _completeFromData(event.data));
  } on Object {
    // Very old browsers; the other two paths cover them.
  }
  _startStoragePolling();
}
