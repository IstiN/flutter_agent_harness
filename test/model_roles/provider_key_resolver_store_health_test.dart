// gh-1679 AC3 (UT-3, IT-3): the no-key skip reason / 401 hint renders
// distinct states — a degraded store ("keys pasted earlier may not have
// persisted") vs a healthy-but-empty store (today's plain wording) — each
// naming the exact slot and the matching remediation. App-side parity
// rides the HostKeyResolver.missingKeyHint seam; the CLI side rides
// KeyStatusRenderer.noKeyHint / customEndpointAuthHint.
import 'package:flutter_agent_harness/src/cli/custom_providers.dart';
import 'package:flutter_agent_harness/src/cli/key_status.dart';
import 'package:flutter_agent_harness/src/model_roles/provider_key_resolver.dart';
import 'package:flutter_agent_harness/src/secrets/secure_key_store.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart';

void main() {
  group('HostKeyResolver.missingKeyHint store-health states (gh-1679 AC3)',
      () {
    const baseUrl = 'https://api.kimi.com/coding/v1';

    HostKeyResolution resolve({
      bool storeDegraded = false,
      String? lastStoreError,
    }) =>
        HostKeyResolver(
          envRead: (_) => null,
          storeRead: (_) => null,
        ).resolveKey(
          provider: 'kimi',
          baseUrl: baseUrl,
          storeDegraded: storeDegraded,
          lastStoreError: lastStoreError,
        );

    test('healthy-and-empty store keeps the plain wording naming the slot',
        () {
      final hint = resolve().missingKeyHint;
      expect(hint, isNotNull);
      expect(hint, contains('provider "kimi"'));
      expect(hint, contains('/key set FA_KEY_API_KIMI_COM <value>'));
      expect(hint, isNot(contains('not persisted')));
    });

    test('degraded store names the last write failure and the persist '
        'caveat', () {
      final hint = resolve(
        storeDegraded: true,
        lastStoreError: 'no default keychain (exit 1)',
      ).missingKeyHint;
      expect(hint, isNotNull);
      expect(hint, contains('secure store is not writable'));
      expect(hint, contains('no default keychain (exit 1)'));
      expect(hint, contains('may not have persisted'));
      expect(hint, contains('/key set FA_KEY_API_KIMI_COM <value>'));
    });

    test('a resolved key never carries the degraded hint', () {
      final resolution = HostKeyResolver(
        envRead: (_) => null,
        storeRead: (name) => name == 'FA_KEY_API_KIMI_COM' ? 'sk-kimi' : null,
      ).resolveKey(
        provider: 'kimi',
        baseUrl: baseUrl,
        storeDegraded: true,
        lastStoreError: 'no default keychain (exit 1)',
      );
      expect(resolution.slotName, 'FA_KEY_API_KIMI_COM');
      expect(resolution.missingKeyHint, isNull);
    });
  });

  group('KeyStatusRenderer no-key hint store-health states (gh-1679 AC3)',
      () {
    const customUrl = 'https://api.kimi.com/coding/v1';

    Future<KeyStatusRenderer> rendererWith({
      required FakeSecureKeyStore store,
      bool seedSaveFailure = false,
    }) async {
      final keys = SecureKeyCache(store);
      await keys.probe();
      if (seedSaveFailure) {
        store.failWrites = true;
        await keys.save('FA_KEY_SEED', 'sk-seed-value');
        store.failWrites = false;
      }
      return KeyStatusRenderer(
        rolesDriven: false,
        providerKind: 'openai-completions',
        explicitToken: false,
        activeCustomName: null,
        red: (message) => message,
        secureKeys: keys,
        customProviders: CustomProviderRegistry(const []),
        envVarIsSet: (_) => false,
        envVarValue: (_) => null,
      );
    }

    test('healthy store: the custom-endpoint hint is the plain wording',
        () async {
      final renderer = await rendererWith(store: FakeSecureKeyStore());
      final hint = renderer.customEndpointAuthHint(customUrl);
      expect(hint, isNotNull);
      expect(hint, contains('no key resolved for $customUrl'));
      expect(hint, contains('/key set FA_KEY_API_KIMI_COM <value>'));
      expect(hint, isNot(contains('not persisted')));
    });

    test('degraded store: the hint names the last write failure and the '
        'persist caveat; never the value', () async {
      final renderer = await rendererWith(
        store: FakeSecureKeyStore(),
        seedSaveFailure: true,
      );
      final hint = renderer.customEndpointAuthHint(customUrl);
      expect(hint, isNotNull);
      expect(hint, contains('secure store is not writable'));
      expect(hint, contains('keychain write failed (exit 45)'));
      expect(hint, contains('may not have persisted'));
      expect(hint, contains('/key set FA_KEY_API_KIMI_COM <value>'));
      expect(hint, isNot(contains('sk-seed-value')));
    });

    test('the errorLine 401 path carries the degraded wording end-to-end',
        () async {
      final renderer = await rendererWith(
        store: FakeSecureKeyStore(),
        seedSaveFailure: true,
      );
      final line = renderer.errorLine(
        '401 Invalid Authentication — no key set',
        customUrl,
      );
      expect(line, contains('error: 401'));
      expect(line, contains('secure store is not writable'));
      expect(line, contains('/key set FA_KEY_API_KIMI_COM <value>'));
      expect(line, isNot(contains('sk-seed-value')));
    });
  });
}
