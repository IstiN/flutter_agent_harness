import 'dart:convert';

import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProviderRegistry persistence', () {




    test(
      'the connect-flow identity kind round-trips; plain entries stay null',
      () async {
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(env);
        await registry.add(
          name: 'ChatGPT Codex',
          baseUrl: chatGptCodexBaseUrl,
          modelId: 'gpt-5.6-sol',
          kind: 'chatgpt-codex',
        );
        await registry.add(
          name: 'Plain',
          baseUrl: 'https://api.openai.com/v1',
          modelId: 'gpt-4.1',
        );

        final reloaded = await ProviderRegistry.load(env);
        expect(reloaded.providers[0].kind, 'chatgpt-codex');
        expect(reloaded.providers[1].kind, isNull);
        // JSON stays lean: no kind key for identity-less entries.
        final raw = (await env.readTextFile(
          '${env.cwd}/providers.json',
        )).valueOrNull!;
        final stored = jsonDecode(raw) as Map<String, dynamic>;
        final plain =
            (stored['providers'] as List).last as Map<String, dynamic>;
        expect(plain.containsKey('kind'), isFalse);
      },
    );

    test('every entry rebuild path preserves the identity kind', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final codex = await registry.add(
        name: 'ChatGPT Codex',
        baseUrl: chatGptCodexBaseUrl,
        modelId: 'gpt-5.6-sol',
        kind: 'chatgpt-codex',
      );

      // The settings/section edit paths rebuild the entry by hand and hand
      // it to `update` — a rebuild that drops `kind` would silently demote
      // the entry back to URL-shape dispatch guessing.
      await registry.update(
        CustomProvider(
          id: codex.id,
          name: codex.name,
          baseUrl: 'https://relay.example.net/codex-proxy',
          modelId: codex.modelId,
          provenance: codex.provenance,
          requiresKey: codex.requiresKey,
          kind: codex.kind,
        ),
      );
      var reloaded = await ProviderRegistry.load(env);
      expect(reloaded.providers.single.kind, 'chatgpt-codex');
      expect(
        reloaded.providers.single.baseUrl,
        'https://relay.example.net/codex-proxy',
      );

      // `rememberKey`'s requiresKey flip rebuilds the entry in place.
      reloaded.rememberKey(reloaded.providers.single.id, 'blob');
      expect(reloaded.providers.single.kind, 'chatgpt-codex');
      expect(reloaded.providers.single.requiresKey, isTrue);
      reloaded = await ProviderRegistry.load(env);
      expect(reloaded.providers.single.kind, 'chatgpt-codex');
    });






    test(
      'mutations notify listeners (in-memory registry persists nothing)',
      () async {
        final registry = ProviderRegistry.inMemory();
        var notifications = 0;
        registry.addListener(() => notifications++);

        final provider = await registry.add(
          name: 'Acme',
          baseUrl: 'https://acme.example/v1',
          modelId: 'acme-1',
        );
        expect(notifications, 1);
        await registry.update(
          CustomProvider(
            id: provider.id,
            name: 'Acme 2',
            baseUrl: provider.baseUrl,
            modelId: provider.modelId,
          ),
        );
        expect(notifications, 2);
        await registry.remove(provider.id);
        expect(notifications, 3);
        expect(registry.providers, isEmpty);
      },
    );






  });

  group('ProviderRegistry with a Keychain backend', () {
    const channel = MethodChannel('fah/keychain');
    final backend = <String, String>{};

    setUp(() {
      backend.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'isAvailable':
                return true;
              case 'readAll':
                return Map<String, String>.of(backend);
              case 'set':
                backend[call.arguments['name'] as String] =
                    call.arguments['value'] as String;
                return true;
              case 'delete':
                backend.remove(call.arguments['name'] as String);
                return true;
            }
            return null;
          });
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });


    test('load hydrates a Copilot entry from its entry-scoped slot', () async {
      // The connect flow persists the GitHub token entry-scoped
      // (`FA_KEY_COPILOT_<NAME>`, the CLI contract), never host-scoped —
      // a restart must still resolve it, or every /models fetch silently
      // 401s and the picker falls back to the saved model alone.
      backend['FA_KEY_COPILOT_COPILOT_OCTOCAT'] = 'gh-token';
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      final copilot = await registry.add(
        name: 'copilot-octocat',
        baseUrl: 'https://api.githubcopilot.com',
        modelId: 'gpt-4.1',
      );
      await Future<void>.delayed(Duration.zero);

      final reloaded = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(reloaded.keyFor(copilot.id), 'gh-token');
    });

    test('the load-time requiresKey upgrade rebuild preserves kind', () async {
      // A pre-marker entry (requiresKey false in the file) whose key IS in
      // the Keychain hits the upgrade rebuild on boot — the rebuilt entry
      // must keep the identity kind or the codex entry silently demotes to
      // URL-shape dispatch guessing after the first restart.
      final env = MemoryExecutionEnv();
      final seed = await ProviderRegistry.load(env);
      await seed.add(
        name: 'ChatGPT Codex',
        baseUrl: chatGptCodexBaseUrl,
        modelId: 'gpt-5.6-sol',
        kind: 'chatgpt-codex',
      );
      // Key exists in the Keychain, but the file entry predates the
      // keyed marker (requiresKey false).
      backend['FA_KEY_CHATGPT_COM'] = 'blob';

      final reloaded = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(reloaded.providers.single.requiresKey, isTrue);
      expect(reloaded.providers.single.kind, 'chatgpt-codex');
      expect(reloaded.keyFor(reloaded.providers.single.id), 'blob');
    });


    test(
      'removing a copilot entry deletes its entry-scoped token too',
      () async {
        const entryKey = 'FA_KEY_COPILOT_COPILOT_OCTOCAT';
        final keys = SessionKeysStore.inMemory();
        await keys.set(entryKey, 'gho_token');
        backend[entryKey] = 'gho_token';
        final env = MemoryExecutionEnv();
        final registry = await ProviderRegistry.load(
          env,
          keychain: const KeychainStore(),
          sessionKeys: keys,
        );
        final copilot = await registry.add(
          name: 'copilot-octocat',
          baseUrl: copilotIndividualBaseUrl,
          modelId: 'gpt-4.1',
        );
        registry.rememberKey(copilot.id, 'gho_token');
        // Fire-and-forget persistence: let the channel call land.
        await Future<void>.delayed(Duration.zero);
        expect(
          backend[ProviderRegistry.keyNameFor(copilotIndividualBaseUrl)],
          'gho_token',
        );

        await registry.remove(copilot.id);

        expect(
          backend.containsKey(
            ProviderRegistry.keyNameFor(copilotIndividualBaseUrl),
          ),
          isFalse,
        );
        expect(backend.containsKey(entryKey), isFalse);
        expect(keys.has(entryKey), isFalse);
        expect(registry.keyFor(copilot.id), isNull);
      },
    );

    test('removing a non-copilot entry leaves copilot keys alone', () async {
      const entryKey = 'FA_KEY_COPILOT_COPILOT_OCTOCAT';
      final keys = SessionKeysStore.inMemory();
      await keys.set(entryKey, 'gho_token');
      backend[entryKey] = 'gho_token';
      final registry = await ProviderRegistry.load(
        MemoryExecutionEnv(),
        keychain: const KeychainStore(),
        sessionKeys: keys,
      );
      final acme = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );

      await registry.remove(acme.id);

      expect(backend[entryKey], 'gho_token');
      expect(keys.has(entryKey), isTrue);
    });
  });

  group('ProviderRegistry on Android (issue #329)', () {
    // AC1 (IT-persist): with an Android-targeting configuration the key
    // must SURVIVE a store restart — rememberKey persists through the
    // `fah/keychain` secure backend (the Android embedding answers it with
    // Keystore-backed storage) and a fresh load hydrates it. RED on main:
    // the backend was iOS/macOS-only, so the key stayed session-only and
    // the next boot went keyless (z.ai 401/1001).
    const channel = MethodChannel('fah/keychain');
    final backend = <String, String>{};

    setUp(() {
      backend.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            switch (call.method) {
              case 'isAvailable':
                return true;
              case 'readAll':
                return Map<String, String>.of(backend);
              case 'set':
                backend[call.arguments['name'] as String] =
                    call.arguments['value'] as String;
                return true;
              case 'delete':
                backend.remove(call.arguments['name'] as String);
                return true;
            }
            return null;
          });
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('rememberKey persists across a restart (the key resolves)', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      final zai = await registry.add(
        name: 'z.ai',
        baseUrl: 'https://api.z.ai/api/coding/paas/v4',
        modelId: 'glm-4.7',
      );
      registry.rememberKey(zai.id, 'sk-zai');
      // Fire-and-forget persistence: let the channel call land.
      await Future<void>.delayed(Duration.zero);
      expect(backend['FA_KEY_API_Z_AI'], 'sk-zai');

      // The very next boot: a fresh registry resolves the key.
      final reloaded = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(reloaded.keyFor(zai.id), 'sk-zai');
    });

    test('the requiresKey marker rides providers.json', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      final zai = await registry.add(
        name: 'z.ai',
        baseUrl: 'https://api.z.ai/api/coding/paas/v4',
        modelId: 'glm-4.7',
      );
      registry.rememberKey(zai.id, 'sk-zai');
      await Future<void>.delayed(Duration.zero);
      final persisted =
          jsonDecode(
                (await env.readTextFile(
                  '${env.cwd}/providers.json',
                )).valueOrNull!,
              )
              as Map<String, dynamic>;
      expect(
        (persisted['providers'] as List).single['requiresKey'],
        isTrue,
        reason: 'the guard needs the marker across restarts',
      );

      // Forgetting the key clears the marker (an intentionally de-keyed
      // entry goes back to keyless-legal).
      registry.rememberKey(zai.id, '');
      await Future<void>.delayed(Duration.zero);
      final repersisted =
          jsonDecode(
                (await env.readTextFile(
                  '${env.cwd}/providers.json',
                )).valueOrNull!,
              )
              as Map<String, dynamic>;
      expect(
        (repersisted['providers'] as List).single.containsKey('requiresKey'),
        isFalse,
      );
    });
  });

  group('ProviderRegistry host-session seam (issue #2391)', () {
    test('upsert replaces by id and preserves insertion order', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final first = await registry.add(
        name: 'First',
        baseUrl: 'https://first.example/v1',
        modelId: 'first-1',
      );
      await registry.upsert(
        const CustomProvider(
          id: 'host',
          name: 'Host',
          baseUrl: 'https://api.example/v1',
          modelId: 'host/flash',
          provenance: 'host',
          kind: 'host-session',
        ),
      );
      await registry.upsert(
        const CustomProvider(
          id: 'host',
          name: 'Host Renamed',
          baseUrl: 'https://api.example/v2',
          modelId: 'host/pro',
          provenance: 'host',
          kind: 'host-session',
        ),
      );
      expect(registry.providers.length, 2);
      expect(registry.providers.first.id, first.id);
      final host = registry.providers.last;
      expect(host.id, 'host');
      expect(host.name, 'Host Renamed');
      expect(host.baseUrl, 'https://api.example/v2');
      expect(host.modelId, 'host/pro');
      expect(host.provenance, 'host');
      expect(host.kind, 'host-session');
      // The definition persists; a reload sees it.
      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.providers.where((p) => p.id == 'host').length, 1);
    });

    test('rememberSessionKey stays in memory: no file, no keychain, '
        'no requiresKey flip', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final host = await registry.upsert(
        const CustomProvider(
          id: 'host',
          name: 'Host',
          baseUrl: 'https://api.example/v1',
          modelId: 'host/flash',
          provenance: 'host',
          kind: 'host-session',
        ),
      );
      registry.rememberSessionKey('host', 'bridged-secret');
      expect(registry.keyFor('host'), 'bridged-secret');
      expect(
        registry.keyValueForName(
          ProviderRegistry.keyNameFor('https://api.example/v1'),
        ),
        'bridged-secret',
      );
      expect(host.requiresKey, isFalse);
      // Nothing persisted: the providers.json write only carries the
      // non-secret definition (no requiresKey marker, no key value).
      final persisted =
          jsonDecode(
                (await env.readTextFile(
                  '${env.cwd}/providers.json',
                )).valueOrNull!,
              )
              as Map<String, dynamic>;
      expect(jsonEncode(persisted).contains('bridged-secret'), isFalse);
      expect(jsonEncode(persisted).contains('requiresKey'), isFalse);
      // An empty value forgets, same convention as rememberKey.
      registry.rememberSessionKey('host', '');
      expect(registry.keyFor('host'), isNull);
    });
  });
}
