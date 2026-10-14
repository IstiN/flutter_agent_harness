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

  test('the chatgpt-codex KIND resolves key names through the chatgpt spec '
      '(gh-760 review)', () {
    // gh-760: the restored boot provider is the kind; the key layer must
    // map it to the catalog spec's OAuth credential slot.
    expect(apiKeyEnvNames('chatgpt-codex'), ['CHATGPT_OAUTH_CREDENTIALS']);
    expect(apiKeyEnvNames('CHATGPT-CODEX'), ['CHATGPT_OAUTH_CREDENTIALS']);
    expect(apiKeyEnvNames('chatgpt'), ['CHATGPT_OAUTH_CREDENTIALS']);
  });

  test('codex env creds resolve on the DEFAULT endpoint, never on a '
      'foreign one (gh-760 review)', () {
    final keys = SecureKeyCache(FakeSecureKeyStore());

    // The spec default (chatgpt.com): the env OAuth creds are the key.
    expect(
      optionalProviderApiKey(
        'chatgpt-codex',
        keys,
        env: const {'CHATGPT_OAUTH_CREDENTIALS': 'dummy-creds'},
      ),
      'dummy-creds',
    );
    // A foreign baseUrl is a custom endpoint: the catalog env names
    // describe the default endpoint and must never hijack it (#40) —
    // null, even with the env var present.
    expect(
      optionalProviderApiKey(
        'chatgpt-codex',
        keys,
        baseUrl: 'https://openrouter.ai/api/v1',
        env: const {'CHATGPT_OAUTH_CREDENTIALS': 'dummy-creds'},
      ),
      isNull,
    );
  });

  group('pinned key name (gh-1000 AC1)', () {
    const kimiUrl = 'https://api.kimi.com/coding/v1';

    test('the pinned entry slot beats the host-scoped slot', () async {
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_KIMI_COM'] = 'host-scoped-wrong-account'
        ..map['FA_KEY_API_KIMI_COM_KIMI_ME'] = 'kimi-me-key';
      final keys = SecureKeyCache(store);
      await keys.preload(store.map.keys.toList());

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: kimiUrl,
        pinnedKeyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
        env: const {},
      );

      expect(key, 'kimi-me-key');
    });

    test('the pinned name resolves from the environment first', () async {
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_KIMI_COM_KIMI_ME'] = 'stored';
      final keys = SecureKeyCache(store);
      await keys.preload(store.map.keys.toList());

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: kimiUrl,
        pinnedKeyName: 'FA_KEY_API_KIMI_COM_KIMI_ME',
        env: const {'FA_KEY_API_KIMI_COM_KIMI_ME': 'from-env'},
      );

      expect(key, 'from-env');
    });

    test('a missing pinned slot falls through to the legacy order', () async {
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_KIMI_COM'] = 'host-scoped';
      final keys = SecureKeyCache(store);
      await keys.preload(store.map.keys.toList());

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: kimiUrl,
        pinnedKeyName: 'FA_KEY_API_KIMI_COM_GONE',
        env: const {},
      );

      expect(key, 'host-scoped');
    });
  });

  group('endpoint normalization (gh-1570 L10/S4/E1)', () {
    test('a trailing-slash spelling of the DEFAULT endpoint still resolves '
        'the catalog env names', () async {
      final store = FakeSecureKeyStore()..map['OPENROUTER_API_KEY'] = 'stored';
      final keys = SecureKeyCache(store);
      await keys.preload(const ['OPENROUTER_API_KEY']);

      final key = optionalProviderApiKey(
        'openai-completions',
        keys,
        baseUrl: 'https://openrouter.ai/api/v1/',
        env: const {},
      );

      // Raw string comparison would classify the trailing-slash URL as a
      // CUSTOM endpoint and never probe the catalog names — keyless boot.
      expect(key, 'stored');
    });

    test('a trailing-slash default endpoint is not "custom" in '
        'startupApiKey — a missing required key still fails loud', () {
      expect(
        () => startupApiKey(
          'openai-completions',
          SecureKeyCache(FakeSecureKeyStore()),
          baseUrl: 'https://openrouter.ai/api/v1/',
          customProviders: const [],
          defaultRoleResolved: false,
          interactive: false,
          env: const {},
        ),
        throwsA(isA<ConfigException>()),
      );
    });
  });

  group('boot-time legacy slot migration (gh-1570 incident REG)', () {
    test('a key stranded under the previous release slot is COPIED onto '
        'the canonical slot, non-destructively, with a notice', () async {
      final store = FakeSecureKeyStore()
        ..map['FA_KEY_API_KIMI_COM'] = 'legacy-kimi-key';
      final keys = SecureKeyCache(store);
      await keys.preload(const [
        'FA_KEY_API_KIMI_COM_KIMI_IRA',
        'FA_KEY_API_KIMI_COM',
      ]);

      final notices = await migrateLegacyKeySlots(const [
        (
          baseUrl: 'https://api.kimi.com',
          providerName: 'kimi-ira',
          pinnedKeyName: null,
        ),
      ], keys);

      // The canonical slot now resolves; the legacy slot is KEPT (a
      // rollback keeps working); the notice names both slots.
      expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA'], 'legacy-kimi-key');
      expect(store.map['FA_KEY_API_KIMI_COM'], 'legacy-kimi-key');
      expect(notices, hasLength(1));
      expect(notices.single, contains('FA_KEY_API_KIMI_COM_KIMI_IRA'));
      expect(notices.single, contains('FA_KEY_API_KIMI_COM'));
      expect(notices.single, contains('migrated'));
    });

    test(
      'a canonical slot that already holds a value is never touched',
      () async {
        final store = FakeSecureKeyStore()
          ..map['FA_KEY_API_KIMI_COM'] = 'legacy-kimi-key'
          ..map['FA_KEY_API_KIMI_COM_KIMI_IRA'] = 'current-key';
        final keys = SecureKeyCache(store);
        await keys.preload(const ['FA_KEY_API_KIMI_COM_KIMI_IRA']);

        final notices = await migrateLegacyKeySlots(const [
          (
            baseUrl: 'https://api.kimi.com',
            providerName: 'kimi-ira',
            pinnedKeyName: null,
          ),
        ], keys);

        expect(notices, isEmpty);
        expect(store.map['FA_KEY_API_KIMI_COM_KIMI_IRA'], 'current-key');
      },
    );

    test('an unavailable store stays quiet — never a boot failure', () async {
      final keys = SecureKeyCache(FakeSecureKeyStore(available: false));
      await keys.preload(const []);

      final notices = await migrateLegacyKeySlots(const [
        (
          baseUrl: 'https://api.kimi.com',
          providerName: 'kimi-ira',
          pinnedKeyName: null,
        ),
      ], keys);

      expect(notices, isEmpty);
    });

    test('a failing keychain write degrades to the fallback notice — '
        'resolution still probes the legacy slot', () async {
      final store = FakeSecureKeyStore()
        ..failWrites = true
        ..map['FA_KEY_API_KIMI_COM'] = 'legacy-kimi-key';
      final keys = SecureKeyCache(store);
      await keys.preload(const ['FA_KEY_API_KIMI_COM']);

      final notices = await migrateLegacyKeySlots(const [
        (
          baseUrl: 'https://api.kimi.com',
          providerName: 'kimi-ira',
          pinnedKeyName: null,
        ),
      ], keys);

      expect(notices, hasLength(1));
      expect(notices.single, contains('could not migrate'));
      expect(notices.single, contains('falls back to the legacy slot'));
    });
  });
}
