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
    if (data is! Map) return;
    if (data['type'] != 'openrouter_oauth_code') return;
    OpenRouterOAuthCoordinator.instance.complete(data['code'] as String?);
  });
}
