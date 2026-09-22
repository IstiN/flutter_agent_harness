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
    // null, even with the env var present (the boot pair-guard degrades
    // this shape before the key gate).
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
}
