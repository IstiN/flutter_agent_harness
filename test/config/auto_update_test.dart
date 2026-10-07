/// The `auto_update` scalar (issue #1377): the strict tri-state parse
/// (`true`/`false`/`"notify"` — anything else throws [ConfigException]),
/// the top-level key registry, the config service's mirrored validator
/// (the pure core cannot import cli_config.dart — pinned to it here), and
/// the persistence round-trip through `saveCliConfig` (defaults are never
/// written). Mirrors `links_section_test.dart` + the
/// `pins against cli_config.dart` group of `config_service_test.dart`.
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/cli_config.dart';
import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:flutter_agent_harness/src/parity/settings_registry.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _globalConfig = '/home/.fah/config.yaml';

const _base = '''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
mode: code
approvalMode: yolo
''';

/// The exact message both parsers must throw (single source: the contract
/// wording; the service mirror is pinned to the same bytes).
String autoUpdateError(Object got) =>
    '"auto_update" must be true, false, or "notify", got: $got';

void main() {
  group('autoUpdateModeFromYaml', () {
    test('absent parses as notify (the default is never written)', () {
      expect(autoUpdateModeFromYaml(null), AutoUpdateMode.notify);
    });

    test('true parses as on, false as off', () {
      expect(autoUpdateModeFromYaml(true), AutoUpdateMode.on);
      expect(autoUpdateModeFromYaml(false), AutoUpdateMode.off);
    });

    test('the "notify" string parses as notify', () {
      expect(autoUpdateModeFromYaml('notify'), AutoUpdateMode.notify);
    });

    test('junk throws ConfigException with the exact message', () {
      // A bare `yes` is a yaml STRING (the yaml package has no 1.1 bools),
      // a quoted 'true' stays a string, numbers and maps are junk too.
      expect(
        () => autoUpdateModeFromYaml('yes'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            autoUpdateError('yes'),
          ),
        ),
      );
      expect(
        () => autoUpdateModeFromYaml('true'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            autoUpdateError('true'),
          ),
        ),
      );
      expect(
        () => autoUpdateModeFromYaml(1),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            autoUpdateError(1),
          ),
        ),
      );
      final map = loadYaml('auto_update: {a: 1}')['auto_update'];
      expect(
        () => autoUpdateModeFromYaml(map),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            autoUpdateError(map),
          ),
        ),
      );
    });
  });

  group('CliConfig.fromYaml', () {
    Object? valueOf(String doc) => (loadYaml(doc) as YamlMap)['auto_update'];

    test('parses every legal tri-state value', () {
      expect(
        CliConfig.fromYaml(loadYaml('auto_update: true') as YamlMap).autoUpdate,
        AutoUpdateMode.on,
      );
      expect(
        CliConfig.fromYaml(
          loadYaml('auto_update: false') as YamlMap,
        ).autoUpdate,
        AutoUpdateMode.off,
      );
      expect(
        CliConfig.fromYaml(
          loadYaml("auto_update: 'notify'") as YamlMap,
        ).autoUpdate,
        AutoUpdateMode.notify,
      );
      expect(
        CliConfig.fromYaml(loadYaml('provider: anthropic') as YamlMap)
            .autoUpdate,
        AutoUpdateMode.notify,
      );
    });

    test('junk throws ConfigException at boot', () {
      for (final doc in [
        'auto_update: yes',
        "auto_update: 'true'",
        'auto_update: 1',
        'auto_update: {a: 1}',
      ]) {
        expect(
          () => CliConfig.fromYaml(loadYaml(doc) as YamlMap),
          throwsA(isA<ConfigException>()),
          reason: doc,
        );
      }
      // The parser and its node agree on what it saw.
      expect(
        () => autoUpdateModeFromYaml(valueOf('auto_update: 1')),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            autoUpdateError(1),
          ),
        ),
      );
    });
  });

  group('config service', () {
    test('auto_update is a known top-level key', () {
      expect(configTopLevelKeys, contains('auto_update'));
    });

    test('auto_update is classified by the settings registry', () {
      expect(settingForYamlKey('auto_update'), SharedSetting.autoUpdate);
    });

    test('the mirror validator agrees with the real parser', () {
      // The service cannot import cli_config.dart (dart:io) — this pin
      // keeps the mirrored scalar rule from drifting: both accept the
      // same values and both junk throws carry the same bytes.
      for (final value in const [true, false, 'notify', 'yes', 'true', 1]) {
        void parse() => autoUpdateModeFromYaml(value);
        void validate() => validateAutoUpdateScalar(value);
        final legal = value is bool || value == 'notify';
        if (legal) {
          expect(parse, returnsNormally);
          expect(validate, returnsNormally);
        } else {
          final message = autoUpdateError(value);
          expect(
            parse,
            throwsA(
              isA<ConfigException>().having(
                (e) => e.message,
                'message',
                message,
              ),
            ),
          );
          expect(
            validate,
            throwsA(
              isA<ConfigException>().having(
                (e) => e.message,
                'message',
                message,
              ),
            ),
          );
        }
      }
    });

    late MemoryExecutionEnv env;
    late ConfigService service;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/work');
      service = ConfigService(env: env, homeDir: '/home');
    });

    test('a legal value writes to the global file and reads back', () async {
      await env.writeFile(_globalConfig, _base);
      await service.set('auto_update', 'true');
      final readBack = await service.get('auto_update');
      expect(readBack.found, isTrue);
      expect(readBack.display, 'true');
      expect(readBack.scope, 'global');
      // The yaml boolean persists verbatim — the next boot parses `on`.
      final text = (await env.readTextFile(_globalConfig)).getOrThrow();
      expect(text, contains('auto_update: true\n'));
      final report = await service.check();
      expect(report.errors, isEmpty);
    });

    test('junk is refused and nothing is persisted', () async {
      await env.writeFile(_globalConfig, _base);
      await expectLater(
        service.set('auto_update', 'yes'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains(autoUpdateError('yes')),
          ),
        ),
      );
      final readBack = await service.get('auto_update');
      expect(readBack.found, isFalse);
      // The check surfaces a hand-edited junk value as a named error too.
      await env.writeFile(_globalConfig, '$_base\nauto_update: yes\n');
      final report = await service.check();
      expect(report.errors, isNotEmpty);
      expect(
        report.errors.map((e) => e.message),
        everyElement(contains('"auto_update" must be true, false, or')),
      );
    });
  });

  group('saveCliConfig round-trip', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-auto-update-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    Future<String> savedText(CliConfig config) async {
      await saveCliConfig(tmp.path, config);
      return File('${tmp.path}/.fah/config.yaml').readAsStringSync();
    }

    test('a non-default mode persists and loads back', () async {
      final text = await savedText(
        CliConfig(autoUpdate: AutoUpdateMode.on),
      );
      expect(text, contains('auto_update: true\n'));
      expect(loadCliConfig(tmp.path).autoUpdate, AutoUpdateMode.on);

      await savedText(CliConfig(autoUpdate: AutoUpdateMode.off));
      expect(loadCliConfig(tmp.path).autoUpdate, AutoUpdateMode.off);
      expect(
        File('${tmp.path}/.fah/config.yaml').readAsStringSync(),
        contains('auto_update: false\n'),
      );
    });

    test('the notify default is never written', () async {
      final text = await savedText(CliConfig());
      expect(text, isNot(contains('auto_update')));
      expect(loadCliConfig(tmp.path).autoUpdate, AutoUpdateMode.notify);
    });
  });
}
