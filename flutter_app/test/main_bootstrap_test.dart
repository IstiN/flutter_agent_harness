import 'package:fa/main.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('restorableBootConfig', () {
    const connection = LastConnection(
      providerKind: 'openai-completions',
      modelId: 'k3-256k',
      baseUrl: 'https://api.kimi.com/coding/v1',
    );

    test('null when nothing was ever configured', () {
      expect(
        restorableBootConfig(
          connection: null,
          registry: null,
          sessionKeysStore: null,
        ),
        isNull,
      );
    });

    test('null for on-device connections (the quick start re-offers them)', () {
      expect(
        restorableBootConfig(
          connection: const LastConnection(
            providerKind: 'webllm',
            modelId: 'preset-1',
          ),
          registry: null,
          sessionKeysStore: null,
        ),
        isNull,
      );
    });

    test('null when the hosted key is gone (setup shows prefilled)', () {
      expect(
        restorableBootConfig(
          connection: connection,
          registry: null,
          sessionKeysStore: SessionKeysStore.inMemory(),
        ),
        isNull,
      );
    });

    test('the hosted key resolves from the saved-keys store', () {
      final config = restorableBootConfig(
        connection: connection,
        registry: null,
        sessionKeysStore: SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-saved',
        }),
      );
      expect(config, isNotNull);
      expect(config!.apiKey, 'sk-saved');
      expect(config.modelId, 'k3-256k');
      expect(config.baseUrl, 'https://api.kimi.com/coding/v1');
      expect(config.providerKind, 'openai-completions');
    });

    test('a matching custom provider supplies its registry key', () async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Kimi',
        baseUrl: connection.baseUrl!,
        modelId: 'k3-256k',
      );
      registry.rememberKey(provider.id, 'sk-custom');
      final config = restorableBootConfig(
        connection: connection,
        registry: registry,
        sessionKeysStore: SessionKeysStore.inMemory({
          'OPENROUTER_API_KEY': 'sk-saved',
        }),
      );
      expect(config!.apiKey, 'sk-custom');
    });

    test('a keyless custom endpoint restores without a key', () async {
      const local = LastConnection(
        providerKind: 'openai-completions',
        modelId: 'llama-3.2',
        baseUrl: 'http://localhost:11434/v1',
      );
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Local',
        baseUrl: local.baseUrl!,
        modelId: 'llama-3.2',
      );
      final config = restorableBootConfig(
        connection: local,
        registry: registry,
        sessionKeysStore: null,
      );
      expect(config, isNotNull);
      expect(config!.apiKey, isEmpty);
    });
  });
}
