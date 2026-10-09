// gh-1426 UT-2: the `models.overrides` section — strict parse, refresh-
// proof storage shape, and the resolver consultation in model building.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

YamlMap _yaml(String source) => loadYaml(source) as YamlMap;

void main() {
  group('ModelCapabilityOverride.fromYaml', () {
    test('parses the full shape', () {
      final override = ModelCapabilityOverride.fromYaml(
        'zai',
        'glm-5.3-flash',
        _yaml('''
contextWindow: 400000
maxTokens: 65536
thinkingLevel: high
omitMaxOutputTokens: true
'''),
      );
      expect(override.contextWindow, 400000);
      expect(override.maxTokens, 65536);
      expect(override.thinkingLevel, 'high');
      expect(override.omitMaxOutputTokens, isTrue);
    });

    test('parses the empty shape (every field optional)', () {
      final override = ModelCapabilityOverride.fromYaml(
        'zai',
        'glm-5.3-flash',
        _yaml('{}'),
      );
      expect(override.isEmpty, isTrue);
    });

    test('xhigh/max thinking levels fold to high', () {
      final override = ModelCapabilityOverride.fromYaml(
        'zai',
        'glm-5.3-flash',
        _yaml('thinkingLevel: max'),
      );
      expect(override.thinkingLevel, 'high');
    });

    test('rejects unknown fields naming the key', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('zai', 'glm-5.3-flash', _yaml('''
contextWindow: 200000
bogus: 1
''')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('models.overrides.zai.glm-5.3-flash'),
          ),
        ),
      );
    });

    test('rejects a bad thinking level naming the ladder', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('zai', 'glm', _yaml('''
thinkingLevel: turbo
''')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects non-boolean omitMaxOutputTokens', () {
      expect(
        () => ModelCapabilityOverride.fromYaml('zai', 'glm', _yaml('''
omitMaxOutputTokens: sometimes
''')),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('ModelsConfig overrides section', () {
    test('parses overrides alongside slots/custom', () {
      final models = ModelsConfig.fromYaml(_yaml('''
overrides:
  zai:
    glm-5.3-flash:
      maxTokens: 65536
      thinkingLevel: high
  openrouter:
    vendor/big-model:
      contextWindow: 1000000
'''));
      expect(models.overrides.length, 2);
      expect(
        models.overrides.lookup('zai', 'glm-5.3-flash')?.maxTokens,
        65536,
      );
      expect(
        models.overrides.lookup('openrouter', 'vendor/big-model')
            ?.contextWindow,
        1000000,
      );
    });

    test('lookup normalizes the provider name, keeps the model id exact', () {
      final models = ModelsConfig.fromYaml(_yaml('''
overrides:
  Zai:
    glm-5.3-flash:
      maxTokens: 65536
'''));
      expect(models.overrides.lookup('zai', 'glm-5.3-flash'), isNotNull);
      expect(models.overrides.lookup('ZAI', 'glm-5.3-flash'), isNotNull);
      // Model ids are matched verbatim (openrouter vendor prefixes, case).
      expect(models.overrides.lookup('zai', 'GLM-5.3-FLASH'), isNull);
    });

    test('unknown provider/model strings are allowed (they address futures)',
        () {
      final models = ModelsConfig.fromYaml(_yaml('''
overrides:
  future-provider:
    future-model:
      maxTokens: 65536
'''));
      expect(
        models.overrides.lookup('future-provider', 'future-model'),
        isNotNull,
      );
    });

    test('rejects unknown section keys', () {
      expect(
        () => ModelsConfig.fromYaml(_yaml('''
overrides: {}
bogus: {}
''')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('bogus'),
          ),
        ),
      );
    });

    test('rejects a non-map overrides section', () {
      expect(
        () => ModelsConfig.fromYaml(_yaml('overrides: nope')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a non-map model entry', () {
      expect(
        () => ModelsConfig.fromYaml(_yaml('''
overrides:
  zai:
    glm-5.3-flash: 65536
''')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('isEmpty stays true without overrides', () {
      expect(ModelsConfig().isEmpty, isTrue);
      expect(ModelsConfig.fromYaml(_yaml('overrides: {}')).isEmpty, isTrue);
    });

    test('setOverride/removeOverride mutate the live map', () {
      final models = ModelsConfig();
      models.setOverride(
        'zai',
        'glm-5.3-flash',
        const ModelCapabilityOverride(maxTokens: 65536),
      );
      expect(models.overrides.lookup('zai', 'glm-5.3-flash')?.maxTokens, 65536);
      models.removeOverride('zai', 'glm-5.3-flash');
      expect(models.overrides.lookup('zai', 'glm-5.3-flash'), isNull);
    });

    test('toYaml round-trips the overrides section', () {
      final models = ModelsConfig();
      models.setOverride(
        'zai',
        'glm-5.3-flash',
        const ModelCapabilityOverride(
          contextWindow: 400000,
          maxTokens: 65536,
          thinkingLevel: 'high',
          omitMaxOutputTokens: true,
        ),
      );
      final doc = _yaml(models.toYaml());
      final parsed = ModelsConfig.fromYaml(doc['models']);
      final roundTripped = parsed.overrides.lookup('zai', 'glm-5.3-flash');
      expect(roundTripped?.contextWindow, 400000);
      expect(roundTripped?.maxTokens, 65536);
      expect(roundTripped?.thinkingLevel, 'high');
      expect(roundTripped?.omitMaxOutputTokens, isTrue);
    });

    test('toYaml omits the overrides block when empty', () {
      final models = ModelsConfig()
        ..setSlotOverride(
          'vision',
          MediaSlotModelConfig(
            providerKind: 'openai-completions',
            baseUrl: 'https://api.openai.com/v1',
            modelId: 'gpt-4o',
          ),
        );
      expect(models.toYaml(), isNot(contains('overrides')));
    });
  });

  group('buildCatalogModel — override consultation (AC2)', () {
    test('the owner pain: raised maxTokens + thinking level reach the model',
        () {
      final previous = modelCapabilityOverrides;
      final overrides = ModelCapabilityOverrides()
        ..set(
          'zai',
          'glm-5.3-flash',
          const ModelCapabilityOverride(
            maxTokens: 65536,
            thinkingLevel: 'high',
          ),
        );
      modelCapabilityOverrides = overrides;
      addTearDown(() => modelCapabilityOverrides = previous);
      final model = buildCatalogModel('zai', 'glm-5.3-flash');
      expect(model.maxTokens, 65536);
      expect(model.thinkingLevel, 'high');
      expect(model.contextWindow, 200000); // untouched field keeps catalog
    });

    test('an override beats the explicit role-slot argument (layer order)',
        () {
      // The resolver precedence: override (layer 1) beats role slot (layer
      // 2) — the explicit buildCatalogModel contextWindow arg IS the role
      // slot, so an override contextWindow wins over it.
      final previous = modelCapabilityOverrides;
      final overrides = ModelCapabilityOverrides()
        ..set(
          'zai',
          'glm-5.3-flash',
          const ModelCapabilityOverride(contextWindow: 400000),
        );
      modelCapabilityOverrides = overrides;
      addTearDown(() => modelCapabilityOverrides = previous);
      final model = buildCatalogModel(
        'zai',
        'glm-5.3-flash',
        contextWindow: 128000,
      );
      expect(model.contextWindow, 400000);
    });

    test('no overrides installed → byte-identical legacy build (REG-1)', () {
      final previous = modelCapabilityOverrides;
      modelCapabilityOverrides = null;
      addTearDown(() => modelCapabilityOverrides = previous);
      final model = buildCatalogModel('zai', 'glm-5.3-flash');
      expect(model.contextWindow, 200000);
      expect(model.maxTokens, 16384);
      expect(model.thinkingLevel, isNull);
      expect(model.compat, isNull);
    });

    test('omitMaxOutputTokens lands on the model compat (AC7)', () {
      final previous = modelCapabilityOverrides;
      final overrides = ModelCapabilityOverrides()
        ..set(
          'zai',
          'glm-5.3-flash',
          const ModelCapabilityOverride(omitMaxOutputTokens: true),
        );
      modelCapabilityOverrides = overrides;
      addTearDown(() => modelCapabilityOverrides = previous);
      final model = buildCatalogModel('zai', 'glm-5.3-flash');
      expect(model.compat?.omitMaxOutputTokens, isTrue);
      // Auto-detection fields stay null → the adapter defaults apply.
      expect(model.compat?.maxTokensField, isNull);
      expect(model.compat?.thinkingFormat, isNull);
    });

    test('the override survives a catalog-source swap (AC3 refresh)', () {
      // The overrides live in the config file, not the catalog: swapping
      // the catalog source (remote fetch refresh) cannot touch them.
      final previous = modelCapabilityOverrides;
      final previousEnrichment = remoteCatalogEnrichment;
      final overrides = ModelCapabilityOverrides()
        ..set(
          'zai',
          'glm-5.3-flash',
          const ModelCapabilityOverride(maxTokens: 65536),
        );
      modelCapabilityOverrides = overrides;
      addTearDown(() {
        modelCapabilityOverrides = previous;
        setRemoteCatalogEnrichmentForTesting(previousEnrichment);
      });

      final before = buildCatalogModel('zai', 'glm-5.3-flash');
      // Simulate a remote-catalog refresh: a fresh (empty) catalog source
      // replaces the old one — the override layer is untouched.
      setRemoteCatalogEnrichmentForTesting(RemoteCatalogEnrichment());
      final after = buildCatalogModel('zai', 'glm-5.3-flash');
      expect(after.maxTokens, before.maxTokens);
      expect(after.maxTokens, 65536);
    });
  });

  group('buildCliDefaultModel — override consultation', () {
    test('the single-model boot path applies the same override layer', () {
      final previous = modelCapabilityOverrides;
      final overrides = ModelCapabilityOverrides()
        ..set(
          'zai',
          'glm-5.3-flash',
          const ModelCapabilityOverride(maxTokens: 65536),
        );
      modelCapabilityOverrides = overrides;
      addTearDown(() => modelCapabilityOverrides = previous);
      final model = buildCliDefaultModel('zai', modelId: 'glm-5.3-flash');
      expect(model.maxTokens, 65536);
    });
  });

  group('capability notes ride the model (gh-1426 rework)', () {
    test('the resolved notes are threaded onto the built Model — never '
        'dropped at the build boundary', () {
      // Today's catalog has no reasoning:false provider and the boot
      // builders pass no endpoint report, so no note fires here — the
      // assertion pins the THREADING: the field exists, is fed from the
      // resolver's notes (empty ⇒ silent default build, REG-1 noise-free),
      // and the E1/E3/E4 notes reach the status surfaces the moment a
      // spec produces one (see the /model-edit surface test).
      final previous = modelCapabilityOverrides;
      modelCapabilityOverrides = ModelCapabilityOverrides()
        ..set(
          'zai',
          'glm-5.3-flash',
          const ModelCapabilityOverride(maxTokens: 65536),
        );
      addTearDown(() => modelCapabilityOverrides = previous);
      expect(
        buildCatalogModel('zai', 'glm-5.3-flash').capabilityNotes,
        isEmpty,
      );
      expect(
        buildCliDefaultModel('zai', modelId: 'glm-5.3-flash').capabilityNotes,
        isEmpty,
      );
    });
  });
}
