/// Tests for `CubeToolPolicy`: wildcard/word-boundary matching, deny-wins,
/// the empty-allow deny-all default, and strict schema errors.
library;

import 'package:flutter_agent_harness/src/cube/config/tool_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  CubeToolPolicy parse(String yaml) => CubeToolPolicy.fromYaml(loadYaml(yaml));

  group('CubeToolPolicy.fromYaml', () {
    test('null section yields the deny-all default', () {
      final policy = CubeToolPolicy.fromYaml(null);
      expect(policy.allow, isEmpty);
      expect(policy.deny, isEmpty);
      expect(policy.permits('git'), isFalse);
    });

    test('parses allow and deny entries', () {
      final policy = parse('''
allow: [git, curl, "git*"]
deny: ["git push", ssh]
''');
      expect(policy.allow, {'git', 'curl', 'git*'});
      expect(policy.deny, {'git push', 'ssh'});
    });

    test('rejects unknown keys', () {
      expect(
        () => parse('allowed: [git]'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.tools: unknown key "allowed"'),
          ),
        ),
      );
    });

    test('rejects a non-map section', () {
      expect(
        () => CubeToolPolicy.fromYaml('git'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects non-string or empty entries', () {
      expect(() => parse('allow: [1]'), throwsA(isA<ConfigException>()));
      expect(() => parse('allow: ["  "]'), throwsA(isA<ConfigException>()));
    });
  });

  group('CubeToolPolicy.permits', () {
    test('wildcard git* allows git, git-status and git-log', () {
      final policy = parse('allow: ["git*"]');
      expect(policy.permits('git'), isTrue);
      expect(policy.permits('git-status'), isTrue);
      expect(policy.permits('git-log'), isTrue);
      expect(policy.permits('git push'), isTrue); // plain string prefix
    });

    test('exact entry allows the command alone', () {
      final policy = parse('allow: [git]');
      expect(policy.permits('git'), isTrue);
    });

    test('exact entry does not match a different command name', () {
      final policy = parse('allow: [git]');
      expect(policy.permits('gitx'), isFalse);
      expect(policy.permits('git-status'), isFalse);
    });

    test('multi-word entry matches at word boundary', () {
      final policy = parse('allow: ["git push"]');
      expect(policy.permits('git push'), isTrue);
      expect(policy.permits('git push -f'), isTrue);
      expect(policy.permits('git'), isFalse);
    });

    test('trailing-word boundary requires a space', () {
      final policy = parse('allow: [git]');
      expect(policy.permits('git commit'), isTrue);
      // 'gitignore' has no space after the 'git' prefix -> not a word match.
      expect(policy.permits('gitignore foo'), isFalse);
    });

    test('deny wins over allow', () {
      final policy = parse('''
allow: ["git*"]
deny: ["git push"]
''');
      expect(policy.permits('git log'), isTrue);
      expect(policy.permits('git push'), isFalse);
      expect(policy.permits('git push -f'), isFalse);
    });

    test('empty allowlist denies everything', () {
      final policy = parse('deny: [ssh]');
      expect(policy.permits('ssh'), isFalse);
      expect(policy.permits('git'), isFalse);
    });

    test('empty allowlist denies even a wildcard deny', () {
      final policy = parse('deny: ["*"]');
      expect(policy.permits('anything'), isFalse);
    });

    test('untrimmed command words are matched after trim', () {
      final policy = parse('allow: [git]');
      expect(policy.permits('  git  '), isTrue);
    });
  });
}
