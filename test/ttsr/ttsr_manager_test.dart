import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

TtsrRule _rule(
  String name,
  String pattern, {
  TtsrScope scope = TtsrScope.defaultScope,
  bool enabled = true,
}) {
  return TtsrRule(
    name: name,
    patterns: [pattern],
    body: 'rule body for $name',
    scope: scope,
    enabled: enabled,
  );
}

const _text = TtsrMatchContext(source: TtsrMatchSource.text);
const _thinking = TtsrMatchContext(source: TtsrMatchSource.thinking);

TtsrMatchContext _tool(String name, {String id = '1'}) {
  return TtsrMatchContext(
    source: TtsrMatchSource.tool,
    toolName: name,
    streamKey: 'toolcall:$id',
  );
}

void main() {
  group('TtsrManager registration', () {
    test('registers a valid rule', () {
      final manager = TtsrManager();
      expect(manager.addRule(_rule('a', 'foo')), isTrue);
      expect(manager.hasRules(), isTrue);
      expect(manager.rules.map((rule) => rule.name), ['a']);
    });

    test('duplicate names are ignored (first wins)', () {
      final manager = TtsrManager();
      expect(manager.addRule(_rule('a', 'foo')), isTrue);
      expect(manager.addRule(_rule('a', 'bar')), isFalse);
      expect(manager.rules.single.patterns, ['foo']);
    });

    test('disabled rules are skipped', () {
      final manager = TtsrManager();
      expect(manager.addRule(_rule('a', 'foo', enabled: false)), isFalse);
      expect(manager.hasRules(), isFalse);
    });

    test('disabled manager refuses registration and matching', () {
      final manager = TtsrManager(settings: const TtsrSettings(enabled: false));
      expect(manager.addRule(_rule('a', 'foo')), isFalse);
      expect(manager.hasRules(), isFalse);
      expect(manager.checkDelta('foo', _text), isEmpty);
    });

    test('invalid regex conditions are skipped with a warning', () {
      final manager = TtsrManager();
      final rule = TtsrRule(
        name: 'a',
        patterns: const ['valid', '[unclosed'],
        body: 'body',
      );
      expect(manager.addRule(rule), isTrue);
      expect(manager.warnings, hasLength(1));
      expect(manager.warnings.single, contains('invalid regex'));
      // The valid condition still matches.
      expect(manager.checkDelta('valid', _text).single.name, 'a');
    });

    test('a rule with no compilable condition is refused', () {
      final manager = TtsrManager();
      final rule = TtsrRule(
        name: 'a',
        patterns: const ['[unclosed'],
        body: 'body',
      );
      expect(manager.addRule(rule), isFalse);
      expect(manager.hasRules(), isFalse);
      expect(manager.warnings, isNotEmpty);
    });

    test('an unreachable scope is refused with a warning', () {
      final manager = TtsrManager();
      final warnings = <String>[];
      final scope = TtsrScope.parse(
        const ['bogus token!'],
        ruleName: 'a',
        warnings: warnings,
      );
      expect(scope.isReachable, isFalse);
      expect(warnings.single, contains('invalid scope token'));
      expect(manager.addRule(_rule('a', 'foo', scope: scope)), isFalse);
    });
  });

  group('TtsrManager matching', () {
    test('matches a text delta', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foobar'));
      expect(manager.checkDelta('say foobar now', _text).single.name, 'a');
    });

    test('matches a pattern split across chunks (cumulative buffer)', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foobar'));
      expect(manager.checkDelta('foo', _text), isEmpty);
      expect(manager.checkDelta('bar', _text).single.name, 'a');
    });

    test('does not match unrelated content', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foobar'));
      expect(manager.checkDelta('unrelated text', _text), isEmpty);
    });

    test('multiple conditions are ORed', () {
      final manager = TtsrManager();
      manager.addRule(
        TtsrRule(name: 'a', patterns: const ['alpha', 'beta'], body: 'body'),
      );
      expect(manager.checkDelta('mention beta', _text).single.name, 'a');
    });

    test('default scope matches text and tools but not thinking', () {
      final manager = TtsrManager()..addRule(_rule('a', 'secret'));
      expect(manager.checkDelta('secret', _text), hasLength(1));
      expect(manager.checkDelta('secret', _thinking), isEmpty);
      expect(manager.checkDelta('secret', _tool('edit')), hasLength(1));
    });

    test('thinking-scoped rule matches thinking deltas', () {
      final manager = TtsrManager()
        ..addRule(
          _rule(
            'a',
            'secret',
            scope: const TtsrScope(
              allowText: false,
              allowThinking: true,
              allowAnyTool: false,
            ),
          ),
        );
      expect(manager.checkDelta('secret', _thinking).single.name, 'a');
      expect(manager.checkDelta('secret', _text), isEmpty);
    });

    test('tool-name scope matches only the named tool', () {
      final manager = TtsrManager()
        ..addRule(
          _rule(
            'a',
            'secret',
            scope: const TtsrScope(
              allowText: false,
              allowAnyTool: false,
              toolNames: {'edit'},
            ),
          ),
        );
      expect(manager.checkDelta('secret', _tool('edit')).single.name, 'a');
      expect(manager.checkDelta('secret', _tool('write')), isEmpty);
      expect(manager.checkDelta('secret', _text), isEmpty);
    });

    test('scope tokens parse text/thinking/tool/tool:name', () {
      final warnings = <String>[];
      final scope = TtsrScope.parse(
        const ['text', 'thinking', 'tool:bash'],
        ruleName: 'a',
        warnings: warnings,
      );
      expect(warnings, isEmpty);
      expect(scope.allowText, isTrue);
      expect(scope.allowThinking, isTrue);
      expect(scope.allowAnyTool, isFalse);
      expect(scope.toolNames, {'bash'});
      expect(scope.matches(_thinking), isTrue);
      expect(scope.matches(_tool('bash')), isTrue);
      expect(scope.matches(_tool('edit')), isFalse);
    });

    test('the tool/toolcall token admits any tool', () {
      final warnings = <String>[];
      final scope = TtsrScope.parse(
        const ['toolcall'],
        ruleName: 'a',
        warnings: warnings,
      );
      expect(scope.allowAnyTool, isTrue);
      expect(scope.matches(_tool('anything')), isTrue);
      expect(scope.matches(_text), isFalse);
    });

    test('buffers are isolated per stream key', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foobar'));
      // Split the pattern across two different tool calls: must NOT match.
      expect(manager.checkDelta('foo', _tool('edit', id: '1')), isEmpty);
      expect(manager.checkDelta('bar', _tool('edit', id: '2')), isEmpty);
    });

    test('resetBuffer clears accumulated content', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foobar'));
      expect(manager.checkDelta('foo', _text), isEmpty);
      manager.resetBuffer();
      // Without the accumulated 'foo', 'bar' alone must not match.
      expect(manager.checkDelta('bar', _text), isEmpty);
    });

    test('matching stops at the first scope shortcut for text-only rules', () {
      final manager = TtsrManager()..addRule(_rule('a', 'secret'));
      // No rule allows thinking, so the thinking buffer never accumulates.
      expect(manager.checkDelta('sec', _thinking), isEmpty);
      expect(manager.checkDelta('ret', _thinking), isEmpty);
    });
  });

  group('TtsrManager repeat policy', () {
    test('once: an injected rule never re-triggers', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foo'));
      expect(manager.checkDelta('foo', _text).single.name, 'a');
      manager.markInjectedByNames(const ['a']);
      manager.resetBuffer();
      expect(manager.checkDelta('foo', _text), isEmpty);
    });

    test('after-gap: re-triggers only after repeatGap completed turns', () {
      final manager = TtsrManager(
        settings: const TtsrSettings(
          repeatMode: TtsrRepeatMode.afterGap,
          repeatGap: 2,
        ),
      )..addRule(_rule('a', 'foo'));
      expect(manager.checkDelta('foo', _text).single.name, 'a');
      manager.markInjectedByNames(const ['a']);
      manager
        ..resetBuffer()
        ..incrementMessageCount();
      expect(manager.checkDelta('foo', _text), isEmpty);
      manager.incrementMessageCount();
      expect(manager.checkDelta('foo', _text).single.name, 'a');
    });

    test('injected names round-trip through restoreInjected', () {
      final manager = TtsrManager()..addRule(_rule('a', 'foo'));
      manager.markInjectedByNames(const ['a']);
      final restored = TtsrManager()
        ..addRule(_rule('a', 'foo'))
        ..restoreInjected(manager.injectedRuleNames);
      expect(restored.checkDelta('foo', _text), isEmpty);
      restored.clearInjected();
      expect(restored.checkDelta('foo', _text).single.name, 'a');
    });
  });
}
