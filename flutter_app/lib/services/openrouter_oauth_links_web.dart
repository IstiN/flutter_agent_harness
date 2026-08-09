// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:html' as html;

import 'package:fa/services/openrouter_oauth_coordinator.dart';

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

/// Listens for the OpenRouter authorization code delivered either by
/// `postMessage` from the callback page (Chrome/Firefox) or by
/// `BroadcastChannel` (Safari fallback, because ITP may strip `window.opener`
/// after the cross-origin OpenRouter redirect).
Future<void> attachOpenRouterOAuthLinks() async {
  html.window.onMessage.listen((event) => _completeFromData(event.data));

  try {
    final channel = html.BroadcastChannel('openrouter_oauth');
    channel.onMessage.listen((event) => _completeFromData(event.data));
  } on Object {
    // BroadcastChannel is not supported on very old browsers; the postMessage
    // path above is enough for those.
  }
}
