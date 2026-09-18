// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Provider connection guards (issue #327 Part 1): model and auth must
// resolve from the SAME registry row. A model id saved on entry X can no
// longer ride entry Y's connection (the CodeMie/OpenRouter 401 fingerprint),
// and a credential-bearing endpoint without a usable key on THIS surface
// fails loudly at selection/boot instead of keyless-requesting a
// cookie-auth gateway.
import 'package:fa/boot/boot_config_codec.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _openRouterUrl = 'https://openrouter.ai/api/v1';
const _codeMieUrl = 'https://acme.example.com/code-assistant-api/v1';
const _localUrl = 'http://localhost:11434/v1';

Future<ProviderRegistry> _registry() async {
  final registry = ProviderRegistry.inMemory();
  final openRouter = await registry.add(
    name: 'OpenRouter',
    baseUrl: _openRouterUrl,
    modelId: 'z-ai/glm-5.3-flash',
  );
  registry.rememberKey(openRouter.id, 'sk-or-test');
  await registry.add(
    name: 'CodeMie',
    baseUrl: _codeMieUrl,
    modelId: 'gpt-4o',
  );
  return registry;
}

StreamFunction _okResponse() {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    stream.push(
      DoneEvent(
        reason: StopReason.stop,
        message: AssistantMessage(
          content: [TextContent(text: 'ok')],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.stop,
          timestamp: DateTime.now(),
        ),
      ),
    );
    stream.end();
    return stream;
  };
}

AgentConfig _config(String baseUrl, String model, {String apiKey = 'k'}) =>
    AgentConfig(
      providerKind: 'openai-completions',
      modelId: model,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );

Future<AgentService> _service(ProviderRegistry registry) =>
    AgentService.create(
      config: _config(_codeMieUrl, 'gpt-4o'),
      env: MemoryExecutionEnv(cwd: '/'),
      providerRegistry: registry,
      streamFunction: _okResponse(),
    );

void main() {
  group('UT-mismatch: model/auth resolve from the same registry row', () {
    test('a model saved on entry X cannot ride entry Y (names both)', () async {
      final service = await _service(await _registry());
      addTearDown(service.dispose);
      await expectLater(
        service.reconfigure(_config(_codeMieUrl, 'z-ai/glm-5.3-flash')),
        throwsA(
          isA<ProviderConnectionException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains("Model z-ai/glm-5.3-flash belongs to provider"),
              contains("'OpenRouter'"),
              contains("active connection is CodeMie"),
            ),
          ),
        ),
      );
    });

    test('E1: a model two entries serve follows the ACTIVE entry', () async {
      final registry = await _registry();
      final mirror = await registry.add(
        name: 'Mirror',
        baseUrl: _localUrl,
        modelId: 'z-ai/glm-5.3-flash',
      );
      registry.rememberKey(mirror.id, 'sk-mirror');
      final service = await _service(registry);
      addTearDown(service.dispose);
      // The OpenRouter entry itself is the active connection: its own
      // model rides it, even though the mirror serves the same id.
      await service.reconfigure(_config(_openRouterUrl, 'z-ai/glm-5.3-flash'));
    });

    test('E1: an active third entry with a contested model names both', () async {
      final registry = await _registry();
      final mirror = await registry.add(
        name: 'Mirror',
        baseUrl: _localUrl,
        modelId: 'z-ai/glm-5.3-flash',
      );
      registry.rememberKey(mirror.id, 'sk-mirror');
      final service = await _service(registry);
      addTearDown(service.dispose);
      await expectLater(
        service.reconfigure(_config(_codeMieUrl, 'z-ai/glm-5.3-flash')),
        throwsA(
          isA<ProviderConnectionException>().having(
            (e) => e.message,
            'message',
            allOf(contains("'OpenRouter'"), contains("'Mirror'")),
          ),
        ),
      );
    });
  });

  group('UT-keyless: credential-bearing endpoints fail loudly', () {
    test('a hosted preset without a key on this surface names the row',
        () async {
      final registry = ProviderRegistry.inMemory();
      final openRouter = await registry.add(
        name: 'OpenRouter',
        baseUrl: _openRouterUrl,
        modelId: 'z-ai/glm-5.3-flash',
      );
      // The add-in partition reload: the key did not survive the hop.
      registry.rememberKey(openRouter.id, '');
      final service = await _service(registry);
      addTearDown(service.dispose);
      await expectLater(
        service.reconfigure(
          _config(_openRouterUrl, 'z-ai/glm-5.3-flash', apiKey: ''),
        ),
        throwsA(
          isA<ProviderConnectionException>().having(
            (e) => e.message,
            'message',
            contains('OpenRouter: no API key on this surface'),
          ),
        ),
      );
    });

    test('a CodeMie entry without its cookie names the sign-in hint',
        () async {
      final service = await _service(await _registry());
      addTearDown(service.dispose);
      await expectLater(
        service.reconfigure(_config(_codeMieUrl, 'gpt-4o', apiKey: '')),
        throwsA(
          isA<ProviderConnectionException>().having(
            (e) => e.message,
            'message',
            contains('CodeMie: no sign-in on this surface'),
          ),
        ),
      );
    });

    test('REG: keyless local endpoints still connect', () async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Local',
        baseUrl: _localUrl,
        modelId: 'llama-3.2',
      );
      final service = await _service(registry);
      addTearDown(service.dispose);
      await service.reconfigure(
        _config(_localUrl, 'llama-3.2', apiKey: ''),
      );
    });
  });

  group('boot restore never assembles a broken connection', () {
    test('keyless CodeMie entry: setup shows instead of a keyless boot',
        () async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'CodeMie',
        baseUrl: _codeMieUrl,
        modelId: 'gpt-4o',
      );
      expect(
        restorableBootConfig(
          connection: const LastConnection(
            providerKind: 'openai-completions',
            modelId: 'gpt-4o',
            baseUrl: _codeMieUrl,
          ),
          registry: registry,
          sessionKeysStore: SessionKeysStore.inMemory(),
        ),
        isNull,
      );
    });

    test('a model of entry X persisted onto entry Y restores degraded - '
        'the row-naming refusal moves to request time (review MAJOR 2)',
        () async {
      final registry = await _registry();
      final config = restorableBootConfig(
        connection: const LastConnection(
          providerKind: 'openai-completions',
          modelId: 'z-ai/glm-5.3-flash',
          baseUrl: _codeMieUrl,
        ),
        registry: registry,
        sessionKeysStore: SessionKeysStore.inMemory(),
      );
      // The mismatched connection must not brick the session (a stale
      // persisted row would otherwise erase the transcript): it boots,
      // and the first request is refused with the same row-naming
      // message.
      expect(config, isNotNull);
      expect(config!.modelId, 'z-ai/glm-5.3-flash');
    });

    test('REG: keyless local entries still restore', () async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Local',
        baseUrl: _localUrl,
        modelId: 'llama-3.2',
      );
      final config = restorableBootConfig(
        connection: const LastConnection(
          providerKind: 'openai-completions',
          modelId: 'llama-3.2',
          baseUrl: _localUrl,
        ),
        registry: registry,
        sessionKeysStore: null,
      );
      expect(config, isNotNull);
    });
  });

  group('auth failures surface the entry name', () {
    Future<List<AssistantMessageEvent>> collect(
      AssistantMessageEventStream stream,
    ) async {
      final events = <AssistantMessageEvent>[];
      await for (final event in stream) {
        events.add(event);
      }
      return events;
    }

    AssistantMessage errorMessageOf(String text) => AssistantMessage(
      content: const [],
      api: 'openai-completions',
      provider: 'openai-completions',
      model: 'z-ai/glm-5.3-flash',
      usage: Usage.zero,
      stopReason: StopReason.error,
      errorMessage: text,
      timestamp: DateTime.now(),
    );

    const model = Model(
      id: 'm',
      api: 'openai-completions',
      provider: 'openai-completions',
      baseUrl: 'https://acme.example.com/code-assistant-api/v1',
      contextWindow: 128000,
      maxTokens: 8192,
    );

    test('a 401 error event is prefixed with the entry name', () async {
      final inner = AssistantMessageEventStream();
      final labeled = decorateAuthErrors(
        (m, context, {cancelToken}) => inner,
        () => 'CodeMie',
      );
      final collected = collect(labeled(model, const Context(messages: [])));
      inner.push(
        ErrorEvent(
          reason: StopReason.error,
          error: errorMessageOf('401: No cookie auth credentials found'),
        ),
      );
      inner.end();
      final events = await collected;
      final error = events.whereType<ErrorEvent>().single;
      expect(error.error.errorMessage, startsWith('[CodeMie]'));
      expect(
        error.error.errorMessage,
        contains('401: No cookie auth credentials found'),
      );
    });

    test('a non-auth error passes through untouched', () async {
      final inner = AssistantMessageEventStream();
      final labeled = decorateAuthErrors(
        (m, context, {cancelToken}) => inner,
        () => 'CodeMie',
      );
      final collected = collect(labeled(model, const Context(messages: [])));
      inner.push(
        ErrorEvent(
          reason: StopReason.error,
          error: errorMessageOf('429: rate limited'),
        ),
      );
      inner.end();
      final events = await collected;
      expect(
        events.whereType<ErrorEvent>().single.error.errorMessage,
        '429: rate limited',
      );
    });

    test('a done event passes through untouched', () async {
      final inner = AssistantMessageEventStream();
      final labeled = decorateAuthErrors(
        (m, context, {cancelToken}) => inner,
        () => 'CodeMie',
      );
      final collected = collect(labeled(model, const Context(messages: [])));
      inner.push(
        DoneEvent(reason: StopReason.stop, message: errorMessageOf('ok')),
      );
      inner.end();
      final events = await collected;
      expect(events.whereType<DoneEvent>(), isNotEmpty);
      expect(events.whereType<ErrorEvent>(), isEmpty);
    });
  });
  group('review fixes: the guard breaks nothing it should not (issue #327)',
      () {
    test('MAJOR 1: extension-host CodeMie cookie sign-in keeps its empty '
        'key - plain web still refuses it', () async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'CodeMie',
        baseUrl: _codeMieUrl,
        modelId: 'gpt-4o',
      );
      final config = _config(_codeMieUrl, 'gpt-4o', apiKey: '');
      // The extension hosts the app web build; its cookie sign-in stores
      // an EMPTY key BY DESIGN (the SW fetch attaches the shared jar).
      expect(
        providerConnectionProblem(registry, config, extensionHost: true),
        isNull,
      );
      // A plain web/desktop surface has no cookie jar on the fetch -
      // keyless CodeMie still refuses.
      expect(
        providerConnectionProblem(registry, config, extensionHost: false),
        isNotNull,
      );
    });

    test('MAJOR 3: same-host rows are one provider - a path variant does '
        'not flag', () async {
      final registry = await _registry();
      // Two rows on the SAME host serving the same model: picking the
      // row on the same host is the endpoint's own business. (The id is
      // served by the mirror only - the CodeMie row serves gpt-4o.)
      await registry.add(
        name: 'OpenRouter mirror',
        baseUrl: 'https://openrouter.ai/api/v1/',
        modelId: 'gpt-4o-mini',
      );
      expect(
        providerConnectionProblem(
          registry,
          _config(_openRouterUrl, 'gpt-4o-mini'),
        ),
        isNull,
      );
    });

    test('MAJOR 3: the incident shape stays flagged (different host)',
        () async {
      final registry = await _registry();
      expect(
        providerConnectionProblem(
          registry,
          _config(_codeMieUrl, 'z-ai/glm-5.3-flash'),
        ),
        isNotNull,
      );
    });

    test('MAJOR 2: a boot-restored mismatched connection refuses the '
        'REQUEST, not the boot', () async {
      final registry = await _registry();
      // Simulates the degraded restore: the agent boots on the
      // mismatched pairing (CodeMie endpoint, OpenRouter's model).
      final service = await AgentService.create(
        config: _config(_codeMieUrl, 'z-ai/glm-5.3-flash'),
        env: MemoryExecutionEnv(cwd: '/'),
        providerRegistry: registry,
        streamFunction: _okResponse(),
      );
      addTearDown(service.dispose);
      await service.sendText('hi');
      expect(
        service.error,
        allOf(
          contains('z-ai/glm-5.3-flash'),
          contains('OpenRouter'),
          contains('CodeMie'),
        ),
      );
    });

    test('MINOR: the OpenRouter env key no longer launders onto other '
        'endpoints', () async {
      final keys = SessionKeysStore.inMemory();
      await keys.set('OPENROUTER_API_KEY', 'sk-or-env');
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Local',
        baseUrl: _localUrl,
        modelId: 'llama-3.2',
      );
      final config = restorableBootConfig(
        connection: LastConnection(
          providerKind: 'openai-completions',
          modelId: 'llama-3.2',
          baseUrl: _localUrl,
        ),
        registry: registry,
        sessionKeysStore: keys,
      );
      expect(config, isNotNull);
      expect(config!.apiKey, isEmpty);
    });
  });

  group('add-in send guards (issue #633 AC2)', () {
    test('an empty model id refuses the send by name — the provider is '
        'never called', () async {
      var calls = 0;
      counting(StreamFunction _) => (model, context, {cancelToken}) {
        calls++;
        return _okResponse()(model, context, cancelToken: cancelToken);
      };
      // The #633 live trajectory: a send went out with model: "".
      final service = await AgentService.create(
        config: _config(_openRouterUrl, ''),
        env: MemoryExecutionEnv(cwd: '/'),
        providerRegistry: await _registry(),
        streamFunction: counting(_okResponse()),
      );
      addTearDown(service.dispose);

      await service.sendText('что ты тут видишь?');

      expect(calls, 0, reason: 'no network traffic on an unresolved model');
      expect(service.error, contains('no model selected'));
    });

    test('a hosted preset without a key refuses the send at request time',
        () async {
      var calls = 0;
      final service = await AgentService.create(
        config: _config(_openRouterUrl, 'z-ai/glm-5.3-flash', apiKey: ''),
        env: MemoryExecutionEnv(cwd: '/'),
        providerRegistry: await _registry(),
        streamFunction: (model, context, {cancelToken}) {
          calls++;
          return _okResponse()(model, context, cancelToken: cancelToken);
        },
      );
      addTearDown(service.dispose);

      await service.sendText('hi');

      expect(calls, 0, reason: 'no network traffic without a credential');
      expect(service.error, contains('no API key on this surface'));
    });
  });
}
