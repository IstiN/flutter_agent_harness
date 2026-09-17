import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  group('CliConfig', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-config-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns defaults when config file is missing', () {
      final config = loadCliConfig(tmp.path);
      expect(config.providerKind, 'openai-completions');
      expect(config.modelId, 'openai/gpt-4o-mini');
      expect(config.baseUrl, 'https://openrouter.ai/api/v1');
      expect(config.mode, 'code');
    });

    test('loads saved config', () async {
      final original = CliConfig(
        providerKind: 'anthropic',
        modelId: 'claude-sonnet-4',
        baseUrl: 'https://api.anthropic.com',
        mode: 'architect',
      );
      await saveCliConfig(tmp.path, original);
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.providerKind, 'anthropic');
      expect(loaded.modelId, 'claude-sonnet-4');
      expect(loaded.baseUrl, 'https://api.anthropic.com');
      expect(loaded.mode, 'architect');
    });

    test('falls back to defaults on malformed yaml', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('not yaml: [unclosed');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.modelId, 'openai/gpt-4o-mini');
    });

    test('a yaml-hostile provider entry name survives the roundtrip', () async {
      // Issue #555: `name: ?` written bare throws "Mapping keys are not
      // allowed here" on load — the next start fell back to defaults and
      // the user's saved config was effectively lost.
      final original = CliConfig().withCustomProviders([
        CustomProviderEntry(
          name: '?',
          apiType: 'openai',
          baseUrl: 'https://x.example.com/v1',
          modelId: 'm1',
        ),
      ]);
      await saveCliConfig(tmp.path, original);
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.customProviders.single.name, '?');
      expect(loaded.customProviders.single.baseUrl, 'https://x.example.com/v1');
      expect(loaded.customProviders.single.modelId, 'm1');
    });
    test('approval settings default when absent from the file', () {
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.approvalMode, 'yolo');
      expect(loaded.allowedTools, isEmpty);
    });

    test('round-trips approval settings', () async {
      final original = CliConfig(
        approvalMode: 'write',
        allowedTools: const ['bash', 'write'],
      );
      await saveCliConfig(tmp.path, original);
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.approvalMode, 'write');
      expect(loaded.allowedTools, ['bash', 'write']);
    });

    test('round-trips an empty always-allow set', () async {
      await saveCliConfig(tmp.path, CliConfig(approvalMode: 'always-ask'));
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.approvalMode, 'always-ask');
      expect(loaded.allowedTools, isEmpty);
    });

    test('loads without model roles when the section is absent', () {
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.modelRoles, isNull);
    });

    test('round-trips model roles, overrides, and retry knobs', () async {
      final roles = ModelRolesConfig.fromYaml(
        loadYaml('''
roles:
  default:
    - openrouter/anthropic/claude-sonnet-4
    - provider: openai
      model: gpt-4o
  smol:
    - openrouter/openai/gpt-4o-mini
modelOverrides:
  - path: ~/work/acme
    roles:
      plan:
        - anthropic/claude-opus-4-5
retry:
  retriesPerEntry: 3
''')
            as YamlMap,
      );
      await saveCliConfig(tmp.path, CliConfig(modelRoles: roles));
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.modelId, 'openai/gpt-4o-mini'); // legacy fields intact
      final loadedRoles = loaded.modelRoles!;
      expect(loadedRoles.roles['default'], hasLength(2));
      expect(loadedRoles.roles['smol']!.single.modelId, 'openai/gpt-4o-mini');
      expect(loadedRoles.pathOverrides.single.pattern, '~/work/acme');
      expect(loadedRoles.retry.retriesPerEntry, 3);
      // Full yaml fidelity: emitting again reproduces the same document.
      expect(loaded.toYaml(), CliConfig(modelRoles: roles).toYaml());
    });

    test(
      'surfaces invalid model roles instead of resetting to defaults',
      () async {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('''
provider: anthropic
roles:
  bogus-role:
    - openai/gpt-4o
''');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('unknown model role'),
            ),
          ),
        );
      },
    );

    test('loads without ttsr when the section is absent', () {
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.ttsr, isNull);
    });

    test('round-trips the ttsr section', () async {
      final ttsr = TtsrConfig.fromYaml(
        loadYaml('''
contextMode: keep
rules:
  - name: no-console
    pattern: "console\\\\.log\\\\("
    body: Do not use console.log.
    scope: [text, tool:edit]
'''),
        sourcePath: '~/.fah/config.yaml',
      );
      await saveCliConfig(tmp.path, CliConfig(ttsr: ttsr));
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.modelId, 'openai/gpt-4o-mini'); // legacy fields intact
      final loadedTtsr = loaded.ttsr!;
      expect(loadedTtsr.settings.contextMode, TtsrContextMode.keep);
      expect(loadedTtsr.rules.single.name, 'no-console');
      expect(loadedTtsr.rules.single.patterns, [r'console\.log\(']);
      expect(loadedTtsr.rules.single.scope.toolNames, {'edit'});
      // Full yaml fidelity: emitting again reproduces the same document.
      expect(loaded.toYaml(), CliConfig(ttsr: ttsr).toYaml());
    });

    test('surfaces an invalid ttsr section instead of dropping it', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('''
provider: anthropic
ttsr:
  contextMode: sideways
''');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('ttsr.contextMode'),
          ),
        ),
      );
    });

    test('loads without prompt overrides when the section is absent', () {
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.promptOverrides, isEmpty);
    });

    test('round-trips the prompts section', () async {
      await saveCliConfig(
        tmp.path,
        CliConfig(
          promptOverrides: const {
            'system': '~/prompts/my_system.md',
            'cli/mode_review': 'You are a terse reviewer.\nNever refactor.',
            'compaction/summary': './prompts/sum.md',
          },
        ),
      );
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.modelId, 'openai/gpt-4o-mini'); // legacy fields intact
      expect(loaded.promptOverrides, {
        'system': '~/prompts/my_system.md',
        'cli/mode_review': 'You are a terse reviewer.\nNever refactor.',
        'compaction/summary': './prompts/sum.md',
      });
      // Full yaml fidelity: emitting again reproduces the same document.
      const raw = {
        'system': '~/prompts/my_system.md',
        'cli/mode_review': 'You are a terse reviewer.\nNever refactor.',
        'compaction/summary': './prompts/sum.md',
      };
      expect(loaded.toYaml(), CliConfig(promptOverrides: raw).toYaml());
    });

    test('parses the prompts section from raw yaml', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('''
provider: google
prompts:
  system: ~/prompts/sys.md
  cli/mode_review: "You are a terse reviewer."
''');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.providerKind, 'google');
      expect(loaded.promptOverrides['system'], '~/prompts/sys.md');
      expect(
        loaded.promptOverrides['cli/mode_review'],
        'You are a terse reviewer.',
      );
    });

    test('surfaces an invalid prompts section instead of dropping it', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('''
prompts:
  bogus/name: "text"
''');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown prompt override'),
          ),
        ),
      );
    });

    test('parses providerTimeouts and round-trips them', () async {
      final original = CliConfig(
        providerTimeouts: const ProviderTimeoutsOverride(
          connect: Duration(seconds: 120),
          streamIdle: Duration(minutes: 5),
        ),
      );
      await saveCliConfig(tmp.path, original);
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.providerTimeouts?.connect, const Duration(seconds: 120));
      expect(loaded.providerTimeouts?.streamIdle, const Duration(minutes: 5));
    });

    test('providerTimeouts defaults to null when absent', () {
      expect(loadCliConfig(tmp.path).providerTimeouts, isNull);
    });

    test('rejects a malformed providerTimeouts section', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('providerTimeouts:\n  connectTimeoutMs: "x"\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('connectTimeoutMs'),
          ),
        ),
      );
    });

    test('rejects unknown providerTimeouts keys', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('providerTimeouts:\n  bogusMs: 5\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('bogusMs'),
          ),
        ),
      );
    });

    test('parses the images section and round-trips it', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync(
        'images:\n  registry: false\n  maxPerRequest: 4\n',
      );
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.images?.enabled, isFalse);
      expect(loaded.images?.maxPerRequest, 4);

      await saveCliConfig(tmp.path, loaded);
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.images?.enabled, isFalse);
      expect(reloaded.images?.maxPerRequest, 4);
    });

    test('images defaults to null when absent', () {
      expect(loadCliConfig(tmp.path).images, isNull);
    });

    test('parses the power section and round-trips it (issue #325)', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('power:\n  sleepPrevention: system\n');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.powerSleepPrevention, PowerAssertionLevel.system);

      await saveCliConfig(tmp.path, loaded);
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.powerSleepPrevention, PowerAssertionLevel.system);
    });

    test('parses the power hold lifecycle and round-trips it (#326)', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync(
        'power:\n  sleepPrevention: display\n  hold: session\n',
      );
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.powerSleepPrevention, PowerAssertionLevel.display);
      expect(loaded.powerHold, PowerAssertionHold.session);

      await saveCliConfig(tmp.path, loaded);
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.powerSleepPrevention, PowerAssertionLevel.display);
      expect(reloaded.powerHold, PowerAssertionHold.session);
      // The per-run default stays absent when not configured.
      expect(loadCliConfig(tmp.path).powerHold, PowerAssertionHold.session);
    });

    test(
      'hold alone round-trips (level stays absent → idle default)',
      () async {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('power:\n  hold: session\n');
        final loaded = loadCliConfig(tmp.path);
        expect(loaded.powerSleepPrevention, isNull);
        expect(loaded.powerHold, PowerAssertionHold.session);
        await saveCliConfig(tmp.path, loaded);
        expect(loadCliConfig(tmp.path).powerHold, PowerAssertionHold.session);
      },
    );

    test('rejects a bad power.hold value', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('power:\n  hold: forever\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"power.hold" must be per-run or session'),
          ),
        ),
      );
    });

    test('power defaults to null when absent (the host applies idle)', () {
      expect(loadCliConfig(tmp.path).powerSleepPrevention, isNull);
    });

    test('rejects a bad power.sleepPrevention value', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('power:\n  sleepPrevention: sometimes\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains(
              '"power.sleepPrevention" must be off, idle, display or '
              'system',
            ),
          ),
        ),
      );
    });

    test('rejects unknown images keys', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('images:\n  bogus: 1\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('images'),
          ),
        ),
      );
    });

    test('rejects a malformed images section', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('images:\n  registry: "yes"\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('images.registry'),
          ),
        ),
      );
      file.writeAsStringSync('images:\n  maxPerRequest: 0\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('images.maxPerRequest'),
          ),
        ),
      );
    });

    test('rejects a non-map images section (issue #195 F1)', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('images: 42\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('images must be a map'),
          ),
        ),
      );
    });

    test('rejects a negative images.maxPerRequest (issue #195 F1)', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('images:\n  maxPerRequest: -3\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('images.maxPerRequest'),
          ),
        ),
      );
    });

    test('an empty images section keeps the defaults (issue #195 F1)', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('images: {}\n');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.images, isNull);
    });

    test('partial images section round-trips with core defaults '
        '(issue #195 F1)', () async {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('images:\n  maxPerRequest: 7\n');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.images?.enabled, isTrue);
      expect(loaded.images?.maxPerRequest, 7);

      await saveCliConfig(tmp.path, loaded);
      final reloaded = loadCliConfig(tmp.path);
      expect(reloaded.images?.enabled, isTrue);
      expect(reloaded.images?.maxPerRequest, 7);
    });

    group('skills section', () {
      test('defaults to granted and shell execution enabled', () {
        final loaded = loadCliConfig(tmp.path);
        expect(loaded.skillsAccess, SkillsAccess.granted);
        expect(loaded.skillsDisableShellExecution, isFalse);
      });

      test('parses granted access', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('skills:\n  access: granted\n');
        final loaded = loadCliConfig(tmp.path);
        expect(loaded.skillsAccess, SkillsAccess.granted);
      });

      test('parses denied access and disabled shell execution', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync(
          'skills:\n  access: denied\n  disableShellExecution: true\n',
        );
        final loaded = loadCliConfig(tmp.path);
        expect(loaded.skillsAccess, SkillsAccess.denied);
        expect(loaded.skillsDisableShellExecution, isTrue);
      });

      test('rejects a non-map skills section', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('skills: not-a-map\n');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('skills must be a map'),
            ),
          ),
        );
      });

      test('rejects an invalid access value', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('skills:\n  access: maybe\n');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('skills.access must be ask'),
            ),
          ),
        );
      });

      test('rejects a non-boolean disableShellExecution value', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('skills:\n  disableShellExecution: "yes"\n');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('skills.disableShellExecution must be a boolean'),
            ),
          ),
        );
      });

      test('rejects unknown skills keys', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('skills:\n  bogus: 1\n');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('unknown "skills" key'),
            ),
          ),
        );
      });

      test('omits skills section with default settings', () {
        expect(CliConfig().toYaml(), isNot(contains('skills:')));
      });

      test('emits skills access when not granted (the default)', () {
        final yaml = CliConfig(skillsAccess: SkillsAccess.denied).toYaml();
        expect(yaml, contains('skills:\n  access: denied'));
        expect(yaml, isNot(contains('disableShellExecution')));
      });

      test('emits disabled shell execution alone when access is ask', () {
        final yaml = CliConfig(skillsDisableShellExecution: true).toYaml();
        expect(yaml, contains('skills:\n  disableShellExecution: true'));
        expect(yaml, isNot(contains('access:')));
      });

      test('emits both skills fields when changed', () {
        final yaml = CliConfig(
          skillsAccess: SkillsAccess.denied,
          skillsDisableShellExecution: true,
        ).toYaml();
        expect(yaml, contains('skills:'));
        expect(yaml, contains('access: denied'));
        expect(yaml, contains('disableShellExecution: true'));
      });

      test('omits jobs section with default settings', () {
        expect(CliConfig().toYaml(), isNot(contains('jobs:')));
      });

      test('emits jobs section only when knobs deviate', () {
        final yaml = CliConfig(
          jobs: const JobsConfig(staleHours: 48, logRetentionDays: 7),
        ).toYaml();
        expect(yaml, contains('jobs:\n  staleHours: 48'));
        expect(yaml, contains('logRetentionDays: 7'));
      });

      group('cube section', () {
        test('absent section parses as null', () {
          expect(loadCliConfig(tmp.path).cube, isNull);
        });

        test('round-trips enabled config path', () async {
          await saveCliConfig(
            tmp.path,
            CliConfig(cube: CubeSettings(configPath: '.fah/cubes/dev.yaml')),
          );
          final loaded = loadCliConfig(tmp.path);
          expect(loaded.cube?.enabled, isTrue);
          expect(loaded.cube?.configPath, '.fah/cubes/dev.yaml');
          // Full yaml fidelity: emitting again reproduces the section.
          expect(
            loaded.toYaml(),
            contains('cube:\n  config: .fah/cubes/dev.yaml\n'),
          );
        });

        test('round-trips disabled without a path', () async {
          await saveCliConfig(
            tmp.path,
            CliConfig(cube: CubeSettings(enabled: false)),
          );
          final loaded = loadCliConfig(tmp.path);
          expect(loaded.cube?.enabled, isFalse);
          expect(loaded.cube?.configPath, isNull);
          expect(loaded.toYaml(), contains('cube:\n  enabled: false\n'));
        });

        test('rejects unknown cube keys', () async {
          final file = File('${tmp.path}/.fah/config.yaml');
          file.createSync(recursive: true);
          file.writeAsStringSync('cube:\n  bogus: 1\n');
          expect(
            () => loadCliConfig(tmp.path),
            throwsA(
              isA<ConfigException>().having(
                (e) => e.message,
                'message',
                contains('unknown "cube" key'),
              ),
            ),
          );
        });

        test('rejects a non-boolean enabled', () async {
          final file = File('${tmp.path}/.fah/config.yaml');
          file.createSync(recursive: true);
          file.writeAsStringSync('cube:\n  enabled: yes-please\n');
          expect(
            () => loadCliConfig(tmp.path),
            throwsA(isA<ConfigException>()),
          );
        });
      });
    });

    group('agent section (issue #273)', () {
      test('absent section leaves the cap null', () {
        final loaded = loadCliConfig(tmp.path);
        expect(loaded.contextWindowCap, isNull);
      });

      test('parses a valid contextWindowCap', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('agent:\n  contextWindowCap: 256000\n');
        final loaded = loadCliConfig(tmp.path);
        expect(loaded.contextWindowCap, 256000);
      });

      test('rejects an unknown agent key', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync(
          'agent:\n  contextWindowCap: 256000\n'
          '  temperature: 0\n',
        );
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('unknown "agent" key'),
            ),
          ),
        );
      });

      test('rejects a non-integer cap', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('agent:\n  contextWindowCap: big\n');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('must be a positive integer'),
            ),
          ),
        );
      });

      test('rejects a cap below the compaction reserve (AC5)', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('agent:\n  contextWindowCap: 16383\n');
        expect(
          () => loadCliConfig(tmp.path),
          throwsA(
            isA<ConfigException>().having(
              (e) => e.message,
              'message',
              contains('at least 16384'),
            ),
          ),
        );
      });

      test('toYaml persists the cap for the round-trip', () {
        final file = File('${tmp.path}/.fah/config.yaml');
        file.createSync(recursive: true);
        file.writeAsStringSync('agent:\n  contextWindowCap: 256000\n');
        final loaded = loadCliConfig(tmp.path);
        expect(
          loaded.withCustomProviders(loaded.customProviders).toYaml(),
          contains('agent:\n  contextWindowCap: 256000'),
        );
      });
    });
  });

  group('provider watchdog overrides', () {
    tearDown(() => providerTimeoutsOverride = null);

    test('defaults apply without an override', () {
      expect(effectiveProviderConnectTimeout, providerConnectTimeout);
      expect(effectiveProviderStreamIdleTimeout, providerStreamIdleTimeout);
    });

    test('the override wins field-wise', () {
      providerTimeoutsOverride = const ProviderTimeoutsOverride(
        connect: Duration(seconds: 7),
      );
      expect(effectiveProviderConnectTimeout, const Duration(seconds: 7));
      // Untouched field keeps the default.
      expect(effectiveProviderStreamIdleTimeout, providerStreamIdleTimeout);
    });
  });

  group('project cube section', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-config-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    void writeProjectConfig(String yaml) {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync(yaml);
    }

    test('missing project file loads as null', () {
      expect(loadProjectCubeSettings(tmp.path), isNull);
    });

    test('parses the project cube section', () {
      writeProjectConfig('cube:\n  config: .fah/cubes/dev.yaml\n');
      final loaded = loadProjectCubeSettings(tmp.path);
      expect(loaded?.enabled, isTrue);
      expect(loaded?.configPath, '.fah/cubes/dev.yaml');
    });

    test('absent section loads as null', () {
      writeProjectConfig('provider: anthropic\n');
      expect(loadProjectCubeSettings(tmp.path), isNull);
    });

    test('invalid section throws ConfigException', () {
      writeProjectConfig('cube:\n  bogus: 1\n');
      expect(
        () => loadProjectCubeSettings(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown "cube" key'),
          ),
        ),
      );
    });
  });

  group('save preserves every parsed section (issue #288 drift)', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-config-save-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test(
      'a caller that carries no static sections keeps them on disk',
      () async {
        // The shape of bin/fah.dart's persistConfig before the fix: the
        // caller re-saves the LOADED config minus the sections it forgot to
        // carry — the file must not lose them.
        final seed = '''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
mode: code
approvalMode: yolo
memory:
  projectPath: ./memory
  userPath: ~/longterm
compaction:
  engine: structured
a2a:
  servers:
    translator:
      url: https://agents.example.com/translator
      token: literal-token
providerTimeouts:
  connectTimeoutMs: 8000
''';
        File('${tmp.path}/.fah/config.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync(seed);
        final loaded = loadCliConfig(tmp.path);

        // The forgetful caller: carries only what persistConfig used to.
        await saveCliConfig(
          tmp.path,
          CliConfig(
            providerKind: loaded.providerKind,
            modelId: loaded.modelId,
            baseUrl: loaded.baseUrl,
            mode: loaded.mode,
            approvalMode: loaded.approvalMode,
          ),
        );

        final saved = loadCliConfig(tmp.path);
        expect(saved.memory?.projectPath, './memory');
        expect(saved.memory?.userPath, '~/longterm');
        expect(saved.compactionEngine, CompactionEngine.structured);
        expect(
          saved.a2a?.servers['translator']?.url,
          'https://agents.example.com/translator',
        );
        expect(saved.providerTimeouts?.connect?.inMilliseconds, 8000);
      },
    );

    test('a rendered section still wins over the disk block', () async {
      final seed = '''
compaction:
  engine: classic
''';
      File('${tmp.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync(seed);

      await saveCliConfig(
        tmp.path,
        CliConfig(compactionEngine: CompactionEngine.structured),
      );

      expect(
        loadCliConfig(tmp.path).compactionEngine,
        CompactionEngine.structured,
      );
    });

    test('compaction.judgeBudgetSeconds round-trips (issue #541)', () async {
      final original = CliConfig(compactionJudgeBudgetSeconds: 300);
      await saveCliConfig(tmp.path, original);
      expect(loadCliConfig(tmp.path).compactionJudgeBudgetSeconds, 300);
    });

    test('compaction.judgeBudgetSeconds defaults to null when absent '
        '(issue #541)', () {
      expect(loadCliConfig(tmp.path).compactionJudgeBudgetSeconds, isNull);
    });

    test('a junk compaction.judgeBudgetSeconds is a strict config error '
        '(issue #541)', () async {
      File('${tmp.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('compaction:\n  judgeBudgetSeconds: soon\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('judgeBudgetSeconds'),
          ),
        ),
      );
    });

    test('a non-positive compaction.judgeBudgetSeconds is a strict config '
        'error (issue #541)', () async {
      File('${tmp.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync('compaction:\n  judgeBudgetSeconds: 0\n');
      expect(() => loadCliConfig(tmp.path), throwsA(isA<ConfigException>()));
    });

    test('the disk a2a block survives verbatim (byte-for-byte)', () async {
      // The block is copied as raw text, never re-rendered from the typed
      // config — `${NAME}` env-token references stay literal (a typed
      // round-trip would materialize the resolved secret into the file).
      final seed = '''
a2a:
  servers:
    translator:
      url: https://agents.example.com/translator
      token: literal-token
''';
      final file = File('${tmp.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync(seed);
      await saveCliConfig(tmp.path, CliConfig());
      expect(file.readAsStringSync(), contains(seed.trimRight()));
    });

    test('only a column-0 `key:` line counts as rendered — a scalar or '
        'nested key mentioning the section does not', () async {
      // The guard was an unanchored contains('memory:'): any scalar
      // (a prompt override's text, an `xmemory:`-style key, a comment)
      // containing the substring `memory:`/`a2a:` made the saver
      // believe the caller had rendered the section, silently dropping
      // the real on-disk block. The match must be anchored: a top-level
      // `key:` line at column 0.
      final seed = '''
memory:
  projectPath: ./memory
  userPath: ~/longterm
a2a:
  servers:
    translator:
      url: https://agents.example.com/translator
''';
      File('${tmp.path}/.fah/config.yaml')
        ..createSync(recursive: true)
        ..writeAsStringSync(seed);

      // The caller renders the prompts and roles sections; the poison
      // rides both shapes an unanchored contains would bite on — a
      // scalar VALUE mentioning `memory:`/`a2a:` as plain words, and a
      // NESTED key line (`  memory:` under `roles:`, the `xmemory:`
      // shape from the review) whose text contains the substring.
      final roles = ModelRolesConfig.fromYaml(
        loadYaml('''
roles:
  memory:
    - openrouter/anthropic/claude-sonnet-4
''')
            as YamlMap,
      );
      await saveCliConfig(
        tmp.path,
        CliConfig(
          promptOverrides: {
            'compaction/summary': 'consult memory: and a2a: before answering',
          },
          modelRoles: roles,
        ),
      );

      final saved = loadCliConfig(tmp.path);
      expect(saved.memory?.projectPath, './memory');
      expect(saved.memory?.userPath, '~/longterm');
      expect(
        saved.a2a?.servers['translator']?.url,
        'https://agents.example.com/translator',
      );
    });

    test(
      'a column-0 comment inside a preserved section does not truncate it',
      () async {
        // Comments are invisible to yaml indentation: a `# …` line at
        // column 0 between the section's own lines is still INSIDE the
        // section. The block extractor used to stop at it, preserving
        // only the lines above the comment (here: losing userPath).
        final seed = '''
memory:
  projectPath: ./memory
# userPath is referenced by the weekly export
  userPath: ~/longterm
''';
        File('${tmp.path}/.fah/config.yaml')
          ..createSync(recursive: true)
          ..writeAsStringSync(seed);

        await saveCliConfig(tmp.path, CliConfig());

        final saved = loadCliConfig(tmp.path);
        expect(saved.memory?.projectPath, './memory');
        expect(saved.memory?.userPath, '~/longterm');
      },
    );
  });

  group('trajectory section (issue #385)', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-trajectory-config-');
    });
    tearDown(() {
      tmp.deleteSync(recursive: true);
    });
    test('wireDump: true parses through the user config', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('trajectory:\n  wireDump: true\n');
      expect(loadCliConfig(tmp.path).wireDump, isTrue);
      file.writeAsStringSync('trajectory:\n  wireDump: false\n');
      expect(loadCliConfig(tmp.path).wireDump, isFalse);
    });

    test('an empty section defaults wireDump to false', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('trajectory:\n');
      expect(loadCliConfig(tmp.path).wireDump, isFalse);
    });

    test('rejects unknown trajectory keys', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('trajectory:\n  bogus: 1\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('unknown "trajectory" key'),
          ),
        ),
      );
    });

    test('rejects a non-boolean wireDump', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('trajectory:\n  wireDump: "yes"\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('"trajectory.wireDump" must be a boolean'),
          ),
        ),
      );
    });

    test('rejects a non-map trajectory section', () {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('trajectory: 42\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('trajectory must be a map'),
          ),
        ),
      );
    });

    test('loadProjectWireDump: absent file, section, and value cases', () {
      final missing = Directory.systemTemp.createTempSync('fah-proj');
      expect(loadProjectWireDump(missing.path), isNull);
      missing.deleteSync(recursive: true);

      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync('other:\n  key: 1\n');
      expect(loadProjectWireDump(tmp.path), isNull);

      file.writeAsStringSync('trajectory:\n  wireDump: true\n');
      expect(loadProjectWireDump(tmp.path), isTrue);

      file.writeAsStringSync('trajectory:\n  wireDump: bogus\n');
      expect(
        () => loadProjectWireDump(tmp.path),
        throwsA(isA<ConfigException>()),
      );

      // A scalar document is not a config map: treated as absent.
      file.writeAsStringSync('just-a-string\n');
      expect(loadProjectWireDump(tmp.path), isNull);
    });
  });

  group('startup cube precedence', () {
    const project = CubeSettings(configPath: '.fah/cubes/dev.yaml');
    const user = CubeSettings(configPath: '.fah/cubes/user.yaml');

    test('an explicit --cube-config flag wins over everything', () {
      expect(
        resolveStartupCubeSource(
          flagConfigPath: 'pinned.yaml',
          flagName: 'named',
          project: project,
          user: user,
        ),
        'pinned.yaml',
      );
    });

    test('an explicit --cube name wins over the config sections', () {
      expect(
        resolveStartupCubeSource(
          flagName: 'named',
          project: project,
          user: user,
        ),
        'named',
      );
    });

    test('the project section beats the user section when both set', () {
      expect(
        resolveStartupCubeSource(project: project, user: user),
        '.fah/cubes/dev.yaml',
      );
    });

    test('a disabled project section falls through to the user one', () {
      expect(
        resolveStartupCubeSource(
          project: const CubeSettings(enabled: false, configPath: 'x'),
          user: user,
        ),
        '.fah/cubes/user.yaml',
      );
    });

    test('a disabled or absent user section starts unsandboxed', () {
      expect(resolveStartupCubeSource(), isNull);
      expect(
        resolveStartupCubeSource(user: const CubeSettings(enabled: false)),
        isNull,
      );
      expect(
        resolveStartupCubeSource(project: const CubeSettings(enabled: true)),
        isNull,
        reason: 'enabled with no config path has nothing to resolve',
      );
    });
  });
  group('logFileFromEnv', () {
    test('absent or blank yields null', () {
      expect(logFileFromEnv({}), isNull);
      expect(logFileFromEnv({'FA_LOG_FILE': ''}), isNull);
      expect(logFileFromEnv({'FA_LOG_FILE': '   '}), isNull);
    });

    test('returns the path', () {
      expect(
        logFileFromEnv({'FA_LOG_FILE': '/tmp/trace.log'}),
        '/tmp/trace.log',
      );
    });
  });
}
