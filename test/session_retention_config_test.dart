/// gh-1746 — `sessions.retention` config parse (AC1, AC2 gate).
///
/// The section is TOLERANT like `spills:`: unknown keys and mistyped
/// scalars become notes on the config, never boot failures. Absent
/// section == defaults == NO cap, nothing is ever auto-deleted.
@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/session_retention.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('SessionRetentionConfig defaults', () {
    test('defaults carry no cap', () {
      const config = SessionRetentionConfig();
      expect(config.maxTotalBytes, 0);
      expect(config.minAgeDays, 14);
      expect(config.keepNamed, isTrue);
      expect(config.sweep, SessionRetentionSweepMode.boot);
      expect(config.notes, isEmpty);
      expect(config.hasCap, isFalse);
    });

    test('absent yaml node == defaults (AC1)', () {
      final config = SessionRetentionConfig.fromYaml(null);
      expect(config.maxTotalBytes, 0);
      expect(config.minAgeDays, 14);
      expect(config.keepNamed, isTrue);
      expect(config.sweep, SessionRetentionSweepMode.boot);
      expect(config.notes, isEmpty);
    });

    test('a non-map node degrades to defaults with a note, never throws', () {
      final config = SessionRetentionConfig.fromYaml(42);
      expect(config.hasCap, isFalse);
      expect(config.notes, isNotEmpty);
    });
  });

  group('SessionRetentionConfig.fromYaml', () {
    Object? parse(String yaml) => loadYaml(yaml);

    test('valid section parses all keys', () {
      final config = SessionRetentionConfig.fromYaml(
        parse('maxTotalBytes: 1000\nminAgeDays: 3\nkeepNamed: false\n'
            'sweep: off'),
      );
      expect(config.maxTotalBytes, 1000);
      expect(config.minAgeDays, 3);
      expect(config.keepNamed, isFalse);
      expect(config.sweep, SessionRetentionSweepMode.off);
      expect(config.hasCap, isTrue);
      expect(config.notes, isEmpty);
    });

    test('zero maxTotalBytes means no cap', () {
      final config = SessionRetentionConfig.fromYaml(
        parse('maxTotalBytes: 0'),
      );
      expect(config.maxTotalBytes, 0);
      expect(config.hasCap, isFalse);
      expect(config.notes, isEmpty);
    });

    test('mistyped scalars fall back with notes (tolerant)', () {
      final config = SessionRetentionConfig.fromYaml(
        parse('maxTotalBytes: huge\nminAgeDays: soon\nkeepNamed: maybe'),
      );
      expect(config.maxTotalBytes, 0);
      expect(config.minAgeDays, 14);
      expect(config.keepNamed, isTrue);
      expect(config.notes.length, 3);
      expect(config.notes.first, contains('maxTotalBytes'));
    });

    test('negative maxTotalBytes clamps to 0 (no cap) with a note', () {
      final config = SessionRetentionConfig.fromYaml(
        parse('maxTotalBytes: -5'),
      );
      expect(config.hasCap, isFalse);
      expect(config.notes, isNotEmpty);
    });

    test('unknown sweep mode falls back to boot with a note', () {
      final config = SessionRetentionConfig.fromYaml(parse('sweep: nightly'));
      expect(config.sweep, SessionRetentionSweepMode.boot);
      expect(config.notes, isNotEmpty);
    });

    test('unknown keys are noted and ignored, never boot failures', () {
      final config = SessionRetentionConfig.fromYaml(
        parse('maxTotalBytes: 10\narchive: true'),
      );
      expect(config.maxTotalBytes, 10);
      expect(config.notes.single, contains('archive'));
    });
  });

  group('SessionsConfig', () {
    test('absent node parses to defaults', () {
      final config = SessionsConfig.fromYaml(null);
      expect(config.retention.hasCap, isFalse);
      expect(config.notes, isEmpty);
      expect(config.isEmpty, isTrue);
    });

    test('the retention block parses through the sessions wrapper', () {
      final config = SessionsConfig.fromYaml(
        loadYaml('retention:\n  maxTotalBytes: 2048\n  sweep: off'),
      );
      expect(config.retention.maxTotalBytes, 2048);
      expect(config.retention.sweep, SessionRetentionSweepMode.off);
      expect(config.isEmpty, isFalse);
    });

    test('unknown members of the sessions section are noted', () {
      final config = SessionsConfig.fromYaml(loadYaml('garbage: 1'));
      expect(config.retention.hasCap, isFalse);
      expect(config.notes.single, contains('garbage'));
    });

    test('toYaml renders only non-default sections, round-trips', () {
      expect(const SessionsConfig().toYaml(), isEmpty);

      const config = SessionsConfig(
        retention: SessionRetentionConfig(maxTotalBytes: 4096),
      );
      final rendered = config.toYaml();
      expect(rendered, startsWith('sessions:'));
      expect(rendered, contains('maxTotalBytes: 4096'));
      final reparsed = SessionsConfig.fromYaml(
        loadYaml(rendered),
      );
      expect(reparsed.retention.maxTotalBytes, 4096);
      expect(reparsed.retention.minAgeDays, 14);
    });
  });
}
