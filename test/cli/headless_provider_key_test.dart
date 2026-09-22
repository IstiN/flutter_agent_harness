// Headless (`fa --provider copilot`) API-key resolution: the catalog env
// name COPILOT_GITHUB_TOKEN resolves env-first, then endpoint-scoped store
// entries (what `/provider copilot` writes), then legacy env-name slots.
//
// The function lives in `lib/src/cli/headless_provider_key.dart`; this
// test pins the copilot branch of the resolution order.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:test/test.dart';
import 'agent_cli_test_support.dart';

void main() {
  test('copilot resolves COPILOT_GITHUB_TOKEN from the environment first', () {
    final store = FakeSecureKeyStore()..map['COPILOT_GITHUB_TOKEN'] = 'stored';
    final keys = SecureKeyCache(store);

    final key = optionalProviderApiKey(
      'copilot',
      keys,
      env: const {'COPILOT_GITHUB_TOKEN': 'from-env'},
    );

    expect(key, 'from-env');
  });

  test('copilot falls back to the stored catalog env name', () async {
    final store = FakeSecureKeyStore()..map['COPILOT_GITHUB_TOKEN'] = 'stored';
    final keys = SecureKeyCache(store);
    await keys.preload(const ['COPILOT_GITHUB_TOKEN']);

    final key = optionalProviderApiKey('copilot', keys, env: const {});

    expect(key, 'stored');
  });

  test('a non-default copilot endpoint resolves the saved entry key', () async {
    final store = FakeSecureKeyStore()
      ..map['FA_KEY_COPILOT_COPILOT_X'] = 'entry-key';
    final keys = SecureKeyCache(store);
    await keys.preload(const ['FA_KEY_COPILOT_COPILOT_X']);

    final key = optionalProviderApiKey(
      'copilot',
      keys,
      baseUrl: 'https://api.business.githubcopilot.com',
      scopedKeyNames: ['FA_KEY_COPILOT_COPILOT_X'],
      env: const {},
    );

    expect(key, 'entry-key');
  });

  test(
    'copilot without any key resolves null (headless then fails loudly)',
    () {
      final keys = SecureKeyCache(FakeSecureKeyStore());
      final key = optionalProviderApiKey('copilot', keys, env: const {});

      expect(key, isNull);
    },
  );

  group('both identifiers resolve the same key slot (issue #772)', () {
    test('name and kind both answer the ChatGPT OAuth credential', () async {
      final store = FakeSecureKeyStore()
        ..map['CHATGPT_OAUTH_CREDENTIALS'] = 'oauth-blob';
      final keys = SecureKeyCache(store);
      await keys.preload(const ['CHATGPT_OAUTH_CREDENTIALS']);

      for (final id in ['chatgpt', 'chatgpt-codex']) {
        final key = optionalProviderApiKey(id, keys, env: const {});
        expect(key, 'oauth-blob', reason: '$id: key resolution');
      }
    });

    test('an unknown kind never invents a key', () {
      final keys = SecureKeyCache(FakeSecureKeyStore());
      expect(
        optionalProviderApiKey('from-the-future', keys, env: const {}),
        isNull,
      );
    });
  });
}
