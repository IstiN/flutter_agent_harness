import 'package:fa/agent_service.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/last_connection.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('LastConnectionStore persistence', () {
    test('missing file loads as empty', () async {
      final env = MemoryExecutionEnv();
      final store = await LastConnectionStore.load(env);
      expect(store.connection, isNull);
    });

    test('corrupt file loads as empty instead of crashing', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile('${env.cwd}/last_connection.json', 'not json {');
      final store = await LastConnectionStore.load(env);
      expect(store.connection, isNull);
    });

    test('wrong schema version loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/last_connection.json',
        '{"version": 99, "connection": {}}',
      );
      final store = await LastConnectionStore.load(env);
      expect(store.connection, isNull);
    });

    test('a malformed connection record loads as empty', () async {
      final env = MemoryExecutionEnv();
      await env.writeFile(
        '${env.cwd}/last_connection.json',
        '{"version": 1, "connection": "webllm"}',
      );
      final store = await LastConnectionStore.load(env);
      expect(store.connection, isNull);
    });

    test(
      'a hosted connection round-trips through the env filesystem',
      () async {
        final env = MemoryExecutionEnv();
        final store = await LastConnectionStore.load(env);
        await store.saveFromConfig(
          AgentConfig(
            providerKind: 'openai-completions',
            modelId: 'gpt-oss:120b',
            baseUrl: 'https://ollama.com/v1',
            apiKey: 'sk-secret',
          ),
        );

        final reloaded = await LastConnectionStore.load(env);
        final connection = reloaded.connection;
        expect(connection, isNotNull);
        expect(connection!.providerKind, 'openai-completions');
        expect(connection.modelId, 'gpt-oss:120b');
        expect(connection.baseUrl, 'https://ollama.com/v1');
        expect(connection.webllmPresetId, isNull);
        expect(connection.gemmaPresetId, isNull);
        expect(connection.transformersJsPresetId, isNull);
      },
    );

    test('on-device connections round-trip with their preset ids', () async {
      final env = MemoryExecutionEnv();
      final store = await LastConnectionStore.load(env);
      await store.saveFromConfig(
        AgentConfig(
          providerKind: webLlmProviderKind,
          modelId: 'SmolLM2-1.7B-Instruct-q4f16_1-MLC',
          baseUrl: '',
          apiKey: '',
          contextWindow: 2048,
          maxTokens: 1024,
        ),
      );
      await store.saveFromConfig(
        AgentConfig(
          providerKind: gemmaProviderKind,
          modelId: 'gemma-4-E4B-it',
          baseUrl: '',
          apiKey: '',
          contextWindow: 4096,
          maxTokens: 1024,
        ),
      );
      await store.saveFromConfig(
        AgentConfig(
          providerKind: transformersJsProviderKind,
          modelId: 'onnx-community/gemma-4-E2B-it-ONNX',
          baseUrl: '',
          apiKey: '',
          contextWindow: 4096,
          maxTokens: 1024,
        ),
      );

      // The last save wins.
      final reloaded = await LastConnectionStore.load(env);
      final connection = reloaded.connection!;
      expect(connection.providerKind, transformersJsProviderKind);
      expect(connection.modelId, 'onnx-community/gemma-4-E2B-it-ONNX');
      expect(
        connection.transformersJsPresetId,
        'onnx-community/gemma-4-E2B-it-ONNX',
      );
      expect(connection.baseUrl, isNull);
      expect(connection.webllmPresetId, isNull);

      // The earlier kinds map onto their own preset fields.
      expect(
        LastConnection.fromConfig(
          AgentConfig(
            providerKind: webLlmProviderKind,
            modelId: 'm',
            baseUrl: '',
            apiKey: '',
          ),
        ).webllmPresetId,
        'm',
      );
      expect(
        LastConnection.fromConfig(
          AgentConfig(
            providerKind: gemmaProviderKind,
            modelId: 'm',
            baseUrl: '',
            apiKey: '',
          ),
        ).gemmaPresetId,
        'm',
      );
    });

    test('the store file lives at the sandbox root', () async {
      final env = MemoryExecutionEnv();
      final store = await LastConnectionStore.load(env);
      await store.save(
        const LastConnection(providerKind: 'openai-completions', modelId: 'm'),
      );

      final text = (await env.readTextFile(
        '${env.cwd}/${LastConnectionStore.fileName}',
      )).valueOrNull;
      expect(text, isNotNull);
      expect(text, contains('"openai-completions"'));
    });

    test('API keys are never persisted', () async {
      final env = MemoryExecutionEnv();
      final store = await LastConnectionStore.load(env);
      await store.saveFromConfig(
        AgentConfig(
          providerKind: 'openai-completions',
          modelId: 'openai/gpt-4o-mini',
          baseUrl: 'https://openrouter.ai/api/v1',
          apiKey: 'sk-secret-key',
        ),
      );

      final raw = (await env.readTextFile(
        '${env.cwd}/${LastConnectionStore.fileName}',
      )).valueOrNull!;
      expect(raw, isNot(contains('sk-secret-key')));
      expect(raw, isNot(contains('apiKey')));
      // The record itself carries no key field either.
      expect(
        LastConnection.fromJson(store.connection!.toJson()).modelId,
        'openai/gpt-4o-mini',
      );
    });

    test('the in-memory store keeps the record but writes nothing', () async {
      final store = LastConnectionStore.inMemory();
      await store.save(
        const LastConnection(providerKind: webLlmProviderKind, modelId: 'm'),
      );
      expect(store.connection?.modelId, 'm');
    });
  });
}
