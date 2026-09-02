/// Tests for `parseSizeBytes`, `parseDurationSpec` and
/// `CubeResourceLimits.fromYaml`.
library;

import 'package:flutter_agent_harness/src/cube/config/resource_limits.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('parseSizeBytes', () {
    test('plain integers are bytes', () {
      expect(parseSizeBytes('1024'), 1024);
      expect(parseSizeBytes('0'), 0);
    });

    test('binary suffixes are 1024-based', () {
      expect(parseSizeBytes('1K'), 1024);
      expect(parseSizeBytes('1KiB'), 1024);
      expect(parseSizeBytes('1M'), 1024 * 1024);
      expect(parseSizeBytes('1Mi'), 1024 * 1024);
      expect(parseSizeBytes('512Mi'), 512 * 1024 * 1024);
      expect(parseSizeBytes('1MiB'), 1024 * 1024);
      expect(parseSizeBytes('1G'), 1024 * 1024 * 1024);
      expect(parseSizeBytes('1GiB'), 1024 * 1024 * 1024);
    });

    test('decimal suffixes are 1000-based', () {
      expect(parseSizeBytes('1B'), 1);
      expect(parseSizeBytes('1KB'), 1000);
      expect(parseSizeBytes('1MB'), 1000 * 1000);
      expect(parseSizeBytes('1GB'), 1000 * 1000 * 1000);
    });

    test('suffixes are case-insensitive and allow a space', () {
      expect(parseSizeBytes('512mi'), 512 * 1024 * 1024);
      expect(parseSizeBytes('2 kib'), 2 * 1024);
      expect(parseSizeBytes(' 4gb '), 4 * 1000 * 1000 * 1000);
    });

    test('rejects malformed sizes', () {
      expect(() => parseSizeBytes('abc'), throwsFormatException);
      expect(() => parseSizeBytes('1.5MB'), throwsFormatException);
      expect(() => parseSizeBytes('5TB'), throwsFormatException);
      expect(() => parseSizeBytes(''), throwsFormatException);
      expect(() => parseSizeBytes('-5Mi'), throwsFormatException);
    });
  });

  group('parseDurationSpec', () {
    test('parses single-unit s/m/h specs', () {
      expect(parseDurationSpec('3600s'), const Duration(seconds: 3600));
      expect(parseDurationSpec('90s'), const Duration(seconds: 90));
      expect(parseDurationSpec('5m'), const Duration(minutes: 5));
      expect(parseDurationSpec('24h'), const Duration(hours: 24));
    });

    test('rejects compound and unknown units', () {
      expect(() => parseDurationSpec('1h30m'), throwsFormatException);
      expect(() => parseDurationSpec('10d'), throwsFormatException);
      expect(() => parseDurationSpec('hour'), throwsFormatException);
      expect(() => parseDurationSpec('-5s'), throwsFormatException);
      expect(() => parseDurationSpec(''), throwsFormatException);
    });
  });

  group('CubeResourceLimits.fromYaml', () {
    test('null section means no limits', () {
      final limits = CubeResourceLimits.fromYaml(null);
      expect(limits.cpu, isNull);
      expect(limits.memoryBytes, isNull);
      expect(limits.diskBytes, isNull);
      expect(limits.timeout, isNull);
    });

    test('parses a full resources section', () {
      final limits = CubeResourceLimits.fromYaml(
        loadYaml('''
limits:
  cpu: "50%"
  memory: 512Mi
  disk: 100Mi
timeout: 3600s
'''),
      );
      expect(limits.cpu, '50%'); // kept as a string, unparsed
      expect(limits.memoryBytes, 512 * 1024 * 1024);
      expect(limits.diskBytes, 100 * 1024 * 1024);
      expect(limits.timeout, const Duration(hours: 1));
    });

    test('accepts integer bytes and integer timeout seconds', () {
      final limits = CubeResourceLimits.fromYaml(
        loadYaml('''
limits: {memory: 2048}
timeout: 90
'''),
      );
      expect(limits.memoryBytes, 2048);
      expect(limits.timeout, const Duration(seconds: 90));
    });

    test('rejects a bad size string with the field named', () {
      expect(
        () => CubeResourceLimits.fromYaml(loadYaml('limits: {memory: lots}')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.resources.limits.memory'),
          ),
        ),
      );
    });

    test('rejects a bad timeout with the field named', () {
      expect(
        () => CubeResourceLimits.fromYaml(loadYaml('timeout: 1h30m')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.resources.timeout'),
          ),
        ),
      );
    });

    test('rejects unknown keys at both levels', () {
      expect(
        () => CubeResourceLimits.fromYaml(loadYaml('gpu: 1')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('cube.spec.resources: unknown key "gpu"'),
          ),
        ),
      );
      expect(
        () => CubeResourceLimits.fromYaml(
          loadYaml('limits: {cpu: "50%", net: fast}'),
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('limits: unknown key "net"'),
          ),
        ),
      );
    });
  });
}
