// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:async';
import 'dart:convert';
import 'dart:html' as html;

import 'package:fa/services/openrouter_oauth_coordinator.dart';

/// Storage key used by the callback page as a last-resort fallback.
const _storageKey = 'openrouter_oauth_code';

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
