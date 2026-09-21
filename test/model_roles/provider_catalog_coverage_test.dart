/// Boot-switch coverage by construction (gh-760, REG-C1 + UT-B1).
///
/// The `buildCliDefaultModel` boot path must resolve EVERY
/// [providerCatalog] entry — by name AND by adapter kind — so a catalog
/// addition can never again leave the boot switch behind and brick the
/// CLI with `ConfigException: unknown provider` (the owner crash: the app
/// wrote `provider: chatgpt-codex`, the switch did not know the kind).
///
/// A provider id NO version knows keeps the `ConfigException` for direct
/// API callers — the degrade-to-fallback lives at the config boundary
/// (`resolveEffectiveCliArgs`), not in the library.
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('buildCliDefaultModel catalog coverage (gh-760)', () {
    test('every catalog name and kind resolves (REG-C1)', () {
      final keys = <String>{
        for (final spec in providerCatalog.values) ...[spec.name, spec.kind],
      };
      expect(keys, isNotEmpty);
      for (final key in keys) {
        final model = buildCliDefaultModel(key, modelId: 'coverage-probe');
        expect(model.provider, isNotEmpty, reason: 'kind $key resolved');
      }
    });

    test('the chatgpt-codex kind resolves to the chatgpt catalog entry '
        '(UT-B1, the app-written config)', () {
      final model = buildCliDefaultModel(
        'chatgpt-codex',
        modelId: 'gpt-5-codex',
      );
      expect(model.provider, 'chatgpt');
      expect(model.api, 'responses');
      expect(model.baseUrl, chatGptCodexBaseUrl);
    });

    test('the catalog names the old switch missed resolve too', () {
      // The hand-maintained switch never learned these catalog names.
      for (final name in ['kimi', 'codemie', 'openai', 'chatgpt']) {
        final model = buildCliDefaultModel(name, modelId: 'probe');
        expect(model.provider, name, reason: 'catalog name $name');
      }
    });

    test('a provider id no version knows still throws for direct callers', () {
      expect(
        () => buildCliDefaultModel('from-the-future', modelId: 'x'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => buildCliDefaultModel('', modelId: 'x'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('the openai-completions legacy baseUrl behavior is preserved', () {
      final plain = buildCliDefaultModel('openai-completions', modelId: 'm');
      expect(plain.provider, 'openrouter');
      final custom = buildCliDefaultModel(
        'openai-completions',
        modelId: 'm',
        baseUrl: 'https://proxy.example/v1',
      );
      expect(custom.provider, 'openai');
    });
  });
}
