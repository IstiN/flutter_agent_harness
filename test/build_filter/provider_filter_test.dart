// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The `FA_PROVIDERS` build/runtime filter. The compile-time dart-define is
/// always empty under `dart test`, so these cases exercise the runtime env
/// override ([providerFilterEnvOverride]) — the same code path the CLI wires
/// from the process environment in `bin/fah.dart`.
void main() {
  group('provider filter (FA_PROVIDERS)', () {
    tearDown(() => providerFilterEnvOverride = null);

    test('no override enables the whole catalog', () {
      expect(providerFilterEnvOverride, isNull);
      final visibleCount = providerCatalog.values.where((s) => s.visible).length;
      expect(enabledProviders(), hasLength(visibleCount));
      for (final entry in providerCatalog.entries) {
        final name = entry.key;
        final spec = entry.value;
        expect(providerEnabledInBuild(name), isTrue, reason: name);
        // Hidden providers (e.g. chatgpt codex) resolve through the catalog
        // but are not user-facing in pickers / status lists.
        expect(catalogProvider(name), isNotNull, reason: name);
        expect(enabledProviders().contains(spec), spec.visible, reason: name);
      }
    });

    test('a subset keeps only the listed providers', () {
      providerFilterEnvOverride = 'dial,codemie';
      expect(enabledProviderNames(), ['codemie', 'dial']); // catalog order
      expect(providerEnabledInBuild('dial'), isTrue);
      expect(providerEnabledInBuild('openrouter'), isFalse);
      // Filtered-out names no longer resolve.
      expect(catalogProvider('openrouter'), isNull);
      expect(catalogProvider('anthropic'), isNull);
      expect(catalogProvider('dial'), isNotNull);
    });

    test("'all' / '*' keep every visible provider", () {
      final visibleCount = providerCatalog.values.where((s) => s.visible).length;
      for (final value in ['all', '*']) {
        providerFilterEnvOverride = value;
        expect(
          enabledProviders(),
          hasLength(visibleCount),
          reason: value,
        );
      }
    });

    test('names match case-insensitively and ignore whitespace', () {
      providerFilterEnvOverride = ' DIAL , Codemie ';
      expect(enabledProviderNames(), ['codemie', 'dial']);
      expect(providerEnabledInBuild('dial'), isTrue);
      expect(providerEnabledInBuild('DIAL'), isTrue);
    });

    test('the openai-completions alias honors the filter', () {
      // Without a filter the legacy alias resolves to openrouter…
      expect(catalogProvider('openai-completions')?.name, 'openrouter');
      // …but not when openrouter itself is filtered out.
      providerFilterEnvOverride = 'dial';
      expect(catalogProvider('openai-completions'), isNull);
    });
  });
}
