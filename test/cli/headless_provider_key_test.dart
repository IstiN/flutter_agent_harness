// Headless (`fa --provider copilot`) API-key resolution: the catalog env
// name COPILOT_GITHUB_TOKEN resolves env-first, then endpoint-scoped store
// entries (what `/provider copilot` writes), then legacy env-name slots.
//
// The function lives in `bin/fah.dart` (a proper library); this test pins
// the copilot branch of the resolution order.
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../../bin/fah.dart' as fah;
import 'agent_cli_test_support.dart';

void main() {
  test('copilot resolves COPILOT_GITHUB_TOKEN from the environment first', () {
    final store = FakeSecureKeyStore()..map['COPILOT_GITHUB_TOKEN'] = 'stored';
    final keys = SecureKeyCache(store);

    final key = fah.optionalProviderApiKey(
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

    final key = fah.optionalProviderApiKey('copilot', keys, env: const {});

    expect(key, 'stored');
  });

  test('a non-default copilot endpoint resolves the saved entry key', () async {
    final store = FakeSecureKeyStore()
      ..map['FA_KEY_COPILOT_COPILOT_X'] = 'entry-key';
    final keys = SecureKeyCache(store);
    await keys.preload(const ['FA_KEY_COPILOT_COPILOT_X']);

    final key = fah.optionalProviderApiKey(
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

      final key = fah.optionalProviderApiKey('copilot', keys, env: const {});

      expect(key, isNull);
    },
  );
}
