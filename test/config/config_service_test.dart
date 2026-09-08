/// The config service core (issue #29 S3): check/get/set/paths over the
/// user + project config pair on a [MemoryExecutionEnv], plus the pins that
/// keep the service's mirrored strict validators and top-level key set
/// honest against `cli_config.dart` (which the pure core cannot import).
library;

import 'dart:io';

import 'package:flutter_agent_harness/src/cli/cli_config.dart';
import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

const _globalConfig = '/home/.fah/config.yaml';
const _projectConfig = '/work/.fah/config.yaml';

const _validGlobal = '''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
mode: code
approvalMode: yolo
''';

const _validProject = '''
memory:
  projectPath: ./memory
tools:
  web_search: false
''';

const _commentedProject = '''
# my project config
memory:
  projectPath: ./old # committed with the repo
tools:
  web_search: false
''';

Matcher get throwsConfigException => throwsA(isA<ConfigException>());

/// Throws the first collected error as a failure with its message, so tests
/// can assert on named diagnostics.
Future<ConfigCheckReport> checkOrThrow(ConfigService service) async {
  final report = await service.check();
  expect(
    report.ok,
    isTrue,
    reason:
        'unexpected errors: '
        '${report.errors.map((e) => e.toString()).join('; ')}',
  );
  return report;
}

void main() {
  late MemoryExecutionEnv env;
  late ConfigService service;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    service = ConfigService(env: env, homeDir: '/home');
  });

  Future<String> read(String path) async {
    final result = await env.readTextFile(path);
    return result.valueOrNull ?? '';
  }

  group('check', () {
    test('absent files are fine — defaults apply', () async {
      final report = await service.check();
      expect(report.ok, isTrue);
      expect(report.notes.join('\n'), contains('global config absent'));
      expect(report.notes.join('\n'), contains('project config absent'));
    });

    test('valid global + project files pass clean', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      await env.writeFile(_projectConfig, _validProject);
      final report = await checkOrThrow(service);
      expect(report.warnings, isEmpty);
    });

    test(
      'a broken strict section fails with a named diagnostic (AC7)',
      () async {
        await env.writeFile(
          _globalConfig,
          '$_validGlobal\nmcp:\n  servers:\n    fs: not-a-map\n',
        );
        final report = await service.check();
        expect(report.ok, isFalse);
        expect(
          report.errors.map((e) => e.toString()).join('\n'),
          allOf(contains(_globalConfig), contains('mcp')),
        );
      },
    );

    test('a broken project section fails with a named diagnostic', () async {
      await env.writeFile(_projectConfig, 'memory: 42\n');
      final report = await service.check();
      expect(
        report.errors.map((e) => e.toString()).join('\n'),
        allOf(contains(_projectConfig), contains('memory')),
      );
    });

    test('a yaml syntax error fails loudly', () async {
      await env.writeFile(_globalConfig, 'provider: [unclosed\n');
      final report = await service.check();
      expect(report.ok, isFalse);
      expect(
        report.errors.map((e) => e.message).join('\n'),
        contains('invalid yaml'),
      );
    });

    test('unknown top-level keys warn but do not fail', () async {
      await env.writeFile(_globalConfig, '$_validGlobal\nbogusKey: 1\n');
      final report = await checkOrThrow(service);
      expect(report.warnings.single.message, contains('bogusKey'));
    });

    test(
      'global-only sections in the project file warn as dead config',
      () async {
        await env.writeFile(_projectConfig, '$_validProject\nprovider: zai\n');
        final report = await checkOrThrow(service);
        expect(
          report.warnings.map((w) => w.message).join('\n'),
          contains('dead config'),
        );
      },
    );

    test('bad providerTimeouts and skills sections fail', () async {
      await env.writeFile(
        _globalConfig,
        '$_validGlobal\nproviderTimeouts:\n  bogus: 1\n',
      );
      var report = await service.check();
      expect(
        report.errors.map((e) => e.message).join('\n'),
        contains('providerTimeouts'),
      );

      await env.writeFile(
        _globalConfig,
        '$_validGlobal\nskills:\n  access: sometimes\n',
      );
      report = await service.check();
      expect(
        report.errors.map((e) => e.message).join('\n'),
        contains('access'),
      );
    });
  });

  group('get', () {
    test('project scope wins for the project-capable sections', () async {
      await env.writeFile(
        _globalConfig,
        '$_validGlobal\nmemory:\n  projectPath: ./user-memory\n',
      );
      await env.writeFile(_projectConfig, _validProject);
      final result = await service.get('memory.projectPath');
      expect(result.found, isTrue);
      expect(result.display, './memory');
      expect(result.scope, 'project');
      expect(result.file, _projectConfig);
    });

    test('global-only keys resolve from the user file', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      final result = await service.get('provider');
      expect(result.found, isTrue);
      expect(result.display, 'openai-completions');
      expect(result.scope, 'global');
      expect(result.file, _globalConfig);
    });

    test('a key absent everywhere reports found=false', () async {
      final result = await service.get('memory.projectPath');
      expect(result.found, isFalse);
    });

    test('an unknown top-level key throws (typo protection)', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      expect(() => service.get('providr'), throwsConfigException);
    });
  });

  group('set', () {
    test('creates a minimal project file when asked (E1)', () async {
      final result = await service.set(
        'memory.projectPath',
        './memory',
        scope: ConfigScope.project,
      );
      expect(result.scope, 'project');
      expect(result.oldDisplay, '(absent)');
      expect(await read(_projectConfig), 'memory:\n  projectPath: ./memory\n');
      await checkOrThrow(service);
    });

    test('writes a top-level scalar to the user file', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      final result = await service.set(
        'provider',
        'zai',
        scope: ConfigScope.global,
      );
      expect(result.file, _globalConfig);
      expect(result.oldDisplay, 'openai-completions');
      final text = await read(_globalConfig);
      expect(text, contains('provider: zai'));
      expect(text, contains('model: openai/gpt-4o-mini'));
    });

    test('rewrites only the touched line, comment included (E4)', () async {
      await env.writeFile(_projectConfig, _commentedProject);
      await service.set('memory.projectPath', './memory');
      expect(
        await read(_projectConfig),
        '# my project config\n'
        'memory:\n'
        '  projectPath: ./memory # committed with the repo\n'
        'tools:\n'
        '  web_search: false\n',
      );
    });

    test('inserts a missing key under an existing section', () async {
      await env.writeFile(_projectConfig, 'tools:\n  web_search: false\n');
      await service.set('tools.dap', 'false', scope: ConfigScope.project);
      final result = await service.get('tools.dap');
      expect(result.display, 'false');
      await checkOrThrow(service);
    });

    test('builds a nested mcp server entry in the user file', () async {
      await env.writeFile(
        _globalConfig,
        '$_validGlobal\nmcp:\n  servers:\n    fs:\n      url: https://old.example.com/mcp\n',
      );
      await service.set(
        'mcp.servers.fs.url',
        'https://example.com/mcp',
        scope: ConfigScope.global,
      );
      final result = await service.get('mcp.servers.fs.url');
      expect(result.display, 'https://example.com/mcp');
      await checkOrThrow(service);
    });

    test('rejects a wrong-typed value before writing anything (E3)', () async {
      await env.writeFile(_projectConfig, _validProject);
      await expectLater(
        service.set('tools.web_search', 'maybe', scope: ConfigScope.project),
        throwsConfigException,
      );
      expect(await read(_projectConfig), _validProject);
    });

    test('rejects descending into a scalar key', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      await expectLater(
        service.set('provider.kind', 'x', scope: ConfigScope.global),
        throwsConfigException,
      );
    });

    test('refuses global-only keys at project scope with guidance', () async {
      await env.writeFile(_projectConfig, _validProject);
      await expectLater(
        service.set('provider', 'zai', scope: ConfigScope.project),
        throwsConfigException,
      );
    });

    test('resolves the default scope by cwd: project file wins', () async {
      await env.writeFile(_projectConfig, _validProject);
      final result = await service.set('memory.projectPath', './other');
      expect(result.scope, 'project');
    });

    test(
      'resolves the default scope to global without a project file',
      () async {
        await env.writeFile(_globalConfig, _validGlobal);
        final result = await service.set('mode', 'architect');
        expect(result.scope, 'global');
      },
    );

    test('set then get round-trips across scopes (AC8)', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      await env.writeFile(_projectConfig, _validProject);
      // The project memory section wins wholesale, userPath included.
      await service.set(
        'memory.userPath',
        '~/memory-store',
        scope: ConfigScope.project,
      );
      var result = await service.get('memory.userPath');
      expect(result.display, '~/memory-store');
      expect(result.scope, 'project');
      // The same key at global scope stays shadowed by the project section.
      await service.set(
        'memory.userPath',
        '~/user-store',
        scope: ConfigScope.global,
      );
      result = await service.get('memory.userPath');
      expect(result.display, '~/memory-store');
      expect(result.scope, 'project');
    });
  });

  group('paths', () {
    test('lists the config locations with existence', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      final paths = await service.paths();
      final byLabel = {for (final p in paths) p.label: p};
      expect(byLabel['global config']!.exists, isTrue);
      expect(byLabel['global config']!.path, _globalConfig);
      expect(byLabel['project config']!.exists, isFalse);
      expect(byLabel.keys, containsAll(['project rules', 'dap config']));
    });

    test('reports the global scope honestly without a home (E11)', () async {
      final homeless = ConfigService(env: env);
      final paths = await homeless.paths();
      expect(paths.first.path, contains('no home directory'));
      final report = await homeless.check();
      expect(report.notes.join('\n'), contains('global scope unavailable'));
      await expectLater(
        homeless.set('provider', 'zai', scope: ConfigScope.global),
        throwsConfigException,
      );
    });
  });

  group('pins against cli_config.dart', () {
    test('the top-level key set matches what the CLI config reads', () {
      final bodies = [
        'lib/src/cli/cli_config.dart',
        'lib/src/model_roles/roles_config.dart',
      ].map(File.new).map((file) => file.readAsStringSync());
      for (final key in configTopLevelKeys) {
        final found = bodies.any((body) => body.contains("'$key'"));
        expect(
          found,
          isTrue,
          reason: 'config key "$key" is not read by the CLI config parsers',
        );
      }
    });

    test('providerTimeouts validation agrees with CliConfig.fromYaml', () {
      final bad = loadYaml('providerTimeouts:\n  bogus: 1\n') as YamlMap;
      expect(() => CliConfig.fromYaml(bad), throwsConfigException);
      final good =
          loadYaml('providerTimeouts:\n  connectTimeoutMs: 1000\n') as YamlMap;
      expect(() => CliConfig.fromYaml(good), returnsNormally);
    });

    test('skills validation agrees with CliConfig.fromYaml', () {
      final bad = loadYaml('skills:\n  access: sometimes\n') as YamlMap;
      expect(() => CliConfig.fromYaml(bad), throwsConfigException);
      final good = loadYaml('skills:\n  access: ask\n') as YamlMap;
      expect(() => CliConfig.fromYaml(good), returnsNormally);
    });
  });
}
