// `.fahx` provider export/import (issue #34 item 3, fallback tier):
// crypto round-trips, loud wrong-passphrase/tamper failures, and the
// nothing-written-on-failure contract.
@Timeout(Duration(seconds: 30))
library;

import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/provider_export.dart';
import 'package:test/test.dart';

void main() {
  final entries = [
    CustomProviderEntry(
      name: 'zai',
      apiType: 'openai',
      baseUrl: 'https://api.z.ai/api/paas/v4',
      modelId: 'glm-4.6',
      keyName: 'FA_KEY_TEST_ZAI',
    ),
    CustomProviderEntry(
      name: 'openrouter',
      apiType: 'openai',
      baseUrl: 'https://openrouter.ai/api/v1',
      modelId: 'anthropic/claude-sonnet-4',
    ),
  ];

  group('encrypt/decrypt round-trip', () {
    test('decrypts what it encrypted', () {
      const plaintext = '{"version":1,"providers":[{"name":"zai"}]}';
      final envelope = encryptProvidersExport(plaintext, 'pass-phrase-1');
      expect(envelope['version'], providerExportVersion);
      expect((envelope['kdf'] as Map)['algo'], 'pbkdf2-sha256');
      expect((envelope['kdf'] as Map)['iterations'], providerExportIterations);
      expect(decryptProvidersExport(envelope, 'pass-phrase-1'), plaintext);
    });

    test('a fresh envelope uses a fresh salt and nonce', () {
      final a = encryptProvidersExport('x', 'p');
      final b = encryptProvidersExport('x', 'p');
      expect((a['kdf'] as Map)['salt'], isNot((b['kdf'] as Map)['salt']));
      expect(a['nonce'], isNot(b['nonce']));
    });
  });

  group('decryptProvidersExport', () {
    test('a wrong passphrase fails LOUDLY', () {
      final envelope = encryptProvidersExport('secret payload', 'right');
      expect(
        () => decryptProvidersExport(envelope, 'wrong'),
        throwsA(isA<ProviderExportException>()),
      );
    });

    test('a flipped ciphertext bit is rejected (tamper)', () {
      final envelope = encryptProvidersExport('secret payload', 'right');
      final blob = base64Decode(envelope['ct'] as String);
      blob[0] ^= 0x01;
      final tampered = {...envelope, 'ct': base64Encode(blob)};
      expect(
        () => decryptProvidersExport(tampered, 'right'),
        throwsA(
          isA<ProviderExportException>().having(
            (e) => e.message,
            'message',
            contains('wrong passphrase or corrupted'),
          ),
        ),
      );
    });

    for (final (name, mutate) in [
      (
        'an unsupported version',
        (Map<String, dynamic> e) => {...e, 'version': 99},
      ),
      (
        'an unsupported kdf',
        (Map<String, dynamic> e) => {
          ...e,
          'kdf': {...(e['kdf'] as Map), 'algo': 'rot13'},
        },
      ),
      (
        'a malformed ct field',
        (Map<String, dynamic> e) => {...e, 'ct': '!!!not-base64!!!'},
      ),
    ]) {
      test('rejects $name', () {
        final envelope = encryptProvidersExport('x', 'p');
        expect(
          () => decryptProvidersExport(mutate(envelope), 'p'),
          throwsA(isA<ProviderExportException>()),
        );
      });
    }
  });

  group('importProvidersExport (pure)', () {
    test('round-trips an exported payload into entries + keys', () {
      final envelope = encryptProvidersExport(
        jsonEncode({
          'version': providerExportVersion,
          'providers': [
            for (final (i, e) in entries.indexed)
              {
                'name': e.name,
                'apiType': e.apiType,
                'baseUrl': e.baseUrl,
                'modelId': e.modelId,
                'keyName': ?e.keyName,
                if (i == 0) 'key': 'sk-secret',
              },
          ],
        }),
        'pass-phrase-1',
      );
      final imported = importProvidersExport(
        jsonEncode(envelope),
        'pass-phrase-1',
      );
      expect(imported, hasLength(2));
      expect(imported.first.entry.name, 'zai');
      expect(imported.first.key, 'sk-secret');
      expect(imported.last.entry.name, 'openrouter');
      expect(imported.last.key, isNull);
    });

    test('a wrong passphrase is a loud rejection, never empty output', () {
      final envelope = encryptProvidersExport(
        jsonEncode({'version': 1, 'providers': []}),
        'right',
      );
      expect(
        () => importProvidersExport(jsonEncode(envelope), 'wrong'),
        throwsA(isA<ProviderExportException>()),
      );
    });

    test('a tampered file is rejected and imports nothing', () {
      final envelope = encryptProvidersExport(
        jsonEncode({'version': 1, 'providers': []}),
        'right',
      );
      final blob = base64Decode(envelope['ct'] as String);
      blob[blob.length - 33] ^= 0xff;
      final tampered = jsonEncode({...envelope, 'ct': base64Encode(blob)});
      expect(
        () => importProvidersExport(tampered, 'right'),
        throwsA(isA<ProviderExportException>()),
      );
    });

    test('a non-JSON file is a loud rejection', () {
      expect(
        () => importProvidersExport('not json at all', 'right'),
        throwsA(
          isA<ProviderExportException>().having(
            (e) => e.message,
            'message',
            contains('.fahx file is not valid JSON'),
          ),
        ),
      );
    });

    test('a JSON envelope that is not an object is a loud rejection', () {
      expect(
        () => importProvidersExport('[1, 2]', 'right'),
        throwsA(
          isA<ProviderExportException>().having(
            (e) => e.message,
            'message',
            contains('.fahx file is not valid JSON'),
          ),
        ),
      );
    });

    test('a payload that is not an object is malformed', () {
      final envelope = encryptProvidersExport('[true]', 'right');
      expect(
        () => importProvidersExport(jsonEncode(envelope), 'right'),
        throwsA(isA<ProviderExportException>()),
      );
    });

    test(
      'a payload with a wrong version or non-list providers is malformed',
      () {
        for (final payload in [
          {'version': 99, 'providers': []},
          {'version': providerExportVersion, 'providers': 'nope'},
        ]) {
          final envelope = encryptProvidersExport(jsonEncode(payload), 'right');
          expect(
            () => importProvidersExport(jsonEncode(envelope), 'right'),
            throwsA(
              isA<ProviderExportException>().having(
                (e) => e.message,
                'message',
                contains('.fahx payload is malformed'),
              ),
            ),
          );
        }
      },
    );

    test('entries with missing or empty required fields are malformed', () {
      for (final entry in [
        'not-an-object',
        {'apiType': 'openai', 'baseUrl': 'https://x', 'modelId': 'm'},
        {
          'name': '',
          'apiType': 'openai',
          'baseUrl': 'https://x',
          'modelId': 'm',
        },
        {'name': 'n', 'apiType': 'openai', 'modelId': 'm'},
        {'name': 'n', 'apiType': 'openai', 'baseUrl': '', 'modelId': 'm'},
        {'name': 'n', 'apiType': 'openai', 'baseUrl': 'https://x'},
      ]) {
        final envelope = encryptProvidersExport(
          jsonEncode({
            'version': providerExportVersion,
            'providers': [entry],
          }),
          'right',
        );
        expect(
          () => importProvidersExport(jsonEncode(envelope), 'right'),
          throwsA(
            isA<ProviderExportException>().having(
              (e) => e.message,
              'message',
              contains('.fahx payload is malformed'),
            ),
          ),
          reason: '$entry must be rejected',
        );
      }
    });

    test('empty keyName/key strings import as absent', () {
      final envelope = encryptProvidersExport(
        jsonEncode({
          'version': providerExportVersion,
          'providers': [
            {
              'name': 'n',
              'apiType': 'openai',
              'baseUrl': 'https://x',
              'modelId': 'm',
              'keyName': '',
              'key': '',
            },
          ],
        }),
        'right',
      );
      final imported = importProvidersExport(jsonEncode(envelope), 'right');
      expect(imported.single.entry.keyName, isNull);
      expect(imported.single.key, isNull);
    });
  });

  group('runProviderExportCommand', () {
    test(
      'writes an importable .fahx with keys resolved from the env',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final out = <String>[];
        final code = await runProviderExportCommand(
          const ConfigCliCommand(verb: 'export-providers'),
          io: _FakeIO(sink: out.add),
          env: env,
          entries: entries,
          secureRead: (_) => null,
          environment: {'FA_KEY_TEST_ZAI': 'sk-from-env'},
          readPassphrase: () async => 'pass-phrase-1',
          iterations: 1000,
        );
        expect(code, 0);
        final read = await env.readTextFile('providers.fahx');
        final imported = importProvidersExport(
          read.getOrThrow(),
          'pass-phrase-1',
        );
        expect(imported.first.key, 'sk-from-env');
        expect(imported.last.key, isNull);
        // Keys never leak to output lines.
        expect(out.join('\n'), isNot(contains('sk-from-env')));
      },
    );

    test('an absent key warns and exports the entry without it', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final out = <String>[];
      final code = await runProviderExportCommand(
        const ConfigCliCommand(verb: 'export-providers'),
        io: _FakeIO(sink: out.add),
        env: env,
        entries: entries,
        secureRead: (name) => name == 'FA_KEY_TEST_ZAI' ? 'sk-store' : null,
        environment: const {},
        readPassphrase: () async => 'p',
        iterations: 1000,
      );
      expect(code, 0);
      expect(out.join('\n'), contains('warning: no key for "openrouter"'));
      final read = await env.readTextFile('providers.fahx');
      final imported = importProvidersExport(read.getOrThrow(), 'p');
      expect(imported.first.key, 'sk-store');
      expect(imported.last.key, isNull);
    });

    test('mismatched prompts write nothing and exit non-zero', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final prompts = ['first', 'second'];
      final code = await runProviderExportCommand(
        const ConfigCliCommand(verb: 'export-providers'),
        io: _FakeIO(sink: (_) {}),
        env: env,
        entries: entries,
        environment: const {},
        readPassphrase: () async => prompts.removeAt(0),
      );
      expect(code, 1);
      final read = await env.readTextFile('providers.fahx');
      expect(read.isErr, isTrue);
    });

    test('--passphrase-stdin uses the injected stdin line', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      var prompts = 0;
      final code = await runProviderExportCommand(
        const ConfigCliCommand(verb: 'export-providers', passphraseStdin: true),
        io: _FakeIO(sink: (_) {}),
        env: env,
        entries: entries,
        environment: const {},
        readPassphrase: () {
          prompts++;
          return Future.value('p');
        },
        iterations: 1000,
      );
      expect(code, 0);
      expect(prompts, 1);
    });

    test('an unknown verb is a clean non-zero exit', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final out = <String>[];
      final code = await runProviderExportCommand(
        const ConfigCliCommand(verb: 'nope'),
        io: _FakeIO(sink: out.add),
        env: env,
        entries: entries,
      );
      expect(code, 1);
      expect(out.join('\n'), contains('unknown config verb'));
    });
  });
}

/// A scripted [CliIO]: no stdin, output captured.
final class _FakeIO implements CliIO {
  _FakeIO({required this.sink});

  final void Function(String line) sink;

  @override
  Stream<String> get lines => const Stream.empty();

  @override
  Stream<void> get interrupts => const Stream.empty();

  @override
  Stream<KeyEvent> get keys => const Stream.empty();

  @override
  bool get supportsRawMode => false;

  @override
  void write(String text) => sink(text);

  @override
  void writeln(String text) => sink(text);

  @override
  bool get isInteractive => false;

  @override
  int get columns => 80;

  @override
  int get rows => 24;
}
