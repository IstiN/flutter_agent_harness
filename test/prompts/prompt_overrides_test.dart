import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('parsePromptOverrideMap', () {
    test('returns empty for a missing section', () {
      expect(parsePromptOverrideMap(null), isEmpty);
    });

    test('accepts known names with string values (paths and inline)', () {
      final map = parsePromptOverrideMap(
        loadYaml('''
system: ~/prompts/my_system.md
cli/mode_review: "You are a terse reviewer."
compaction/summary: ./prompts/sum.md
'''),
      );
      expect(map['system'], '~/prompts/my_system.md');
      expect(map['cli/mode_review'], 'You are a terse reviewer.');
      expect(map['compaction/summary'], './prompts/sum.md');
    });

    test('accepts multi-line inline text', () {
      final map = parsePromptOverrideMap(
        loadYaml('''
cli/mode_review: |
  You are a terse reviewer.
  Never refactor.
'''),
      );
      expect(map['cli/mode_review'], contains('Never refactor.'));
    });

    test('rejects an unknown prompt name', () {
      expect(
        () => parsePromptOverrideMap(loadYaml('bogus/name: "text"')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown prompt override "bogus/name"'),
          ),
        ),
      );
    });

    test('rejects a non-string value', () {
      expect(
        () => parsePromptOverrideMap(loadYaml('system: 42')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"prompts.system" must be a non-empty string'),
          ),
        ),
      );
    });

    test('rejects an empty value', () {
      expect(
        () => parsePromptOverrideMap(loadYaml('system: ""')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a non-map section', () {
      expect(
        () => parsePromptOverrideMap(loadYaml('- just\n- a\n- list\n')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"prompts" must be a map'),
          ),
        ),
      );
    });

    test('rejects system and cli/mode_code together (aliases)', () {
      expect(
        () => parsePromptOverrideMap(
          loadYaml('''
system: a.md
cli/mode_code: b.md
'''),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('aliases'),
          ),
        ),
      );
    });
  });

  group('PromptOverrides', () {
    test('resolve returns the override or the fallback', () {
      const overrides = PromptOverrides({'cli/mode_review': 'custom review'});
      expect(overrides.resolve('cli/mode_review', 'builtin'), 'custom review');
      expect(overrides.resolve('cli/mode_code', 'builtin'), 'builtin');
      expect(overrides['cli/mode_review'], 'custom review');
      expect(overrides['cli/mode_code'], isNull);
      expect(overrides.names, ['cli/mode_review']);
    });

    test('empty resolves every name to the fallback', () {
      expect(PromptOverrides.empty.isEmpty, isTrue);
      expect(PromptOverrides.empty.resolve('system', 'builtin'), 'builtin');
    });
  });
}
