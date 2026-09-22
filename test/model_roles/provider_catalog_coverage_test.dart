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
import 'package:flutter_agent_harness/io.dart';
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

    test('every catalog id restores as a STREAMABLE adapter kind (REG-C1, '
        'gh-760 review)', () {
      // Name resolution alone is not enough: a saved id restoring as a raw
      // catalog NAME (openai, chatgpt) bricks the boot at
      // providerStreamFunction, which accepts adapter kinds only. The full
      // restore chain must land every catalog id on a kind the factory
      // knows.
      for (final spec in providerCatalog.values) {
        for (final id in [spec.name, spec.kind]) {
          final resolved = resolveEffectiveCliArgs(
            const CliArgs(),
            CliConfig(providerKind: id, modelId: 'probe'),
            env: const {},
          );
          expect(
            () => providerStreamFunction(resolved.provider, 'k'),
            returnsNormally,
            reason: 'saved id $id restores as streamable kind',
          );
        }
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
<<<<<<< HEAD

    test('ids are canonicalized at the seam: trim + case-fold on names '
        'AND kinds (gh-760 review)', () {
      // The persisted id comes from surfaces the CLI does not control; the
      // lookup must not depend on the caller's spelling.
      for (final id in [' chatgpt-codex ', 'CHATGPT-CODEX', 'ChatGpt']) {
        expect(
          resolveCliProviderSpec(id)?.name,
          'chatgpt',
          reason: 'id "$id" resolves canonically',
        );
      }
      expect(resolveCliProviderSpec(' OPENAI ')!.kind, 'openai-completions');
      expect(resolveCliProviderSpec('   '), isNull);
    });

    test('only the chatgpt spec is endpoint-locked (gh-760 review)', () {
      final locked = [
        for (final spec in providerCatalog.values)
          if (spec.endpointLocked) spec.name,
      ];
      expect(locked, ['chatgpt']);
    });
=======
>>>>>>> origin/main
  });
}
