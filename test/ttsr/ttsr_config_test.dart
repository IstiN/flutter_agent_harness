import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

TtsrConfig _parse(String yamlSource) {
  return TtsrConfig.fromYaml(
    loadYaml(yamlSource),
    sourcePath: '~/.fah/config.yaml',
  );
}

/// Parses a serialized `ttsr:` section (with the `ttsr:` header, as written
/// into the CLI config file by [TtsrConfig.toYaml]).
TtsrConfig _parseSection(String document) {
  final doc = loadYaml(document);
  return TtsrConfig.fromYaml(
    (doc as YamlMap)['ttsr'],
    sourcePath: '~/.fah/config.yaml',
  );
}

void main() {
  group('TtsrConfig.fromYaml', () {
    test('parses defaults for a minimal section', () {
      final config = _parse('rules: []\n');
      final settings = config.settings;
      expect(settings.enabled, isTrue);
      expect(settings.contextMode, TtsrContextMode.discard);
      expect(settings.repeatMode, TtsrRepeatMode.once);
      expect(settings.repeatGap, 10);
      expect(settings.maxInjectionsPerTurn, 3);
      expect(settings.retryDelay, const Duration(milliseconds: 50));
      expect(config.rules, isEmpty);
    });

    test('parses settings', () {
      final config = _parse('''
enabled: false
contextMode: keep
repeatMode: after-gap
repeatGap: 5
maxInjectionsPerTurn: 2
retryDelayMs: 0
''');
      final settings = config.settings;
      expect(settings.enabled, isFalse);
      expect(settings.contextMode, TtsrContextMode.keep);
      expect(settings.repeatMode, TtsrRepeatMode.afterGap);
      expect(settings.repeatGap, 5);
      expect(settings.maxInjectionsPerTurn, 2);
      expect(settings.retryDelay, Duration.zero);
    });

    test('parses a full rule', () {
      final config = _parse('''
rules:
  - name: no-console
    pattern: "console\\\\.log\\\\("
    body: Do not use console.log.
    enabled: false
    scope: [text, tool:edit]
''');
      final rule = config.rules.single;
      expect(rule.name, 'no-console');
      expect(rule.patterns, [r'console\.log\(']);
      expect(rule.body, 'Do not use console.log.');
      expect(rule.enabled, isFalse);
      expect(rule.path, '~/.fah/config.yaml');
      expect(rule.scope.allowText, isTrue);
      expect(rule.scope.allowAnyTool, isFalse);
      expect(rule.scope.toolNames, {'edit'});
    });

    test('accepts a pattern list and a scope string', () {
      final config = _parse('''
rules:
  - name: a
    patterns: ["alpha", "beta"]
    scope: thinking
    body: body
''');
      final rule = config.rules.single;
      expect(rule.patterns, ['alpha', 'beta']);
      expect(rule.scope.allowThinking, isTrue);
      expect(rule.scope.allowText, isFalse);
    });

    test('a rule without scope gets the default scope', () {
      final config = _parse('''
rules:
  - name: a
    pattern: x
    body: body
''');
      expect(config.rules.single.scope.allowText, isTrue);
      expect(config.rules.single.scope.allowAnyTool, isTrue);
      expect(config.rules.single.scope.allowThinking, isFalse);
    });

    test('an explicit rule path wins over the source path', () {
      final config = _parse('''
rules:
  - name: a
    pattern: x
    body: body
    path: custom/location.md
''');
      expect(config.rules.single.path, 'custom/location.md');
    });

    test('strict errors surface as ConfigException', () {
      expect(() => _parse('[]'), throwsA(isA<ConfigException>()));
      expect(
        () => _parse('contextMode: sideways\n'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => _parse('repeatMode: often\n'),
        throwsA(isA<ConfigException>()),
      );
      expect(() => _parse('repeatGap: -1\n'), throwsA(isA<ConfigException>()));
      expect(
        () => _parse('maxInjectionsPerTurn: 0\n'),
        throwsA(isA<ConfigException>()),
      );
      expect(() => _parse('rules: {}\n'), throwsA(isA<ConfigException>()));
      expect(
        () => _parse('rules:\n  - body: b\n'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => _parse('rules:\n  - name: a\n    body: b\n'),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => _parse('rules:\n  - name: a\n    pattern: x\n'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('invalid scope tokens are collected as warnings', () {
      final warnings = <String>[];
      TtsrConfig.fromYaml(
        loadYaml('''
rules:
  - name: a
    pattern: x
    body: b
    scope: [text, "bogus token!"]
'''),
        warnings: warnings,
      );
      expect(warnings.single, contains('invalid scope token'));
    });

    test('round-trips through toYaml', () {
      final original = _parse('''
contextMode: keep
repeatMode: after-gap
repeatGap: 7
maxInjectionsPerTurn: 2
retryDelayMs: 25
rules:
  - name: no-console
    pattern: "console\\\\.log\\\\("
    body: |
      Do not use console.log.
      Use the logger.
    enabled: false
    scope: [text, tool:edit]
  - name: plain
    pattern: simple
    body: short
''');
      final roundTripped = _parseSection(original.toYaml());
      expect(roundTripped.settings.enabled, isTrue);
      expect(roundTripped.settings.contextMode, TtsrContextMode.keep);
      expect(roundTripped.settings.repeatMode, TtsrRepeatMode.afterGap);
      expect(roundTripped.settings.repeatGap, 7);
      expect(roundTripped.settings.maxInjectionsPerTurn, 2);
      expect(roundTripped.settings.retryDelay.inMilliseconds, 25);
      expect(roundTripped.rules, hasLength(2));
      final rule = roundTripped.rules.first;
      expect(rule.name, 'no-console');
      expect(rule.patterns, [r'console\.log\(']);
      expect(rule.body, 'Do not use console.log.\nUse the logger.\n');
      expect(rule.enabled, isFalse);
      expect(rule.scope.allowText, isTrue);
      expect(rule.scope.toolNames, {'edit'});
      expect(roundTripped.rules[1].scope.allowAnyTool, isTrue);
    });

    test('serializes an empty rule list', () {
      final config = TtsrConfig(settings: const TtsrSettings(enabled: false));
      final roundTripped = _parseSection(config.toYaml());
      expect(roundTripped.settings.enabled, isFalse);
      expect(roundTripped.rules, isEmpty);
    });
  });

  group('TtsrConfig.rulesFromYaml (project rules file)', () {
    test('parses a rules-only file with the file path as provenance', () {
      final rules = TtsrConfig.rulesFromYaml(
        loadYaml('''
rules:
  - name: project-rule
    pattern: danger
    body: Do not do dangerous things.
'''),
        sourcePath: '.fah/rules.yaml',
      );
      expect(rules.single.name, 'project-rule');
      expect(rules.single.path, '.fah/rules.yaml');
    });

    test('rejects a non-map file', () {
      expect(
        () => TtsrConfig.rulesFromYaml(loadYaml('- just\n- a\n- list\n')),
        throwsA(isA<ConfigException>()),
      );
    });

    test('an absent rules key yields no rules', () {
      expect(TtsrConfig.rulesFromYaml(loadYaml('{}')), isEmpty);
    });
  });
}
