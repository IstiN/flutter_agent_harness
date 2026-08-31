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

  group('catalogDefaultModelId', () {
    test('zai defaults to the coding endpoint flagship', () {
      expect(catalogDefaultModelId('zai'), 'glm-5.3');
    });

    test('dial has no universal default', () {
      expect(catalogDefaultModelId('dial'), isNull);
    });
  });

  group('envPreconfiguredProvider', () {
    ProviderSpec? pick(Map<String, String> env) =>
        envPreconfiguredProvider((name) => env[name]);

    test('ZAI_API_KEY alone activates zai', () {
      final spec = pick({'ZAI_API_KEY': 'key'});
      expect(spec?.name, 'zai');
      expect(spec?.kind, 'zai');
      expect(spec?.defaultBaseUrl, 'https://api.z.ai/api/coding/paas/v4');
    });

    test('catalog order wins when several keys are set', () {
      expect(
        pick({'ANTHROPIC_API_KEY': 'a', 'ZAI_API_KEY': 'z'})?.name,
        'anthropic',
      );
      // OPENAI_API_KEY is openrouter's fallback name: openrouter precedes
      // the openai spec in the catalog.
      expect(pick({'OPENAI_API_KEY': 'o'})?.name, 'openrouter');
    });

    test('DIAL_API_KEY alone activates nothing (no default model id)', () {
      expect(pick({'DIAL_API_KEY': 'd'}), isNull);
    });

    test('an empty env value is ignored', () {
      expect(pick({'ZAI_API_KEY': ''}), isNull);
    });

    test('no keys means no pick', () {
      expect(pick(const {}), isNull);
    });
  });
}
