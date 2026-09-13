/// The completeness gate (issue #288 AC1/AC6): every top-level key the
/// REAL yaml parsers read must be classified in the settings registry —
/// either owned by a [SharedSetting] (CLI settings TUI + app surface) or
/// listed in [fileOnlyConfigKeys] with a WHY. A new yaml key landing
/// without a classification is RED; that is the ratchet.
///
/// The key set is extracted from the parser SOURCES (not hand-copied), so
/// adding `map['newKey']` to `CliConfig.fromYaml` (or the roles parser)
/// without registering it fails here. This is a VM-only test (reads files).
library;

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// The parser sources whose `map['key']` reads define the real schema.
const _parserSources = [
  'lib/src/cli/cli_config.dart',
  'lib/src/model_roles/roles_config.dart',
];

void main() {
  final bodies = [
    for (final path in _parserSources) File(path).readAsStringSync(),
  ];

  /// Top-level keys the real parsers read. Leaf reads inside section
  /// bodies (e.g. a chain entry's `map['model']`) coincide with top-level
  /// names, so the extraction stays sound for the gate's purpose.
  final parserReadKeys = <String>{
    for (final body in bodies)
      for (final match in RegExp(r"map\['([a-zA-Z]+)'\]").allMatches(body))
        match.group(1)!,
  };

  /// The full universe the gate walks: parser reads ∪ the config service's
  /// declared key set (the service also answers `get`/`set` for them).
  final allKeys = <String>{...parserReadKeys, ...configTopLevelKeys};

  group('yaml schema completeness (AC1)', () {
    test('the parser sources actually describe a schema', () {
      // Guard the guard: if the regex or the sources break, the gate must
      // not silently pass over an empty key set.
      expect(parserReadKeys, containsAll(['provider', 'roles', 'compaction']));
      expect(parserReadKeys.length, greaterThan(20));
    });

    test('every parsed yaml key is classified', () {
      final unclassified = [
        for (final key in allKeys)
          if (!isClassifiedYamlKey(key)) key,
      ]..sort();
      expect(
        unclassified,
        isEmpty,
        reason:
            'Unclassified yaml keys: $unclassified. Every top-level key '
            'the parsers read must be owned by a SharedSetting '
            '(yamlKeyCoverage) or listed in fileOnlyConfigKeys with a WHY. '
            'See lib/src/parity/settings_registry.dart.',
      );
    });

    test('classification is not accidental: an unknown key is rejected', () {
      // AC6 negative half: the predicate the gate rides must return false
      // for a key nobody classified (a new key landing in the parser
      // cannot inherit a neighbor's classification).
      expect(isClassifiedYamlKey('brand_new_setting'), isFalse);
      expect(settingForYamlKey('brand_new_setting'), isNull);
      expect(fileOnlyConfigKeys.containsKey('brand_new_setting'), isFalse);
    });

    test('every SharedSetting owns a yaml key or is a documented non-yaml',
        () {
      for (final setting in SharedSetting.values) {
        final ownsYaml = sharedSettingMetadata[setting]!.yamlKeys.isNotEmpty;
        expect(
          ownsYaml || nonYamlSettings.contains(setting),
          isTrue,
          reason:
              '${setting.name}: a SharedSetting with no yaml key covers '
              'nothing the parsers read — classify its yaml section, add it '
              'to nonYamlSettings with a WHY, or remove the entry.',
        );
      }
    });

    test('the audit table covers every key exactly once', () {
      // The table attached to the PR is generated from the same data; the
      // assertion keeps the mapping single-owner (no two SharedSettings
      // fight over one key).
      final owners = <String, SharedSetting>{};
      for (final setting in SharedSetting.values) {
        for (final key in sharedSettingMetadata[setting]!.yamlKeys) {
          expect(
            owners.containsKey(key),
            isFalse,
            reason: 'yaml key "$key" is claimed by both '
                '${owners[key]?.name} and ${setting.name}.',
          );
          owners[key] = setting;
        }
      }
      final sharedKeys = {...owners.keys, ...fileOnlyConfigKeys.keys};
      expect(sharedKeys, equals(allKeys));
      expect(
        owners.length + fileOnlyConfigKeys.length,
        allKeys.length,
        reason: 'N keys = shared(${owners.length}) + '
            'file-only(${fileOnlyConfigKeys.length})',
      );
    });
  });

  group('CLI-only classification discipline', () {
    test('every CLI-only setting has a user-readable justification', () {
      for (final setting in cliOnlySettings) {
        expect(
          cliOnlyJustifications[setting],
          isNotNull,
          reason:
              '${setting.name} is CLI-only but has no justification — the '
              'WHY must exist in code AND be user-visible (the app renders '
              'it in its CLI-only settings section).',
        );
      }
    });

    test('no justification exists for a non-CLI-only setting', () {
      for (final setting in cliOnlyJustifications.keys) {
        expect(
          cliOnlySettings.contains(setting),
          isTrue,
          reason:
              '${setting.name} has a CLI-only justification but is not in '
              'cliOnlySettings — stale marker, remove it.',
        );
      }
    });

    test('file-only keys carry a non-empty WHY', () {
      for (final entry in fileOnlyConfigKeys.entries) {
        expect(
          entry.value.trim(),
          isNotEmpty,
          reason: '"${entry.key}" is file-only without a WHY.',
        );
      }
    });
  });

  group('surface audit completeness (AC3/AC5)', () {
    test('every SharedSetting has a surface classification', () {
      for (final setting in SharedSetting.values) {
        expect(
          settingSurfaces.containsKey(setting),
          isTrue,
          reason:
              '${setting.name}: no settingSurfaces entry — every shared '
              'setting needs {macOS, iOS, web, extension} applicability.',
        );
      }
    });

    test('absent surfaces always name a capability (E3)', () {
      for (final entry in settingSurfaces.entries) {
        final surfaces = entry.value;
        final absent = !surfaces.macos ||
            !surfaces.ios ||
            !surfaces.web ||
            !surfaces.extensionPanel;
        if (absent) {
          expect(
            (surfaces.gapWhy ?? '').trim(),
            isNotEmpty,
            reason:
                '${entry.key.name} is absent from a surface without a '
                'capability-named WHY (E3: name the capability, never '
                '"didn\'t get to it").',
          );
        }
      }
    });

    test('CLI-only settings are absent from every app surface', () {
      for (final setting in cliOnlySettings) {
        final surfaces = settingSurfaces[setting]!;
        expect(
          surfaces.anyApp || surfaces.extensionPanel,
          isFalse,
          reason:
              '${setting.name} is in cliOnlySettings but a surface claims '
              'it — either implement it there or fix the classification.',
        );
      }
    });
  });
}
