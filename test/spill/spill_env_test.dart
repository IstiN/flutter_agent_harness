// gh-1604 item 4 — the bench env knob for the tool-output cap.
//
// The spill pipeline (issue #678) already caps single tool outputs at M
// chars with a `[... N chars omitted ...]` marker and a read-the-spill-file
// affordance — but it only attaches when a `spills:` yaml section exists.
// Bench runs configure through the environment:
// `FAH_SPILL_THRESHOLD` enables/tunes the cap for one run (and `0`
// explicitly disables it), without touching any config file.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('resolveRunSpillsConfig (gh-1604 item 4)', () {
    test('no section + no env → null (legacy: hook not attached)', () {
      expect(resolveRunSpillsConfig(null, {}), isNull);
    });

    test('no section + env set → enabled with the env threshold', () {
      final config = resolveRunSpillsConfig(null, {
        spillThresholdEnvVar: '4096',
      });
      expect(config, isNotNull);
      expect(config!.isActive, isTrue);
      expect(config.threshold, 4096);
      // The preview bounds stay the shared defaults.
      expect(config.headChars, 2000);
      expect(config.tailChars, 2000);
    });

    test('env wins over the configured threshold', () {
      final config = resolveRunSpillsConfig(
        const SpillsConfig(threshold: 8192),
        {spillThresholdEnvVar: '2048'},
      );
      expect(config!.threshold, 2048);
    });

    test('env 0 explicitly disables a configured section', () {
      final config = resolveRunSpillsConfig(
        const SpillsConfig(threshold: 8192),
        {spillThresholdEnvVar: '0'},
      );
      expect(config!.isActive, isFalse);
    });

    test('the env override keeps the section tolerant-parse notes '
        '(gh-1604 rework)', () {
      // The notes are the boot diagnostics (clamped bounds, unknown
      // keys) — an env retune must not silently drop them on exactly
      // the bench runs where config is being debugged.
      const section = SpillsConfig(
        threshold: 8192,
        notes: ['spills.headChars: 10 below minimum 200, clamped'],
      );
      final config = resolveRunSpillsConfig(section, {
        spillThresholdEnvVar: '2048',
      });
      expect(config!.threshold, 2048);
      expect(config.notes, section.notes);
    });

    test('junk env is ignored — the config applies untouched', () {
      final section = const SpillsConfig(threshold: 8192);
      expect(
        resolveRunSpillsConfig(section, {spillThresholdEnvVar: 'big'}),
        same(section),
      );
      expect(
        resolveRunSpillsConfig(null, {spillThresholdEnvVar: 'big'}),
        isNull,
      );
    });

    test('the full end-to-end preview shape still holds under the env cap', () {
      final config = resolveRunSpillsConfig(null, {
        spillThresholdEnvVar: '1000',
      })!;
      expect(shouldSpill('x' * 1001, config), isTrue);
      expect(shouldSpill('x' * 1000, config), isFalse);
      // A body the preview bounds cover renders ONCE — never duplicated
      // with a negative omitted count (the pre-gh-1604 bug this pins).
      final covered = buildPreview(
        'h' * 600 + 'm' * 300 + 't' * 600,
        spillPath: '.fah/spills/s/1.txt',
        config: config,
      );
      expect(covered, isNot(contains('chars omitted')));
      expect(('m' * 300).allMatches(covered).length, 1);
      expect(covered, contains('[read the spill file above'));
      // A body longer than the bounds keeps the marker with the TRUE
      // omitted size.
      final marked = buildPreview(
        'h' * 2000 + 'm' * 300 + 't' * 2000,
        spillPath: '.fah/spills/s/2.txt',
        config: config,
      );
      expect(marked, contains('[... 300 chars omitted ...]'));
    });
  });
}
