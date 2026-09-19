// The `--pi` harness-mode plumbing (issue #679), pure-decision slices:
// argv parsing, the flag > env > config resolution ladder, and the strict
// `agent.mode` config parsing. The wiring-side behavior (tool scope pin +
// prompt strip + boot print) lives in pi_mode_gate_test.dart.

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('--pi flag parsing', () {
    test('--pi sets piMode on the parsed args', () {
      final args = parseCliArgs(const ['--pi']) as CliArgs;
      expect(args.piMode, isTrue);
      expect(args.isHeadless, isFalse);
    });

    test('default is off; other flags do not bleed into it', () {
      final args = parseCliArgs(const ['--model', 'm']) as CliArgs;
      expect(args.piMode, isFalse);
    });

    test('--pi composes with a headless prompt', () {
      final args = parseCliArgs(const ['--pi', '-p', 'hello']) as CliArgs;
      expect(args.piMode, isTrue);
      expect(args.prompt, 'hello');
    });

    test('--pi does not consume the next argument as a value', () {
      final args = parseCliArgs(const ['--pi', '--model', 'm']) as CliArgs;
      expect(args.piMode, isTrue);
      expect(args.model, 'm');
    });
  });

  group('resolveHarnessMode (flag > env > config, AC3)', () {
    test('no source at all resolves to null (default mode)', () {
      expect(resolveHarnessMode(), isNull);
    });

    test('flag wins over env', () {
      expect(
        resolveHarnessMode(
          flag: true,
          env: const {piModeEnvVar: '0'},
          configMode: 'default',
        ),
        'pi',
      );
    });

    test('env wins over config', () {
      expect(
        resolveHarnessMode(
          flag: false,
          env: const {piModeEnvVar: '1'},
          configMode: 'default',
        ),
        'pi',
      );
    });

    test('config wins when flag and env are silent', () {
      expect(resolveHarnessMode(configMode: 'pi', env: const {}), 'pi');
    });

    test('FA_PI_MODE truthy spellings', () {
      for (final value in const {'1', 'true', 'yes', 'on'}) {
        expect(
          resolveHarnessMode(env: {piModeEnvVar: value}),
          'pi',
          reason: 'FA_PI_MODE=$value should enable pi mode',
        );
      }
    });

    test('FA_PI_MODE non-truthy and empty are off', () {
      for (final value in const {'0', 'false', 'no', 'off', ''}) {
        expect(
          resolveHarnessMode(env: {piModeEnvVar: value}),
          isNull,
          reason: 'FA_PI_MODE=$value should NOT enable pi mode',
        );
      }
    });

    test('config default normalizes to null', () {
      expect(resolveHarnessMode(configMode: 'default'), isNull);
    });

    test('unknown config mode is a usage error naming the value', () {
      expect(
        () => resolveHarnessMode(configMode: 'omp'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('omp'),
          ),
        ),
      );
    });

    test('unknown env values are simply off (the env twin is boolean)', () {
      expect(
        resolveHarnessMode(env: const {piModeEnvVar: 'compaction'}),
        isNull,
      );
    });
  });

  group('piToolsOverride tool surface', () {
    test('exactly the pi benchmark set', () {
      expect(piToolIds, unorderedEquals(['read', 'write', 'edit', 'bash']));
    });

    test('override turns every other known tool off', () {
      final override = piToolsOverride();
      for (final id in knownToolIds) {
        expect(
          override.tools[id],
          piToolIds.contains(id),
          reason: '$id should be ${piToolIds.contains(id) ? "on" : "off"}',
        );
      }
    });

    test('serializes as the runtime tools envelope', () {
      final override = piToolsOverride();
      expect(override.toJson()['tools'], isA<Map<String, dynamic>>());
    });
  });

  group('agent.mode config parsing', () {
    test('mode: pi parses to pi', () {
      final config = CliConfig.fromYaml(
        loadYaml('agent:\n  mode: pi\n') as YamlMap,
      );
      expect(config.agentMode, 'pi');
    });

    test('mode: default normalizes to null', () {
      final config = CliConfig.fromYaml(
        loadYaml('agent:\n  mode: default\n') as YamlMap,
      );
      expect(config.agentMode, isNull);
    });

    test('absent mode stays null', () {
      final config = CliConfig.fromYaml(loadYaml('memory: {}\n') as YamlMap);
      expect(config.agentMode, isNull);
    });

    test('unknown mode throws at boot', () {
      expect(
        () => CliConfig.fromYaml(loadYaml('agent:\n  mode: omp\n') as YamlMap),
        throwsA(isA<ConfigException>()),
      );
    });

    test('agent section with the cap keeps both fields', () {
      final config = CliConfig.fromYaml(
        loadYaml('agent:\n  mode: pi\n  contextWindowCap: 256000\n') as YamlMap,
      );
      expect(config.agentMode, 'pi');
      expect(config.contextWindowCap, 256000);
    });
  });

  group('validateAgentSection (shared strict validator)', () {
    test('accepts mode pi', () {
      validateAgentSection(loadYaml('mode: pi\n') as YamlMap);
    });

    test('accepts mode default', () {
      validateAgentSection(loadYaml('mode: default\n') as YamlMap);
    });

    test('rejects an unknown mode', () {
      expect(
        () => validateAgentSection(loadYaml('mode: omp\n') as YamlMap),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects a non-string mode', () {
      expect(
        () => validateAgentSection(loadYaml('mode: 1\n') as YamlMap),
        throwsA(isA<ConfigException>()),
      );
    });

    test('still rejects unknown keys and a bad cap', () {
      expect(
        () => validateAgentSection(loadYaml('bogus: 1\n') as YamlMap),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => validateAgentSection(
          loadYaml('contextWindowCap: 16383\n') as YamlMap,
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
