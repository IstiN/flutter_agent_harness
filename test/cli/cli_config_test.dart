import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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
  });
}
