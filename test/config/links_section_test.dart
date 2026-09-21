/// The `links:` section through the config SERVICE (issue #691): the
/// section is a first-class top-level key — `fa config get
/// `links.<member>`` resolves it, `fa config set` writes it through the
/// strict section validator (a value the next boot would reject is
/// never persisted), and `fa config check` reports a bad shape as a
/// named error. Mirrors the shape of `config_service_test.dart` over a
/// [MemoryExecutionEnv].
library;

import 'package:flutter_agent_harness/src/config/config_service.dart';
import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/exceptions.dart';
import 'package:test/test.dart';

const _globalConfig = '/home/.fah/config.yaml';

const _base = '''
provider: openai-completions
model: openai/gpt-4o-mini
baseUrl: https://openrouter.ai/api/v1
mode: code
approvalMode: yolo
''';

void main() {
  late MemoryExecutionEnv env;
  late ConfigService service;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    service = ConfigService(env: env, homeDir: '/home');
  });

  group('get', () {
    test('links is a known top-level key', () {
      expect(configTopLevelKeys, contains('links'));
    });

    test(
      'absent section reports not set (defaults apply in-process)',
      () async {
        await env.writeFile(_globalConfig, _base);
        final result = await service.get('links.appstore');
        expect(result.found, isFalse);
      },
    );

    test('a written member resolves through the dotted path', () async {
      await env.writeFile(
        _globalConfig,
        '$_base\nlinks:\n  appstore: https://apps.apple.com/us/app/fa/id77\n',
      );
      final result = await service.get('links.appstore');
      expect(result.found, isTrue);
      expect(result.display, 'https://apps.apple.com/us/app/fa/id77');
    });

    test(
      'an unknown links member reports not set (no invented defaults)',
      () async {
        await env.writeFile(_globalConfig, _base);
        final result = await service.get('links.nope');
        expect(result.found, isFalse);
      },
    );
  });

  group('set', () {
    test('a good appstore link persists and reads back', () async {
      await env.writeFile(_globalConfig, _base);
      final result = await service.set(
        'links.appstore',
        'https://apps.apple.com/us/app/fa/id78',
      );
      expect(result.key, 'links.appstore');
      final readBack = await service.get('links.appstore');
      expect(readBack.display, 'https://apps.apple.com/us/app/fa/id78');
    });

    test('a non-URL value is rejected — nothing persists', () async {
      await env.writeFile(_globalConfig, _base);
      await expectLater(
        service.set('links.appstore', 'banana'),
        throwsA(isA<ConfigException>()),
      );
      final readBack = await service.get('links.appstore');
      expect(readBack.found, isFalse);
    });

    test('a non-boolean banner is rejected', () async {
      await env.writeFile(_globalConfig, _base);
      await expectLater(
        service.set('links.banner', 'sometimes'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('an unknown member persists as a tolerant note (AC7)', () async {
      await env.writeFile(_globalConfig, _base);
      final result = await service.set(
        'links.socials',
        'https://example.com/@fa',
      );
      expect(result.key, 'links.socials');
      // The section parse is tolerant: an unknown member survives as a
      // note, never an error — a future key must not brick the boot.
      final report = await service.check();
      expect(report.errors, isEmpty);
      final readBack = await service.get('links.socials');
      expect(readBack.display, 'https://example.com/@fa');
    });

    test('an explicit project scope is refused — links is user-only', () async {
      await env.writeFile(_globalConfig, _base);
      await expectLater(
        service.set(
          'links.testflight',
          'https://testflight.apple.com/join/YY',
          scope: ConfigScope.project,
        ),
        throwsA(isA<ConfigException>()),
      );
      final readBack = await service.get('links.testflight');
      expect(readBack.found, isFalse);
    });
  });

  group('check', () {
    test('a well-formed section passes clean', () async {
      await env.writeFile(
        _globalConfig,
        '$_base\nlinks:\n  appstore: https://apps.apple.com/us/app/fa/id1\n'
        '  banner: false\n',
      );
      final report = await service.check();
      expect(report.errors, isEmpty);
    });

    test('a bad shape is a named error, never a silent default', () async {
      await env.writeFile(_globalConfig, '$_base\nlinks:\n  appstore: 42\n');
      final report = await service.check();
      expect(report.ok, isFalse);
      expect(
        report.errors.map((e) => e.toString()).join('\n'),
        allOf(contains(_globalConfig), contains('links')),
      );
    });

    test('a non-map section is a named error', () async {
      await env.writeFile(_globalConfig, '$_base\nlinks: nope\n');
      final report = await service.check();
      expect(report.ok, isFalse);
      expect(
        report.errors.map((e) => e.toString()).join('\n'),
        contains('links'),
      );
    });
  });
}
