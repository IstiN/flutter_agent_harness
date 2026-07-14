import 'dart:io';

import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';

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
  });
}
