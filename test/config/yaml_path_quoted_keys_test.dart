/// gh-1787: the yaml path edit primitives find, edit, and extend QUOTED
/// key lines — the shape the typed emitters render (`models.overrides`
/// providers/model ids and `models.custom` names ride `jsonEncode`, see
/// `ModelCapabilityOverrides.toYaml` / `ModelsConfig.toYaml`).
///
/// The incident: the second `/model-edit` write into a host-rendered
/// (quoted) overrides block missed the quoted keys, inserted a duplicate
/// bare-key chain, and the pre-write `loadYaml` threw
/// `YamlException: Duplicate mapping key` — uncaught, up the TUI submit
/// path, as a raw stack trace, with the maxTokens write never landing.
library;

import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// The on-disk shape AFTER a first `/model-edit` write plus the host's
/// whole-file persist: the surgical upsert wrote bare keys, then
/// `ModelCapabilityOverrides.toYaml` re-rendered them quoted.
const _incidentConfig = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        contextWindow: 204800
''';

/// The hand-edited shape the rework review flagged (gh-1787): SINGLE-quoted
/// keys are legal yaml and spell the SAME mapping key — `'copilot':` ≡
/// `"copilot":` ≡ `copilot:` — so the edit primitives must find them, or a
/// second write inserts a duplicate chain whose pre-write parse throws
/// `YamlException: Duplicate mapping key` (the incident's failure class,
/// surviving for hand-edited files).
const _singleQuotedConfig = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    'copilot':
      'gemini-4-argon':
        contextWindow: 204800
''';

void main() {
  group('upsertYamlPath into a quoted overrides block (gh-1787)', () {
    test('a missing field merges into the existing quoted entry', () {
      final edited = upsertYamlPath(
        _incidentConfig,
        ['models', 'overrides', 'copilot', 'gemini-4-argon', 'maxTokens'],
        ['65536'],
      );
      // Parses: the duplicate bare chain would throw
      // `YamlException: Duplicate mapping key` right here.
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      // ONE provider entry — the quoted one, edited in place.
      expect(overrides.containsKey('copilot'), isTrue);
      expect(overrides.length, 1);
      final caps =
          (overrides['copilot'] as YamlMap)['gemini-4-argon'] as YamlMap;
      expect(caps['maxTokens'], 65536);
      expect(caps['contextWindow'], 204800);
    });

    test('a new model id under a quoted provider inserts quoted', () {
      final edited = upsertYamlPath(
        _incidentConfig,
        ['models', 'overrides', 'copilot', 'gpt-5', 'maxTokens'],
        ['32768'],
      );
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      expect(overrides.length, 1, reason: 'one provider block, two models');
      final models = overrides['copilot'] as YamlMap;
      expect(models.containsKey('gpt-5'), isTrue);
      expect(models.containsKey('gemini-4-argon'), isTrue);
      // Emitter parity: the inserted key uses the block's jsonEncode
      // spelling, so the next whole-file persist round-trips byte-identical.
      expect(edited, contains('"gpt-5":'));
    });

    test('a new provider under quoted siblings inserts quoted', () {
      final edited = upsertYamlPath(
        _incidentConfig,
        ['models', 'overrides', 'zai', 'glm-5.3-flash', 'maxTokens'],
        ['65536'],
      );
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      expect(overrides.containsKey('zai'), isTrue);
      expect(edited, contains('"zai":'), reason: 'sibling spelling is shared');
    });

    test('a bare-key file stays bare (no quote churn)', () {
      const bare = '''
models:
  overrides:
    zai:
      glm-5.3-flash:
        maxTokens: 4096
''';
      final edited = upsertYamlPath(
        bare,
        ['models', 'overrides', 'zai', 'glm-5.3-flash', 'thinkingLevel'],
        ['high'],
      );
      expect(edited, isNot(contains('"')), reason: 'legacy shape is stable');
      final doc = loadYaml(edited) as YamlMap;
      final caps =
          ((doc['models'] as YamlMap)['overrides'] as YamlMap)['zai']
              as YamlMap;
      expect((caps['glm-5.3-flash'] as YamlMap)['thinkingLevel'], 'high');
    });

    test('rewriting an existing bare leaf keeps the bare spelling', () {
      final edited = upsertYamlPath(
        _incidentConfig,
        ['models', 'overrides', 'copilot', 'gemini-4-argon', 'contextWindow'],
        ['131072'],
      );
      expect(edited, contains('contextWindow: 131072'));
      final doc = loadYaml(edited) as YamlMap;
      final caps =
          ((doc['models'] as YamlMap)['overrides'] as YamlMap)['copilot']
              as YamlMap;
      expect((caps['gemini-4-argon'] as YamlMap)['contextWindow'], 131072);
    });

    test('rewriting an existing quoted leaf keeps its quoted spelling', () {
      const quotedLeaf = '''
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        "maxTokens": 4096
''';
      final edited = upsertYamlPath(
        quotedLeaf,
        ['models', 'overrides', 'copilot', 'gemini-4-argon', 'maxTokens'],
        ['65536'],
      );
      expect(edited, contains('"maxTokens": 65536'));
      final doc = loadYaml(edited) as YamlMap;
      final caps =
          ((doc['models'] as YamlMap)['overrides'] as YamlMap)['copilot']
              as YamlMap;
      expect((caps['gemini-4-argon'] as YamlMap)['maxTokens'], 65536);
    });

    test('a quoted custom-model name is found (models.custom)', () {
      const custom = '''
models:
  custom:
    "my model":
      provider: openai-completions
      baseUrl: https://example.test/v1
''';
      final edited = upsertYamlPath(
        custom,
        ['models', 'custom', 'my model', 'modelId'],
        ['gpt-5'],
      );
      final doc = loadYaml(edited) as YamlMap;
      final entry = (doc['models'] as YamlMap)['custom'] as YamlMap;
      expect(entry.length, 1, reason: 'edited in place, not duplicated');
      expect((entry['my model'] as YamlMap)['modelId'], 'gpt-5');
    });

    test('a key that is not a valid bare yaml scalar matches quoted', () {
      // `my model` (a space) only parses quoted — the emitter's spelling.
      const spaced = '''
models:
  overrides:
    "my provider":
      "m:1":
        contextWindow: 32768
''';
      final edited = upsertYamlPath(
        spaced,
        ['models', 'overrides', 'my provider', 'm:1', 'maxTokens'],
        ['4096'],
      );
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      expect(overrides.length, 1);
      expect(
        ((overrides['my provider'] as YamlMap)['m:1'] as YamlMap)['maxTokens'],
        4096,
      );
    });
  });

  group('removeYamlPath on a quoted block (gh-1787)', () {
    test('a field remove edits the quoted entry, the sibling survives', () {
      const twoFields = '''
provider: copilot
model: gemini-4-argon
models:
  overrides:
    "copilot":
      "gemini-4-argon":
        contextWindow: 204800
        maxTokens: 65536
''';
      final edited = removeYamlPath(twoFields, [
        'models',
        'overrides',
        'copilot',
        'gemini-4-argon',
        'contextWindow',
      ]);
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      final caps =
          (overrides['copilot'] as YamlMap)['gemini-4-argon'] as YamlMap;
      expect(caps.containsKey('contextWindow'), isFalse);
      expect(caps['maxTokens'], 65536);
    });

    test('the last field remove drops the emptied quoted blocks', () {
      final edited = removeYamlPath(_incidentConfig, [
        'models',
        'overrides',
        'copilot',
        'gemini-4-argon',
        'contextWindow',
      ]);
      // Only that one field was pinned — the whole chain empties away.
      expect(edited, isNot(contains('"gemini-4-argon":')));
      expect(edited, isNot(contains('overrides')));
      final doc = loadYaml(edited) as YamlMap;
      expect(doc.containsKey('models'), isFalse);
    });
  });

  group('upsertYamlPath into a single-quoted block (gh-1787 rework)', () {
    test('a missing field merges into the existing single-quoted entry', () {
      final edited = upsertYamlPath(
        _singleQuotedConfig,
        ['models', 'overrides', 'copilot', 'gemini-4-argon', 'maxTokens'],
        ['65536'],
      );
      // The blind-spot duplicate chain would throw
      // `YamlException: Duplicate mapping key` right here.
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      expect(overrides.length, 1, reason: 'edited in place, not duplicated');
      final caps =
          (overrides['copilot'] as YamlMap)['gemini-4-argon'] as YamlMap;
      expect(caps['maxTokens'], 65536);
      expect(caps['contextWindow'], 204800);
    });

    test(
      'a new model id under single-quoted siblings inserts single-quoted',
      () {
        final edited = upsertYamlPath(
          _singleQuotedConfig,
          ['models', 'overrides', 'copilot', 'gpt-5', 'maxTokens'],
          ['32768'],
        );
        // Emitter parity: the inserted key adopts the block's own
        // single-quoted spelling, so the next whole-file persist
        // round-trips without quote churn.
        expect(edited, contains("'gpt-5':"));
        final doc = loadYaml(edited) as YamlMap;
        final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
        expect(overrides.length, 1);
        expect((overrides['copilot'] as YamlMap).containsKey('gpt-5'), isTrue);
      },
    );

    test('rewriting an existing single-quoted leaf keeps its spelling', () {
      final edited = upsertYamlPath(
        _singleQuotedConfig,
        ['models', 'overrides', 'copilot', 'gemini-4-argon', 'contextWindow'],
        ['131072'],
      );
      expect(edited, contains("'gemini-4-argon':"));
      expect(edited, isNot(contains('"gemini-4-argon":')));
      expect(edited, contains('contextWindow: 131072'));
      final doc = loadYaml(edited) as YamlMap;
      final caps =
          ((doc['models'] as YamlMap)['overrides'] as YamlMap)['copilot']
              as YamlMap;
      expect((caps['gemini-4-argon'] as YamlMap)['contextWindow'], 131072);
    });

    test(
      'a single-quoted key holding a quote matches (the doubled escape)',
      () {
        // `it''s` is the yaml single-quoted escape of `it's`.
        const quoted = '''
models:
  custom:
    'it''s a model':
      provider: openai-completions
''';
        final edited = upsertYamlPath(
          quoted,
          ['models', 'custom', "it's a model", 'modelId'],
          ['gpt-5'],
        );
        final doc = loadYaml(edited) as YamlMap;
        final entry = (doc['models'] as YamlMap)['custom'] as YamlMap;
        expect(entry.length, 1, reason: 'edited in place, not duplicated');
        expect((entry["it's a model"] as YamlMap)['modelId'], 'gpt-5');
      },
    );
  });

  group('removeYamlPath on a single-quoted block (gh-1787 rework)', () {
    test(
      'a field remove edits the single-quoted entry, the sibling survives',
      () {
        const twoFields = '''
models:
  overrides:
    'copilot':
      'gemini-4-argon':
        contextWindow: 204800
        maxTokens: 65536
''';
        final edited = removeYamlPath(twoFields, [
          'models',
          'overrides',
          'copilot',
          'gemini-4-argon',
          'contextWindow',
        ]);
        final doc = loadYaml(edited) as YamlMap;
        final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
        final caps =
            (overrides['copilot'] as YamlMap)['gemini-4-argon'] as YamlMap;
        expect(caps.containsKey('contextWindow'), isFalse);
        expect(caps['maxTokens'], 65536);
      },
    );
  });

  group('the inserted chain spelling is per level (gh-1787 rework)', () {
    test('only the first inserted level takes the block spelling; deeper '
        'fresh levels stay bare', () {
      final edited = upsertYamlPath(
        _incidentConfig,
        ['models', 'overrides', 'copilot', 'gpt-5', 'maxTokens'],
        ['32768'],
      );
      // First inserted level: real siblings (the quoted gemini entry) —
      // the block's quoted spelling.
      expect(edited, contains('"gpt-5":'));
      // Deeper fresh levels have no visible children — the legacy bare
      // shape (the key-spelling helper's own doc: a parent with no
      // visible children stays bare).
      expect(edited, contains('maxTokens: 32768'));
      expect(edited, isNot(contains('"maxTokens":')));
    });

    test('a single-level insert into a quoted block stays quoted', () {
      final edited = upsertYamlPath(
        _incidentConfig,
        ['models', 'overrides', 'note'],
        ['kept for the rework'],
      );
      // The only inserted level IS the first one — real siblings, the
      // block's quoted spelling.
      expect(edited, contains('"note": kept for the rework'));
      final doc = loadYaml(edited) as YamlMap;
      final overrides = (doc['models'] as YamlMap)['overrides'] as YamlMap;
      expect(overrides['note'], 'kept for the rework');
    });
  });
}
