// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:web/web.dart' as web;

/// Explicit host handoff wins, then the host's shared language choice.
/// Invalid values are ignored rather than overriding the device locale.
String? loadAppLocaleOverride(FaProductConfig config) {
  final query = Uri.parse(web.window.location.href).queryParameters['lang'];
  if (_supported(query)) return query;
  final key = config.localeStorageKey;
  if (key == null) return null;
  try {
    final stored = web.window.localStorage.getItem(key);
    if (_supported(stored)) return stored;
  } on Object {
    // Storage can be disabled by the browser; device locale still works.
  }
  return null;
}

bool _supported(String? value) => value == 'ru' || value == 'en';
