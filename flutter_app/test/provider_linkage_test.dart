// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

// Provider→live-model linkage (issue #2156 P1): the office add-in boots a
// placeholder session; a provider added to the registry afterwards (or its
// key, minted by a sign-in) must reach the LIVE chat — the chat model
// switches — instead of the first turn dying on a raw upstream 405. The
// fake registry lifecycle below replays the incident: add → (no key yet,
// placeholder stays) → sign-in remembers the key → the chat switches.
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

const _aiinUrl = 'https://api.aiin.by/v1';
const _openRouterUrl = 'https://openrouter.ai/api/v1';

/// The post-onboarding/office-taskpane boot config (main.dart's
/// `_EmptyManagerHome.placeholderConfig`): a model that cannot serve any
/// request.
AgentConfig _placeholder() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'placeholder',
  baseUrl: '',
  apiKey: '',
);

AgentConfig _connected() => AgentConfig(
  providerKind: 'openai-completions',
  modelId: 'z-ai/glm-5.2',
  baseUrl: _openRouterUrl,
  apiKey: 'sk-or-test',
);

Future<AgentService> _service(
  ProviderRegistry registry, {
  AgentConfig? config,
}) => AgentService.create(
  config: config ?? _placeholder(),
  env: MemoryExecutionEnv(cwd: '/'),
  providerRegistry: registry,
  streamFunction: _okResponse(),
);

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

void main() {
  group('UT-linkage: an added provider applies to the placeholder chat', () {
    test('boot: a keyed registry provider becomes the live model', () async {
      final registry = ProviderRegistry.inMemory();
      final aiin = await registry.add(
        name: 'AIIN',
        baseUrl: _aiinUrl,
        modelId: 'aiin_free_vision',
      );
      registry.rememberKey(aiin.id, 'sk-aiin-40');
      final service = await _service(registry);
      addTearDown(service.dispose);
      await pumpEventQueue();
      expect(service.modelId, 'aiin_free_vision');
      expect(service.activeBaseUrl, _aiinUrl);
      expect(service.providerKind, 'openai-completions');
    });

    test(
      'lifecycle: the provider added after boot switches the chat',
      () async {
        // The incident: boot on the placeholder, THEN add the provider and
        // mint its key (web sign-in) — the live chat must follow.
        final registry = ProviderRegistry.inMemory();
        final service = await _service(registry);
        addTearDown(service.dispose);
        await pumpEventQueue();
        expect(service.modelId, 'placeholder');
        expect(service.activeBaseUrl, '');

        final aiin = await registry.add(
          name: 'AIIN',
          baseUrl: _aiinUrl,
          modelId: 'aiin_free_vision',
        );
        await pumpEventQueue();
        // The definition alone (no key on this surface yet — the pre-sign-in
        // state) must not switch the chat.
        expect(service.modelId, 'placeholder');

        registry.rememberKey(aiin.id, 'sk-aiin-40');
        await pumpEventQueue();
        expect(service.modelId, 'aiin_free_vision');
        expect(service.activeBaseUrl, _aiinUrl);
      },
    );

    test('several usable providers stay a picker decision', () async {
      final registry = ProviderRegistry.inMemory();
      final aiin = await registry.add(
        name: 'AIIN',
        baseUrl: _aiinUrl,
        modelId: 'aiin_free_vision',
      );
      registry.rememberKey(aiin.id, 'sk-aiin-40');
      final openRouter = await registry.add(
        name: 'OpenRouter',
        baseUrl: _openRouterUrl,
        modelId: 'z-ai/glm-5.2',
      );
      registry.rememberKey(openRouter.id, 'sk-or-test');
      final service = await _service(registry);
      addTearDown(service.dispose);
      await pumpEventQueue();
      expect(service.modelId, 'placeholder');
    });

    test(
      'a chosen connection is never hijacked by a registry change',
      () async {
        final registry = ProviderRegistry.inMemory();
        final aiin = await registry.add(
          name: 'AIIN',
          baseUrl: _aiinUrl,
          modelId: 'aiin_free_vision',
        );
        registry.rememberKey(aiin.id, 'sk-aiin-40');
        final service = await _service(registry, config: _connected());
        addTearDown(service.dispose);
        await pumpEventQueue();
        expect(service.modelId, 'z-ai/glm-5.2');
        expect(service.activeBaseUrl, _openRouterUrl);
      },
    );

    test('the add-flow latch defers the switch until the flow ends', () async {
      final registry = ProviderRegistry.inMemory();
      final service = await _service(registry);
      addTearDown(service.dispose);
      await pumpEventQueue();
      service.beginProviderAddFlow();
      final aiin = await registry.add(
        name: 'AIIN',
        baseUrl: _aiinUrl,
        modelId: 'aiin_free_vision',
      );
      registry.rememberKey(aiin.id, 'sk-aiin-40');
      await pumpEventQueue();
      // Mid-flow (gh-1044 F4): the flow's own fromProviderAddFlow
      // reconfigure owns the connection — the linkage must not race it.
      expect(service.modelId, 'placeholder');

      service.endProviderAddFlow();
      // The next registry notify picks the change up.
      registry.rememberKey(aiin.id, 'sk-aiin-40');
      await pumpEventQueue();
      expect(service.modelId, 'aiin_free_vision');
    });

    test('a persisted entry kind dispatches its own wire', () async {
      final registry = ProviderRegistry.inMemory();
      final codex = await registry.add(
        name: 'ChatGPT',
        baseUrl: 'https://chatgpt.com/backend-api/codex',
        modelId: 'gpt-5-codex',
        kind: 'chatgpt-codex',
      );
      registry.rememberKey(codex.id, 'tok');
      final service = await _service(registry);
      addTearDown(service.dispose);
      await pumpEventQueue();
      expect(service.providerKind, 'chatgpt-codex');
      expect(service.modelId, 'gpt-5-codex');
    });

    test(
      'a streaming turn is never interrupted — the next notify applies',
      () async {
        final registry = ProviderRegistry.inMemory();
        final service = await _service(registry);
        addTearDown(service.dispose);
        await pumpEventQueue();
        final aiin = await registry.add(
          name: 'AIIN',
          baseUrl: _aiinUrl,
          modelId: 'aiin_free_vision',
        );
        // The streaming bracket (issue #325 setter): a key arriving mid-turn
        // must not swap the backend under a live run.
        service.isStreaming = true;
        registry.rememberKey(aiin.id, 'sk-aiin-40');
        await pumpEventQueue();
        expect(service.modelId, 'placeholder');

        service.isStreaming = false;
        registry.rememberKey(aiin.id, 'sk-aiin-40');
        await pumpEventQueue();
        expect(service.modelId, 'aiin_free_vision');
      },
    );

    test('a refused linkage is caught and the linkage recovers', () async {
      final registry = ProviderRegistry.inMemory();
      final service = await _service(registry);
      addTearDown(service.dispose);
      await pumpEventQueue();
      // An entry whose persisted kind dispatches to an unknown wire: the
      // reconfigure throws — the catch must swallow it (a notify callback
      // crash would kill the registry dispatch) and the busy flag must
      // clear so a later valid provider still applies.
      final broken = await registry.add(
        name: 'Broken',
        baseUrl: 'https://broken.example.com/v1',
        modelId: 'broken-model',
        kind: 'frobnicator',
      );
      registry.rememberKey(broken.id, 'sk-broken');
      await pumpEventQueue();

      // The refusal must not wedge the linkage: clear the broken row, and
      // the next usable provider applies.
      await registry.remove(broken.id);
      final aiin = await registry.add(
        name: 'AIIN',
        baseUrl: _aiinUrl,
        modelId: 'aiin_free_vision',
      );
      registry.rememberKey(aiin.id, 'sk-aiin-40');
      await pumpEventQueue();
      expect(service.modelId, 'aiin_free_vision');
      expect(service.activeBaseUrl, _aiinUrl);
    });
  });
}
