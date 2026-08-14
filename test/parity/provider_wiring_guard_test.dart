import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/cli_args.dart';
import 'package:flutter_agent_harness/src/cli/custom_providers.dart';
import 'package:test/test.dart';

/// Guard: adding a new provider to the catalog must wire it EVERYWHERE in
/// one change. Each check below names the integration point that was
/// historically forgotten; extend this file when a new wiring point appears.
///
/// When you add a catalog provider, make sure each of these holds:
/// 1. `customProviderApiTypes` includes the spec name (saved-provider
///    entries reference it; `CustomProviderEntry.fromYaml` rejects the
///    entry otherwise — a config that "silently" can't save your provider).
/// 2. `cliProviderKinds` accepts the kind (so `--provider <kind>` works
///    headless) — unless the provider is interactive-only (OAuth/SSO-first,
///    no env key, like `chatgpt`), in which case add it to
///    [interactiveOnlyProviders] below with a reason.
/// 3. The kind builds a model: `providerStreamFunction` accepts it and
///    `buildCliDefaultModel` either has a default model id or throws a
///    helpful ConfigException asking for `--model`.
void main() {
  /// Catalog entries that deliberately have NO `--provider` CLI kind
  /// (interactive auth flows only). Everything else must be reachable
  /// headless.
  const interactiveOnlyProviders = {'chatgpt': 'OAuth-only sign-in'};

  /// Catalog entries deliberately NOT a custom-provider api type: they have
  /// dedicated setup flows (OAuth/presets), and an openai-compatible custom
  /// endpoint already covers the generic path via apiType `openai`.
  const presetOnlyProviders = {
    'openrouter': 'OAuth preset; custom openai-like endpoints cover it',
    'codemie': 'SSO preset that writes its own registry entry',
    'chatgpt': 'OAuth preset (Codex backend, no custom endpoints exist)',
  };

  test('every catalog provider is a legal custom-provider api type', () {
    for (final spec in providerCatalog.values) {
      if (presetOnlyProviders.containsKey(spec.name)) continue;
      expect(
        customProviderApiTypes,
        contains(spec.name),
        reason:
            '${spec.name} is in providerCatalog but missing from '
            'customProviderApiTypes — /provider presets cannot save it and '
            'CustomProviderEntry.fromYaml rejects its entries. If it has a '
            'dedicated flow, exempt it in presetOnlyProviders with a reason',
      );
    }
  });

  test('every custom-provider api type resolves to a catalog spec', () {
    for (final apiType in customProviderApiTypes) {
      expect(
        providerCatalog.containsKey(apiType),
        isTrue,
        reason:
            'customProviderApiTypes lists "$apiType" but the catalog has no '
            'such spec — CustomProviderEntry.spec would null-assert crash',
      );
    }
  });

  test('every headless-capable catalog kind is accepted by --provider', () {
    for (final spec in providerCatalog.values) {
      final skipReason = interactiveOnlyProviders[spec.name];
      if (skipReason != null) continue;
      expect(
        cliProviderKinds,
        contains(spec.kind),
        reason:
            '${spec.name} (kind ${spec.kind}) cannot be selected with '
            '--provider: add it to cliProviderKinds (cli_args.dart) or '
            'interactiveOnlyProviders with a reason',
      );
    }
  });

  test('every catalog kind builds a stream function', () {
    for (final spec in providerCatalog.values) {
      expect(
        () => providerStreamFunction(spec.kind, 'test-key'),
        returnsNormally,
        reason:
            '${spec.name} (kind ${spec.kind}) is in the catalog but '
            'providerStreamFunction rejects its kind',
      );
    }
  });

  test('every cli provider kind maps to a catalog spec', () {
    for (final kind in cliProviderKinds) {
      final hasSpec = providerCatalog.values.any((s) => s.kind == kind);
      expect(
        hasSpec,
        isTrue,
        reason:
            'cliProviderKinds accepts "$kind" but no catalog spec uses it — '
            'buildCliDefaultModel would throw "unknown provider"',
      );
    }
  });

  test('buildCliDefaultModel resolves or clearly demands --model per kind', () {
    for (final kind in cliProviderKinds) {
      // Either a default model id exists, or the error teaches --model —
      // never an "unknown provider" surprise.
      Object? thrown;
      String? modelId;
      try {
        final model = buildCliDefaultModel(kind);
        modelId = model.id;
      } on Object catch (e) {
        thrown = e;
      }
      if (thrown != null) {
        expect(
          thrown,
          isA<ConfigException>(),
          reason: 'kind $kind: unexpected error type $thrown',
        );
        expect(
          thrown.toString(),
          contains('--model'),
          reason:
              'kind $kind has no default model id — the error must ask '
              'for --model explicitly',
        );
      } else {
        expect(modelId, isNotNull, reason: 'kind $kind built no model');
      }
    }
  });

  test('CustomProviderEntry round-trips every catalog api type', () {
    for (final apiType in customProviderApiTypes) {
      final entry = CustomProviderEntry(
        name: 'test-$apiType',
        apiType: apiType,
        baseUrl: 'https://example.test/v1',
        modelId: 'some-model',
      );
      final restored = CustomProviderEntry.fromYaml(entry.toYaml());
      expect(restored.apiType, apiType);
      expect(restored.spec.kind, providerCatalog[apiType]!.kind);
    }
  });
}
