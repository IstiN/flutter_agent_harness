import 'package:fa/provider_registry.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
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
  });
}
