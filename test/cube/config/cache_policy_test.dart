/// Tests for `CubeCachePolicy`: section-present defaults, explicit
/// overrides, ttl parsing and strict schema errors.
library;

import 'package:flutter_agent_harness/src/cube/config/cache_policy.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  CubeCachePolicy parse(String yaml) =>
      CubeCachePolicy.fromYaml(loadYaml(yaml));

  group('CubeCachePolicy.fromYaml', () {
    test('null section means caching disabled', () {
      final policy = CubeCachePolicy.fromYaml(null);
      expect(policy.enabled, isFalse);
      expect(policy.paths, isEmpty);
      expect(policy.restore, isTrue);
      expect(policy.ttl, isNull);
    });

    test('section present defaults enabled+restore to true', () {
      final policy = parse('paths: [/workspace/.cache]');
      expect(policy.enabled, isTrue);
      expect(policy.restore, isTrue);
      expect(policy.paths, ['/workspace/.cache']);
      expect(policy.ttl, isNull);
    });

    test('parses an explicit full section', () {
      final policy = parse('''
enabled: true
paths: [/workspace/.cache, /workspace/.npm]
restore: false
ttl: 24h
''');
      expect(policy.enabled, isTrue);
      expect(policy.restore, isFalse);
      expect(policy.ttl, const Duration(hours: 24));
      expect(policy.paths, ['/workspace/.cache', '/workspace/.npm']);
    });

    test('explicit enabled: false overrides the present-section default', () {
      expect(parse('enabled: false').enabled, isFalse);
    });

    test('rejects unknown keys', () {
      expect(
        () => parse('dir: /cache'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.cache: unknown key "dir"'),
          ),
        ),
      );
    });

    test('rejects bad ttl and non-string paths', () {
      expect(() => parse('ttl: 1h30m'), throwsA(isA<ConfigException>()));
      expect(() => parse('paths: [123]'), throwsA(isA<ConfigException>()));
      expect(
        () => parse('enabled: yes-please'),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
