/// Unit tests for the cli_visual harness's hermetic-boot machinery
/// (issue #508): the sandbox HOME default in [CliVisualHarness.spawn]'s
/// env resolution and the real-config leak guard over screenshot twins.
///
/// No `integration` tag and no PTY: these run in the default `flutter test`
/// gate, so the guard against leaking the developer's real `~/.fah` is
/// checked on every plain test run.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'cli_visual_harness.dart';

void main() {
  group('resolveSpawnEnv — sandbox HOME by default', () {
    test('without extraEnv the child HOME is a fresh temp dir', () {
      final (env, sandbox) = CliVisualHarness.resolveSpawnEnv(null);
      final home = env['HOME'];
      expect(home, isNotNull);
      expect(home, isNot(Platform.environment['HOME']));
      expect(Directory(home!).existsSync(), isTrue);
      expect(sandbox, isNotNull);
      expect(sandbox!.path, home);
      expect(env['TERM'], 'xterm-256color');
      Directory(home).deleteSync(recursive: true);
    });

    test('an explicit HOME wins and creates no sandbox', () {
      final (env, sandbox) = CliVisualHarness.resolveSpawnEnv({
        'HOME': '/tmp/explicit-fixture-home',
      });
      expect(env['HOME'], '/tmp/explicit-fixture-home');
      expect(sandbox, isNull);
    });

    test('PUB_CACHE passes through for package resolution', () {
      // The harness forwards PUB_CACHE because the pub cache lives under
      // the REAL home; without it a HOME override breaks `dart` startup.
      const pubCache = '/tmp/pub-cache-probe';
      final withCache = CliVisualHarness.resolveSpawnEnv({
        'HOME': '/tmp/any',
        'PUB_CACHE': pubCache,
      }).$1;
      expect(withCache['PUB_CACHE'], pubCache);
    });
  });

  group('configLeakMarkers — real config extraction', () {
    test('collects model ids, urls and provider names, never api keys', () {
      final markers = configLeakMarkers('''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
api_key: sk-SUPERSECRET123
customProviders:
  - name: epam-copilot
    apiType: openai
    baseUrl: https://copilot.example/api
    modelId: my-custom-model
''', '');
      expect(
        markers,
        containsAll(<String>[
          'epam-copilot',
          'my-custom-model',
          // A custom endpoint is distinctive — it stays a marker.
          'https://copilot.example/api',
        ]),
      );
      // A stock catalog endpoint the provider picker renders anyway is
      // dropped: not leak evidence.
      expect(markers, isNot(contains('https://openrouter.ai/api/v1')));
      // A key value must never become a marker: it would echo the secret
      // into the failure message.
      expect(markers, isNot(contains('sk-SUPERSECRET123')));
      // 'openai/gpt-4o-mini' is a bundled-catalog id: the /models screen
      // renders it on any machine, so a real config reusing it must not
      // poison the guard (issue #508).
      expect(markers, isNot(contains('openai/gpt-4o-mini')));
    });

    test('collects live-fetched ids from the model cache', () {
      final markers = configLeakMarkers('', '''
{"openai": {"ids": ["z-ai/glm-5.3-flash", "openai/gpt-4o"]}}
''');
      expect(markers, contains('z-ai/glm-5.3-flash'));
      // Bundled ids fetched from a live endpoint are dropped the same way.
      expect(markers, isNot(contains('openai/gpt-4o')));
    });

    test('no real config on the machine means no markers', () {
      expect(configLeakMarkers('', ''), isEmpty);
    });

    test('a distinctive real id survives catalog subtraction', () {
      expect(
        configLeakMarkers('model: epam/secret-model\n', ''),
        contains('epam/secret-model'),
      );
    });

    test('a live id that prefixes a catalog row is dropped', () {
      // openrouter serves 'openai/gpt-4.1'; the bundled fallback renders
      // 'openai/gpt-4.1-mini' — the substring hit is catalog content, not
      // a leak (issue #508).
      final markers = configLeakMarkers(
        '',
        '{"openrouter": {"ids": ["openai/gpt-4.1"]}}',
      );
      expect(markers, isNot(contains('openai/gpt-4.1')));
    });
  });

  group('findConfigLeak — screen scan', () {
    test('names the offending marker on a leaked screen', () {
      final hit = findConfigLeak(
        'boot banner\n[Model]\n  openai/gpt-4o-mini (openai-completions)\n',
        {'other-provider', 'openai/gpt-4o-mini'},
      );
      expect(hit, 'openai/gpt-4o-mini');
    });

    test('a fixture-only screen is clean', () {
      final hit = findConfigLeak(
        '[Model]\n  test-model (openai-completions)\n1) test-provider/test-model\n',
        {'openai/gpt-4o-mini', 'epam-copilot'},
      );
      expect(hit, isNull);
    });
  });
}
