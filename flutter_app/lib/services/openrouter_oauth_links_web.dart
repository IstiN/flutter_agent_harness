// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:html' as html;

import 'package:fa/services/openrouter_oauth_coordinator.dart';

/// Listens for the `postMessage` from `https://fa1.dev/oauth/openrouter.html`
/// that carries the OpenRouter authorization code.
Future<void> attachOpenRouterOAuthLinks() async {
  html.window.onMessage.listen((event) {
    final data = event.data;
    if (data == null) return;

    String? type;
    String? code;

    if (data is Map) {
      type = data['type'] as String?;
      code = data['code'] as String?;
    } else {
      // postMessage from a same-origin JS page arrives as a native JS object
      // in dart2js, not a Dart Map. Use dynamic dispatch to read its fields.
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
  });
}
