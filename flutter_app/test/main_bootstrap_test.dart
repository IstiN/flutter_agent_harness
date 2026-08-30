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

    test('a google (Gemini) connection restores with GOOGLE_API_KEY', () {
      final config = restorableBootConfig(
        connection: const LastConnection(
          providerKind: 'google',
          modelId: 'gemini-3-flash',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        ),
        registry: null,
        sessionKeysStore: SessionKeysStore.inMemory({
          'GOOGLE_API_KEY': 'g-key',
        }),
      );
      expect(config, isNotNull);
      expect(config!.providerKind, 'google');
      expect(config.apiKey, 'g-key');
      expect(config.modelId, 'gemini-3-flash');
    });

    test(
      'a google connection restores through the custom provider key',
      () async {
        const conn = LastConnection(
          providerKind: 'google',
          modelId: 'gemini-3-flash',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
        );
        final registry = ProviderRegistry.inMemory();
        final provider = await registry.add(
          name: 'Gemini',
          baseUrl: conn.baseUrl!,
          modelId: 'gemini-3-flash',
        );
        registry.rememberKey(provider.id, 'g-custom');
        final config = restorableBootConfig(
          connection: conn,
          registry: registry,
          sessionKeysStore: SessionKeysStore.inMemory(),
        );
        expect(config, isNotNull);
        expect(config!.apiKey, 'g-custom');
      },
    );

    test('a copilot connection restores through its registry key', () async {
      const conn = LastConnection(
        providerKind: 'copilot',
        modelId: 'gpt-4.1',
        baseUrl: 'https://api.githubcopilot.com',
      );
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'copilot-octocat',
        baseUrl: conn.baseUrl!,
        modelId: 'gpt-4.1',
      );
      registry.rememberKey(provider.id, 'gho_custom');
      final config = restorableBootConfig(
        connection: conn,
        registry: registry,
        sessionKeysStore: SessionKeysStore.inMemory(),
      );
      expect(config, isNotNull);
      expect(config!.providerKind, 'copilot');
      expect(config.apiKey, 'gho_custom');
    });

    test('a copilot connection restores through the entry-scoped '
        'FA_KEY_COPILOT name', () async {
      const conn = LastConnection(
        providerKind: 'copilot',
        modelId: 'gpt-4.1',
        baseUrl: 'https://api.githubcopilot.com',
      );
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'copilot-octocat',
        baseUrl: conn.baseUrl!,
        modelId: 'gpt-4.1',
      );
      final config = restorableBootConfig(
        connection: conn,
        registry: registry,
        sessionKeysStore: SessionKeysStore.inMemory({
          'FA_KEY_COPILOT_COPILOT_OCTOCAT': 'gho_scoped',
        }),
      );
      expect(config, isNotNull);
      expect(config!.apiKey, 'gho_scoped');
    });

    test('null for a google connection whose key is gone', () {
      expect(
        restorableBootConfig(
          connection: const LastConnection(
            providerKind: 'google',
            modelId: 'gemini-3-flash',
            baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          ),
          registry: null,
          sessionKeysStore: SessionKeysStore.inMemory(),
        ),
        isNull,
      );
    });
  });
}
