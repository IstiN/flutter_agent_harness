import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

void main() {
  group('CliConfig tools section', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-tools-config-test-');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    void writeConfig(String yaml) {
      final file = File('${tmp.path}/.fah/config.yaml');
      file.createSync(recursive: true);
      file.writeAsStringSync(yaml);
    }

    test('defaults to null when the section is absent', () {
      expect(loadCliConfig(tmp.path).tools, isNull);
    });

    test('parses the tools section from the config file', () {
      writeConfig('tools:\n  web_search: false\n  mcp:\n    fs: true\n');
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.tools?.tools, {'web_search': false, 'mcp:fs': true});
    });

    test('round-trips the tools section', () async {
      const tools = ToolsConfig(tools: {'web_search': false, 'mcp:fs': true});
      await saveCliConfig(tmp.path, CliConfig(tools: tools));
      final loaded = loadCliConfig(tmp.path);
      expect(loaded.tools?.tools, tools.tools);
      // Full yaml fidelity: emitting again reproduces the same document.
      expect(loaded.toYaml(), CliConfig(tools: tools).toYaml());
    });

    test('round-trips an empty config as an absent section', () async {
      await saveCliConfig(tmp.path, CliConfig(tools: const ToolsConfig()));
      expect(loadCliConfig(tmp.path).tools, isNull);
    });

    test('rejects a malformed tools section', () {
      writeConfig('tools: not-a-map\n');
      expect(
        () => loadCliConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('tools must be a map'),
          ),
        ),
      );
    });

    test('rejects a non-boolean tools value', () {
      writeConfig('tools:\n  web_search: sure\n');
      expect(() => loadCliConfig(tmp.path), throwsA(isA<ConfigException>()));
    });
  });

  group('project tools section', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('fah-project-tools-test-');
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
      expect(loadProjectToolsConfig(tmp.path), isNull);
    });

    test('parses the project tools section', () {
      writeProjectConfig('tools:\n  bash: false\n  mcp:\n    fs: false\n');
      final loaded = loadProjectToolsConfig(tmp.path);
      expect(loaded?.tools, {'bash': false, 'mcp:fs': false});
    });

    test('absent section loads as null', () {
      writeProjectConfig('provider: anthropic\n');
      expect(loadProjectToolsConfig(tmp.path), isNull);
    });

    test('malformed yaml loads as null', () {
      writeProjectConfig('not yaml: [unclosed');
      expect(loadProjectToolsConfig(tmp.path), isNull);
    });

    test('invalid section throws ConfigException', () {
      writeProjectConfig('tools:\n  - nope\n');
      expect(
        () => loadProjectToolsConfig(tmp.path),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('tools must be a map'),
          ),
        ),
      );
    });
  });

  group('toolsSpecFromEnv', () {
    test('absent variable yields null', () {
      expect(toolsSpecFromEnv({}), isNull);
    });

    test('empty or blank value yields null', () {
      expect(toolsSpecFromEnv({'FA_TOOLS': ''}), isNull);
      expect(toolsSpecFromEnv({'FA_TOOLS': '   '}), isNull);
    });

    test('parses the csv spec', () {
      final tools = toolsSpecFromEnv({
        'FA_TOOLS': 'web_search=off, dap=on, mcp:fs=false',
      });
      expect(tools?.tools, {'web_search': false, 'dap': true, 'mcp:fs': false});
    });

    test('malformed value throws ConfigException naming the token', () {
      expect(
        () => toolsSpecFromEnv({'FA_TOOLS': 'web_search'}),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('web_search'),
          ),
        ),
      );
    });
  });

  group('--tools flag', () {
    test('defaults to null when absent', () {
      final args = parseCliArgs(const []) as CliArgs;
      expect(args.tools, isNull);
    });

    test('parses the csv spec', () {
      final args =
          parseCliArgs(['--tools', 'web_search=off,mcp:fs=on']) as CliArgs;
      expect(args.tools?.tools, {'web_search': false, 'mcp:fs': true});
    });

    test('malformed spec throws CliArgsException naming the token', () {
      expect(
        () => parseCliArgs(['--tools', 'web_search']),
        throwsA(
          isA<CliArgsException>().having(
            (e) => e.message,
            'message',
            allOf(contains('--tools'), contains('web_search')),
          ),
        ),
      );
    });

    test('missing value is a usage error', () {
      expect(() => parseCliArgs(['--tools']), throwsA(isA<CliArgsException>()));
    });
  });
}
