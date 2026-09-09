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

    test('a2a env tokens pass the structural check', () async {
      await env.writeFile(
        _globalConfig,
        '$_validGlobal\n'
        'a2a:\n'
        '  servers:\n'
        '    translator:\n'
        '      url: https://agents.example.com/translator\n'
        r'      token: ${A2A_TRANSLATOR_KEY}'
        '\n',
      );
      final report = await checkOrThrow(service);
      expect(report.warnings, isEmpty);
    });

    test('set passes on a file carrying a2a env tokens', () async {
      await env.writeFile(
        _globalConfig,
        '$_validGlobal\n'
        'a2a:\n'
        '  servers:\n'
        '    translator:\n'
        '      url: https://agents.example.com/translator\n'
        r'      token: ${A2A_TRANSLATOR_KEY}'
        '\n',
      );
      final result = await service.set('approvalMode', 'yolo');
      expect(result.newDisplay, 'yolo');
      expect(
        read(_globalConfig),
        completion(contains(r'${A2A_TRANSLATOR_KEY}')),
      );
    });
  });

  group('broken files degrade cleanly (never a raw YamlException)', () {
    test('check reports invalid yaml on the project file', () async {
      await env.writeFile(_projectConfig, 'memory: [unclosed\n');
      final report = await service.check();
      expect(
        report.errors.map((e) => e.toString()).join('\n'),
        allOf(contains(_projectConfig), contains('invalid yaml')),
      );
    });

    test('get answers "not set" on a broken file', () async {
      await env.writeFile(_globalConfig, 'memory: [unclosed\n');
      expect((await service.get('memory.projectPath')).found, isFalse);
    });

    test('set refuses to persist onto a broken file', () async {
      await env.writeFile(_globalConfig, 'model: [unclosed\n');
      await expectLater(service.set('provider', 'zai'), throwsConfigException);
      expect(read(_globalConfig), completion(contains('[unclosed')));
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

    test('writes a JSON list of provider entries as a yaml block (S4)', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      await service.set(
        'customProviders',
        '[{"name":"mock","apiType":"openai","baseUrl":"http://127.0.0.1:9/v1",'
            '"modelId":"m1","keyName":"MOCK_KEY"}]',
        scope: ConfigScope.global,
      );
      final text = await read(_globalConfig);
      expect(
        text,
        contains(
          'customProviders:\n  - name: mock\n    apiType: openai\n'
          '    baseUrl: http://127.0.0.1:9/v1\n    modelId: m1\n'
          '    keyName: MOCK_KEY\n',
        ),
      );
      final result = await service.get('customProviders');
      // get reports the compact JSON round trip (feed it back into set).
      expect(
        result.display,
        '[{"name":"mock","apiType":"openai","baseUrl":"http://127.0.0.1:9/v1",'
        '"modelId":"m1","keyName":"MOCK_KEY"}]',
      );
      // The pre-write validation ran the REAL customProviders parser.
      await checkOrThrow(service);
    });

    test('replaces an existing provider block in place', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      const first =
          '[{"name":"a","apiType":"openai","baseUrl":"http://a/v1","modelId":"ma"}]';
      const second =
          '[{"name":"b","apiType":"anthropic","baseUrl":"http://b/v1","modelId":"mb"}]';
      await service.set('customProviders', first, scope: ConfigScope.global);
      await service.set('customProviders', second, scope: ConfigScope.global);
      final text = await read(_globalConfig);
      expect(text, contains('- name: b'));
      expect(text, isNot(contains('name: a')));
      // Unrelated content above and below the block survives untouched.
      expect(text, contains('provider: openai'));
      await checkOrThrow(service);
    });

    test('a block write keeps the key trailing comment and neighbors', () async {
      await env.writeFile(
        _globalConfig,
        '$_validGlobal\n# my providers\ncustomProviders: []\n# tail\n',
      );
      await service.set(
        'customProviders',
        '[{"name":"x","apiType":"openai","baseUrl":"http://x/v1","modelId":"mx"}]',
        scope: ConfigScope.global,
      );
      final text = await read(_globalConfig);
      expect(text, contains('# my providers\ncustomProviders:\n'));
      expect(text, endsWith('# tail\n'));
      await checkOrThrow(service);
    });

    test(
      'rejects a bad provider entry before writing (named diagnostic)',
      () async {
        await env.writeFile(_globalConfig, _validGlobal);
        await expectLater(
          service.set(
            'customProviders',
            '[{"name":"broken"}]',
            scope: ConfigScope.global,
          ),
          throwsConfigException,
        );
        expect(await read(_globalConfig), _validGlobal);
      },
    );

    test('empty JSON list renders flow [] and appends a fresh block', () async {
      await env.writeFile(_globalConfig, _validGlobal);
      await service.set('customProviders', '[]', scope: ConfigScope.global);
      expect(await read(_globalConfig), contains('customProviders: []\n'));
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

    test(
      'project-capable keys default to the project file, creating it (E1)',
      () async {
        await env.writeFile(_globalConfig, _validGlobal);
        final result = await service.set('tools.web_search', 'false');
        expect(result.scope, 'project');
        expect(await read(_projectConfig), 'tools:\n  web_search: false\n');
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
  group('diagnostic dispatch', () {
    test('a non-map root is a named error, not a crash', () async {
      await env.writeFile(_globalConfig, '- just\n- a list\n');
      final report = await service.check();
      expect(
        report.errors.single.message,
        contains('config root must be a yaml map'),
      );
    });

    test('scalar keys must be non-empty strings', () async {
      await env.writeFile(_globalConfig, 'provider: 123\n');
      final report = await service.check();
      expect(
        report.errors.single.message,
        contains('provider: must be a non-empty string'),
      );
    });

    test('allowedTools must be a list when present', () async {
      await env.writeFile(_globalConfig, 'allowedTools: web_fetch\n');
      final report = await service.check();
      expect(
        report.errors.single.message,
        contains('allowedTools: must be a list of tool names'),
      );
    });

    test('the roles group parses once and accepts a valid chain', () async {
      await env.writeFile(
        _globalConfig,
        'roles:\n'
        '  default: [openrouter/anthropic/claude-sonnet-4]\n'
        'retry:\n'
        '  retriesPerEntry: 2\n',
      );
      final report = await service.check();
      expect(report.errors, isEmpty);
    });

    test(
      'an invalid roles entry fails with the triggering key named',
      () async {
        await env.writeFile(
          _globalConfig,
          'roles: [not, a, map]\n'
          'modelOverrides: []\n',
        );
        final report = await service.check();
        // The group parses once, but both group keys report the failure
        // under their own name.
        expect(report.errors, hasLength(2));
        expect(report.errors.first.message, contains('roles:'));
      },
    );

    test('every strict section reaches its validator via check', () async {
      // One valid document touching every strict-section validator, so
      // the dispatch map routes all of them through `check`.
      await env.writeFile(
        _globalConfig,
        'provider: openai-completions\n'
        'memory:\n  projectPath: ./memory\n'
        'cube:\n  enabled: true\n'
        'tools:\n  web_search: false\n'
        'mcp:\n  servers: {}\n'
        'redact:\n  enabled: true\n'
        'models:\n  custom: {}\n'
        'customProviders: []\n'
        'ttsr:\n  rules: []\n'
        'a2a:\n  servers: {}\n'
        'providerTimeouts:\n  connectTimeoutMs: 1000\n'
        'skills:\n  access: ask\n'
        'prompts:\n  bootstrap: hi\n',
      );
      final report = await service.check();
      expect(
        report.errors,
        isEmpty,
        reason:
            'every section must parse: '
            '${report.errors.map((e) => e.message).join('; ')}',
      );
    });

    test(
      'providerTimeouts rejects unknown keys and non-positive ints',
      () async {
        await env.writeFile(_globalConfig, 'providerTimeouts:\n  bogus: 1\n');
        expect(
          (await service.check()).errors.single.message,
          contains('unknown "providerTimeouts" key: bogus'),
        );
        await env.writeFile(
          _globalConfig,
          'providerTimeouts:\n  connectTimeoutMs: 0\n',
        );
        expect(
          (await service.check()).errors.single.message,
          contains('must be a positive integer'),
        );
      },
    );

    test(
      'skills rejects bad access values, bad bools and unknown keys',
      () async {
        await env.writeFile(_globalConfig, 'skills:\n  access: sometimes\n');
        expect(
          (await service.check()).errors.single.message,
          contains('skills.access must be ask, granted or denied'),
        );
        await env.writeFile(
          _globalConfig,
          'skills:\n  disableShellExecution: yes-please\n',
        );
        expect(
          (await service.check()).errors.single.message,
          contains('skills.disableShellExecution must be a boolean'),
        );
        await env.writeFile(_globalConfig, 'skills:\n  bogus: 1\n');
        expect(
          (await service.check()).errors.single.message,
          contains('unknown "skills" key: bogus'),
        );
      },
    );

    test('prompts must be a string-valued map', () async {
      await env.writeFile(_globalConfig, 'prompts:\n  bootstrap: [nope]\n');
      expect(
        (await service.check()).errors.single.message,
        contains('prompts.bootstrap must be a string'),
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
  group('host capability (AC11)', () {
    // The real web/iOS-container shape: no home directory (the global scope
    // is unreachable) and no process spawning.
    late MemoryExecutionEnv webEnv;
    late ConfigService webService;
    // A no-process host that still has a readable user file — pins the
    // stdio-vs-remote distinction itself.
    late MemoryExecutionEnv capEnv;
    late ConfigService capService;

    setUp(() {
      webEnv = MemoryExecutionEnv(cwd: '/work');
      webService = ConfigService(
        env: webEnv,
        homeDir: null,
        supportsProcesses: false,
      );
      capEnv = MemoryExecutionEnv(cwd: '/work');
      capService = ConfigService(
        env: capEnv,
        homeDir: '/home',
        supportsProcesses: false,
      );
    });

    const stdioNote =
        'mcp stdio server "fs" is not applicable on this host (no process '
        'spawning) — configure a remote server via `mcp.servers.fs.url` '
        'instead';

    test(
      'get of a stdio member answers not applicable, never dead config',
      () async {
        await webEnv.writeFile(
          _globalConfig,
          'mcp:\n  servers:\n    fs:\n      command: npx\n',
        );
        final result = await webService.get('mcp.servers.fs.command');
        expect(result.found, isFalse);
        expect(result.notApplicable, stdioNote);
        // The sibling args/env members are process-bound too.
        expect(
          (await webService.get('mcp.servers.fs.args')).notApplicable,
          stdioNote,
        );
      },
    );

    test('get of a whole stdio entry answers not applicable', () async {
      await capEnv.writeFile(
        _globalConfig,
        'mcp:\n  servers:\n    fs:\n      command: npx\n      args: [-y]\n',
      );
      final result = await capService.get('mcp.servers.fs');
      expect(result.notApplicable, stdioNote);
    });

    test('get of a remote server entry resolves normally', () async {
      await capEnv.writeFile(
        _globalConfig,
        'mcp:\n  servers:\n    web:\n      url: https://mcp.example\n',
      );
      final result = await capService.get('mcp.servers.web');
      expect(result.found, isTrue);
      expect(result.notApplicable, isNull);
      expect((await capService.get('mcp.servers.web.url')).found, isTrue);
    });

    test('global-scope writes answer honestly on a home-less host', () async {
      await expectLater(
        webService.set('provider', 'openai-completions'),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('global scope unavailable on this host'),
          ),
        ),
      );
    });

    test('set of a stdio entry is refused with the host reason', () async {
      await webEnv.writeFile(_globalConfig, 'mode: code\n');
      expect(
        () => webService.set('mcp.servers.fs.command', 'npx'),
        throwsA(
          isA<ConfigException>().having((e) => e.message, 'message', stdioNote),
        ),
      );
      expect(
        () => webService.set(
          'mcp.servers.fs',
          '{"command": "npx", "args": ["-y"]}',
        ),
        throwsConfigException,
      );
      // Nothing was written.
      expect((await webService.get('mcp.servers.fs.command')).found, isFalse);
    });

    test('set of a remote server entry succeeds on the same host', () async {
      final result = await capService.set(
        'mcp.servers.web',
        '{"url": "https://mcp.example", "transport": "streamable-http"}',
      );
      expect(result.scope, 'global');
      expect(
        (await capService.get('mcp.servers.web.url')).display,
        'https://mcp.example',
      );
    });

    test('check warns about existing stdio entries as dead config', () async {
      await capEnv.writeFile(
        _globalConfig,
        'mcp:\n  servers:\n    fs:\n      command: npx\n',
      );
      final report = await capService.check();
      expect(report.ok, isTrue); // a warning, not an error
      expect(
        report.warnings.single.message,
        contains('mcp stdio server "fs" cannot run on this host'),
      );
    });
    test(
      'the desktop default still resolves and writes stdio entries',
      () async {
        await env.writeFile(
          _globalConfig,
          'mcp:\n  servers:\n    fs:\n      command: npx\n',
        );
        expect((await service.get('mcp.servers.fs.command')).display, 'npx');
        final report = await checkOrThrow(service);
        expect(report.warnings, isEmpty);
      },
    );

    test('config tool get renders the not-applicable answer (config_tool_test '
        'covers the schema; this pins the AC11 wording end to end)', () async {
      await webEnv.writeFile(
        _globalConfig,
        'mcp:\n  servers:\n    fs:\n      command: npx\n',
      );
      final result = await webService.get('mcp.servers.fs.args');
      expect(result.notApplicable, contains('not applicable on this host'));
    });
  });
}
