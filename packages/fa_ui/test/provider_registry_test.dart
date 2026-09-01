import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ProviderRegistry persistence', () {
    test('missing file loads as empty', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      expect(registry.providers, isEmpty);
    });

    test('corrupt file loads as empty instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/providers.json', 'not json {');
      final registry = await ProviderRegistry.load(env);
      expect(registry.providers, isEmpty);
    });

    test('wrong schema version loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/providers.json',
        '{"version": 99, "providers": []}',
      );
      final registry = await ProviderRegistry.load(env);
      expect(registry.providers, isEmpty);
    });

    test('providers round-trip through the env filesystem', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final acme = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await registry.add(
        name: 'Beta',
        baseUrl: 'https://beta.example/v1',
        modelId: 'beta-2',
      );

      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.providers, hasLength(2));
      expect(reloaded.providers[0].id, acme.id);
      expect(reloaded.providers[0].name, 'Acme');
      expect(reloaded.providers[0].baseUrl, 'https://acme.example/v1');
      expect(reloaded.providers[0].modelId, 'acme-1');
      expect(reloaded.providers[1].name, 'Beta');
    });

    test('the registry file lives at the sandbox root', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );

      final text = (await env.readTextFile(
        '${env.cwd}/${ProviderRegistry.fileName}',
      )).valueOrNull;
      expect(text, isNotNull);
      expect(text, contains('"Acme"'));
      expect(text, contains('https://acme.example/v1'));
    });

    test('update replaces the definition and persists', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );

      await registry.update(
        CustomProvider(
          id: provider.id,
          name: 'Acme 2',
          baseUrl: 'https://acme2.example/v1',
          modelId: 'acme-2',
        ),
      );

      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.providers, hasLength(1));
      expect(reloaded.providers.single.name, 'Acme 2');
      expect(reloaded.providers.single.baseUrl, 'https://acme2.example/v1');
      expect(reloaded.providers.single.modelId, 'acme-2');
    });

    test('remove deletes the provider and its session key', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'sk-secret');

      await registry.remove(provider.id);

      expect(registry.providers, isEmpty);
      expect(registry.keyFor(provider.id), isNull);
      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.providers, isEmpty);
    });

    test('session keys are remembered in memory but never persisted', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );

      registry.rememberKey(provider.id, 'sk-secret');
      expect(registry.keyFor(provider.id), 'sk-secret');

      final raw = (await env.readTextFile(
        '${env.cwd}/${ProviderRegistry.fileName}',
      )).valueOrNull!;
      expect(raw, isNot(contains('sk-secret')));

      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.keyFor(provider.id), isNull);
    });

    test('an empty key forgets the remembered one', () {
      final registry = ProviderRegistry.inMemory();
      registry.rememberKey('p1', 'sk-secret');
      registry.rememberKey('p1', '');
      expect(registry.keyFor('p1'), isNull);
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

    test('CustomProvider equality is by id (edits keep selections valid)', () {
      const a = CustomProvider(
        id: 'p1',
        name: 'Acme',
        baseUrl: 'https://a.example/v1',
        modelId: 'm1',
      );
      const b = CustomProvider(
        id: 'p1',
        name: 'Acme renamed',
        baseUrl: 'https://b.example/v1',
        modelId: 'm2',
      );
      const c = CustomProvider(
        id: 'p2',
        name: 'Acme',
        baseUrl: 'https://a.example/v1',
        modelId: 'm1',
      );
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, b.hashCode);
    });

    test('preset model overrides persist and reload', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      expect(registry.presetModelOverride('openrouter'), isNull);

      await registry.setPresetModelOverride('openrouter', 'anthropic/claude');
      expect(registry.presetModelOverride('openrouter'), 'anthropic/claude');

      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.presetModelOverride('openrouter'), 'anthropic/claude');
      // Overrides ride the same envelope as the providers.
      final raw = (await env.readTextFile(
        '${env.cwd}/${ProviderRegistry.fileName}',
      )).valueOrNull!;
      expect(raw, contains('"presetModels"'));
      expect(raw, contains('anthropic/claude'));
    });

    test('clearing a preset model override removes it', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(env);
      await registry.setPresetModelOverride('openrouter', 'anthropic/claude');
      await registry.setPresetModelOverride('openrouter', null);
      expect(registry.presetModelOverride('openrouter'), isNull);
      // An empty string clears too.
      await registry.setPresetModelOverride('openrouter', 'm');
      await registry.setPresetModelOverride('openrouter', '');
      expect(registry.presetModelOverride('openrouter'), isNull);

      final reloaded = await ProviderRegistry.load(env);
      expect(reloaded.presetModelOverride('openrouter'), isNull);
    });

    test('preset model overrides notify listeners', () async {
      final registry = ProviderRegistry.inMemory();
      var notifications = 0;
      registry.addListener(() => notifications++);
      await registry.setPresetModelOverride('openrouter', 'm1');
      expect(notifications, 1);
      // A no-op set (same value) does not notify.
      await registry.setPresetModelOverride('openrouter', 'm1');
      expect(notifications, 1);
      await registry.setPresetModelOverride('openrouter', null);
      expect(notifications, 2);
    });

    test('a file without presetModels loads with none', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/providers.json',
        '{"version": 1, "providers": []}',
      );
      final registry = await ProviderRegistry.load(env);
      expect(registry.presetModelOverride('openrouter'), isNull);
    });

    test('keyValueForName resolves a provider session key by its host-scoped '
        'name', () async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      expect(registry.keyValueForName('FA_KEY_ACME_EXAMPLE'), isNull);

      registry.rememberKey(provider.id, 'sk-acme');
      expect(registry.keyValueForName('FA_KEY_ACME_EXAMPLE'), 'sk-acme');
      // Unknown names resolve to null.
      expect(registry.keyValueForName('FA_KEY_OTHER_EXAMPLE'), isNull);

      registry.rememberKey(provider.id, '');
      expect(registry.keyValueForName('FA_KEY_ACME_EXAMPLE'), isNull);
    });
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

    test('rememberKey persists host-scoped; load hydrates keys', () async {
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      final acme = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(acme.id, 'sk-acme');
      // Fire-and-forget persistence: let the channel call land.
      await Future<void>.delayed(Duration.zero);
      expect(backend['FA_KEY_ACME_EXAMPLE'], 'sk-acme');

      // A fresh boot restores the key from the Keychain, not the file.
      final reloaded = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      expect(reloaded.keyFor(acme.id), 'sk-acme');
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

    test('remove deletes the provider and its Keychain slot', () async {
      backend['FA_KEY_ACME_EXAMPLE'] = 'sk-acme';
      final env = MemoryExecutionEnv();
      final registry = await ProviderRegistry.load(
        env,
        keychain: const KeychainStore(),
      );
      final acme = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      expect(registry.keyFor(acme.id), 'sk-acme');

      await registry.remove(acme.id);
      expect(backend.containsKey('FA_KEY_ACME_EXAMPLE'), isFalse);
      expect(registry.keyFor(acme.id), isNull);
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
}
