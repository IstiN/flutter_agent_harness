// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// Regression pin for the Phase 1 un-hide: the ChatGPT Codex provider must
/// stay visible across the pickers, settings screens, and `enabledProviders`
/// consumers. A refactor that drops the default `visible: true` fails here
/// instead of surfacing as a "the picker is missing chatgpt" mystery.
///
/// The ceiling groups pin issue #273's per-family output caps: the catalog
/// specs' blanket `maxTokens: 16384` clamps modern Claude models, so
/// resolution is config override > Claude ceiling table > provider default.
void main() {
  test('chatgpt spec is visible after Phase 1 un-hide', () {
    expect(providerCatalog['chatgpt']!.visible, isTrue);
    expect(enabledProviders().any((s) => s.name == 'chatgpt'), isTrue);
  });

  group('resolveModelMaxOutputTokens (UT-ceilings, AC2)', () {
    test('exact catalogued versions pin their documented cap', () {
      expect(resolveModelMaxOutputTokens('claude-opus-4-5'), 64000);
      expect(resolveModelMaxOutputTokens('claude-sonnet-4-6'), 128000);
      expect(resolveModelMaxOutputTokens('claude-haiku-4-5'), 64000);
      expect(resolveModelMaxOutputTokens('claude-sonnet-3-5'), 8192);
      // Version read from before the family token.
      expect(resolveModelMaxOutputTokens('claude-3-opus'), 4096);
    });

    test('uncatalogued versions fall to the nearest-lower minor', () {
      // 4.9 is past 4.8 — rides the largest catalogued ≤ it.
      expect(resolveModelMaxOutputTokens('claude-opus-4-9'), 128000);
      // 4.7 misses; sonnet falls back to 4.6's cap.
      expect(resolveModelMaxOutputTokens('claude-sonnet-4-7'), 128000);
      // Nothing catalogued at or below 2.9.
      expect(resolveModelMaxOutputTokens('claude-opus-2-9'), 128000);
    });

    test('unknown Claude model takes the conservative fallback', () {
      expect(resolveModelMaxOutputTokens('claude-lambda-9'), 128000);
    });

    test('non-Claude ids miss the table (null = provider default)', () {
      expect(resolveModelMaxOutputTokens('gpt-4o'), isNull);
      expect(resolveModelMaxOutputTokens('glm-5.3-flash'), isNull);
      expect(resolveModelMaxOutputTokens('kimi-k2'), isNull);
    });

    test('id shapes: dates, dots, scopes, underscores, pre-family', () {
      expect(resolveModelMaxOutputTokens('claude-opus-4-5-20251101'), 64000);
      expect(resolveModelMaxOutputTokens('claude-opus-4.5'), 64000);
      expect(resolveModelMaxOutputTokens('anthropic/claude-opus-4.5'), 64000);
      // Date suffix must not parse as the version; 3.5 read pre-family.
      expect(resolveModelMaxOutputTokens('claude-3-5-sonnet-20241022'), 8192);
      expect(resolveModelMaxOutputTokens('claude-sonnet-4-5'), 64000);
      expect(resolveModelMaxOutputTokens('claude_opus_4_5'), 64000);
    });
  });

  group('catalog/cli builders thread the ceiling table', () {
    test('buildCatalogModel: table beats provider default', () {
      expect(
        buildCatalogModel('anthropic', 'claude-opus-4-5').maxTokens,
        64000,
      );
    });

    test('buildCatalogModel: non-Claude id keeps the provider default', () {
      expect(buildCatalogModel('openai', 'gpt-4o').maxTokens, 16384);
    });

    test('buildCatalogModel: explicit override beats the table', () {
      expect(
        buildCatalogModel(
          'anthropic',
          'claude-opus-4-5',
          maxTokens: 1000,
        ).maxTokens,
        1000,
      );
    });

    test('buildCliDefaultModel resolves through the table', () {
      expect(
        buildCliDefaultModel('anthropic', modelId: 'claude-opus-4-5')
            .maxTokens,
        64000,
      );
    });
  });
}
