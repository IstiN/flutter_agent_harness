@Timeout(Duration(seconds: 10))
library;

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

void main() {
  group('LspConfig.defaults', () {
    test('registers the Dart analysis server for .dart', () {
      final config = LspConfig.defaults();
      final dart = config.servers['dart']!;
      expect(dart.command, 'dart');
      expect(dart.args, ['language-server', '--protocol=lsp']);
      expect(dart.fileTypes, ['.dart']);
      expect(dart.rootMarkers, contains('pubspec.yaml'));
      expect(config.idleTimeout, LspConfig.defaultIdleTimeout);
    });
  });

  group('serverForFile', () {
    test('matches by extension and basename, skips disabled', () {
      final config = LspConfig(
        servers: {
          'dart': LspConfig.defaults().servers['dart']!,
          'docker': const LspServerConfig(
            name: 'docker',
            command: 'docker-langserver',
            fileTypes: ['Dockerfile'],
            rootMarkers: ['Dockerfile'],
          ),
          'off': const LspServerConfig(
            name: 'off',
            command: 'off',
            fileTypes: ['.off'],
            rootMarkers: ['.'],
            disabled: true,
          ),
        },
      );
      expect(config.serverForFile('/ws/lib/a.dart')?.name, 'dart');
      expect(config.serverForFile('/ws/Dockerfile')?.name, 'docker');
      expect(config.serverForFile('/ws/a.off'), isNull);
      expect(config.serverForFile('/ws/a.txt'), isNull);
    });
  });

  group('languageIdFor', () {
    test('defaults to the extension, honors overrides', () {
      const server = LspServerConfig(
        name: 'dart',
        command: 'dart',
        fileTypes: ['.dart'],
        rootMarkers: ['pubspec.yaml'],
      );
      expect(server.languageIdFor('/ws/a.dart'), 'dart');
      const custom = LspServerConfig(
        name: 'custom',
        command: 'custom',
        fileTypes: ['.vue'],
        rootMarkers: ['.'],
        languageId: 'vue',
      );
      expect(custom.languageIdFor('/ws/a.vue'), 'vue');
    });
  });

  group('LspConfig.load', () {
    late MemoryExecutionEnv env;

    setUp(() {
      env = MemoryExecutionEnv(cwd: '/ws');
    });

    test('returns defaults when no config file exists', () async {
      final config = await LspConfig.load(env);
      expect(config.servers.keys, ['dart']);
      expect(config.warnings, isEmpty);
    });

    test('merges .fah/lsp.json over the defaults', () async {
      await env.writeFile('/ws/.fah/lsp.json', '''
{
  "servers": {
    "dart": {"command": "dart", "args": ["language-server"], "fileTypes": [".dart"], "rootMarkers": ["pubspec.yaml"], "settings": {"dart": {"lineLength": 120}}},
    "my-server": {"command": "my-ls", "args": ["--stdio"], "fileTypes": [".xyz"], "rootMarkers": ["xyz.json"]}
  },
  "idleTimeoutMs": 60000
}
''');
      final config = await LspConfig.load(env);
      expect(config.servers.keys, containsAll(['dart', 'my-server']));
      // The override's args win; unspecified fields are taken from the entry.
      expect(config.servers['dart']!.args, ['language-server']);
      expect(config.servers['dart']!.settings, {
        'dart': {'lineLength': 120},
      });
      expect(config.servers['my-server']!.command, 'my-ls');
      expect(config.idleTimeout, const Duration(minutes: 1));
    });

    test('a malformed file falls back to defaults with a warning', () async {
      await env.writeFile('/ws/.fah/lsp.json', '{not json');
      final config = await LspConfig.load(env);
      expect(config.servers.keys, ['dart']);
      expect(config.warnings.single, contains('malformed'));
    });

    test('a non-object file falls back to defaults with a warning', () async {
      await env.writeFile('/ws/.fah/lsp.json', '["nope"]');
      final config = await LspConfig.load(env);
      expect(config.servers.keys, ['dart']);
      expect(config.warnings.single, contains('top level'));
    });

    test('invalid server entries are skipped with a warning', () async {
      await env.writeFile('/ws/.fah/lsp.json', '''
{"servers": {"bad": {"args": []}}}
''');
      final config = await LspConfig.load(env);
      expect(config.servers.keys, ['dart']);
      expect(config.warnings.single, contains('"bad"'));
    });
  });

  group('workspaceRootFor', () {
    test('walks up to the nearest root marker', () async {
      final env = MemoryExecutionEnv(cwd: '/ws');
      await env.writeFile('/ws/pubspec.yaml', 'name: ws\n');
      await env.writeFile('/ws/lib/src/a.dart', '');
      final root = await LspConfig.defaults().workspaceRootFor(
        env,
        '/ws/lib/src/a.dart',
        LspConfig.defaults().servers['dart']!,
      );
      expect(root, '/ws');
    });

    test('falls back to cwd when no marker exists', () async {
      final env = MemoryExecutionEnv(cwd: '/ws');
      await env.writeFile('/elsewhere/a.dart', '');
      final root = await LspConfig.defaults().workspaceRootFor(
        env,
        '/elsewhere/a.dart',
        LspConfig.defaults().servers['dart']!,
      );
      expect(root, '/ws');
    });
  });
}
