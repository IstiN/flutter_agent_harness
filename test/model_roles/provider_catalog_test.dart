// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Regression pin for the Phase 1 un-hide: the ChatGPT Codex provider must
/// stay visible across the pickers, settings screens, and `enabledProviders`
/// consumers. A refactor that drops the default `visible: true` fails here
/// instead of surfacing as a "the picker is missing chatgpt" mystery.
void main() {
  test('chatgpt spec is visible after Phase 1 un-hide', () {
    expect(providerCatalog['chatgpt']!.visible, isTrue);
    expect(enabledProviders().any((s) => s.name == 'chatgpt'), isTrue);
  });
}
