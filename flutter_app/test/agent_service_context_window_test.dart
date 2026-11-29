// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2479 — the service-side context-window chain:
/// - the per-model override wins over the config-carried window, the
///   owner cap replaces the number LAST (#729);
/// - the provenance getter names the winning layer (override / endpoint /
///   spec / unknown default) through the SDK resolver;
/// - `applyContextWindowCap` re-caps live (compaction field + the agent's
///   late-wirable knob);
/// - `applyModelWindowOverride` reinstalls the layer and rebuilds the
///   ACTIVE model — clearing the pin restores the chain value.
library;

import 'dart:io' as io;

import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/io.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

Agent _agentModel(Model model) => Agent(
  model: model,
  systemPrompt: 'You are Fa.',
  streamFunction: _singleTextResponse('ok'),
  toolRegistry: ToolRegistry(const []),
);

AgentService _service({
  required Agent agent,
  ModelCapabilityOverrides? overrides,
  int? cap,
  required io.Directory tmp,
}) {
  return AgentService(
    agent: agent,
    env: LocalExecutionEnv(cwd: tmp.path),
    sessionsRoot: tmp.path,
    watchExternalSessions: false,
    includeSharedSessionRoots: false,
    capabilityOverrides: overrides,
    contextWindowCap: cap,
  );
}

AgentConfig _config({int contextWindow = 1048576, String modelId = 'big'}) =>
    AgentConfig(
      providerKind: 'aiin',
      modelId: modelId,
      baseUrl: 'https://aiin.example/v1',
      apiKey: '',
      contextWindow: contextWindow,
      maxTokens: 16384,
    );

void main() {
  late io.Directory tmp;

  setUp(() async {
    tmp = await io.Directory.systemTemp.createTemp('fa_ctx2479svc_');
    // The override layer is PROCESS-wide (the resolver reads it on every
    // model build) — tests must not leak pins into each other.
    modelCapabilityOverrides = null;
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('window chain resolution', () {
    test(
      'no pin: the config-carried window rides, provenance names it',
      () async {
        final service = _service(
          agent: _agentModel(
            const Model(
              id: 'big',
              api: 'openai-completions',
              provider: 'aiin',
              baseUrl: 'https://aiin.example/v1',
              contextWindow: 200000,
              maxTokens: 16384,
            ),
          ),
          tmp: tmp,
        );
        await service.reconfigure(_config(contextWindow: 1048576));
        final provenance = service.modelContextWindow;
        expect(provenance, isNotNull);
        expect(provenance!.window, 1048576);
        expect(provenance.source, CapabilityWindowLayer.endpoint);
        expect(provenance.uncapped, 1048576);
        expect(provenance.cap, isNull);
      },
    );

    test(
      'the pin wins over the endpoint report (aiin 1M → 200k override)',
      () async {
        final service = _service(
          agent: _agentModel(
            const Model(
              id: 'big',
              api: 'openai-completions',
              provider: 'aiin',
              baseUrl: 'https://aiin.example/v1',
              contextWindow: 200000,
              maxTokens: 16384,
            ),
          ),
          overrides: ModelCapabilityOverrides()
            ..set(
              'aiin',
              'big',
              const ModelCapabilityOverride(contextWindow: 200000),
            ),
          tmp: tmp,
        );
        await service.reconfigure(_config(contextWindow: 1048576));
        expect(service.agentModel.contextWindow, 200000);
        final provenance = service.modelContextWindow!;
        expect(provenance.window, 200000);
        expect(provenance.source, CapabilityWindowLayer.override);
      },
    );

    test('the cap applies AFTER the chain', () async {
      final service = _service(
        agent: _agentModel(
          const Model(
            id: 'big',
            api: 'openai-completions',
            provider: 'aiin',
            baseUrl: 'https://aiin.example/v1',
            contextWindow: 200000,
            maxTokens: 16384,
          ),
        ),
        cap: 131072,
        tmp: tmp,
      );
      await service.reconfigure(_config(contextWindow: 1048576));
      final provenance = service.modelContextWindow!;
      expect(provenance.window, 131072, reason: 'the cap replaced the number');
      expect(provenance.source, CapabilityWindowLayer.endpoint);
      expect(provenance.uncapped, 1048576);
      expect(provenance.cap, 131072);
    });

    test(
      'pin + cap together: the pin wins the chain, the cap wins last',
      () async {
        final service = _service(
          agent: _agentModel(
            const Model(
              id: 'big',
              api: 'openai-completions',
              provider: 'aiin',
              baseUrl: 'https://aiin.example/v1',
              contextWindow: 200000,
              maxTokens: 16384,
            ),
          ),
          overrides: ModelCapabilityOverrides()
            ..set(
              'aiin',
              'big',
              const ModelCapabilityOverride(contextWindow: 200000),
            ),
          cap: 65536,
          tmp: tmp,
        );
        await service.reconfigure(_config(contextWindow: 1048576));
        expect(service.agentModel.contextWindow, 65536);
        expect(
          service.modelContextWindow!.source,
          CapabilityWindowLayer.override,
        );
      },
    );
  });

  group('live apply seams', () {
    test(
      'applyContextWindowCap re-caps live (agent knob + provenance)',
      () async {
        final service = _service(
          agent: _agentModel(
            const Model(
              id: 'big',
              api: 'openai-completions',
              provider: 'aiin',
              baseUrl: 'https://aiin.example/v1',
              contextWindow: 200000,
              maxTokens: 16384,
            ),
          ),
          tmp: tmp,
        );
        await service.reconfigure(_config(contextWindow: 1048576));
        service.applyContextWindowCap(262144);
        expect(service.modelContextWindow!.window, 262144);
        expect(service.modelContextWindow!.cap, 262144);
        // The model KEEPS its carried window (like the CLI) — the cap
        // replaces the number in the loop config and the compaction wiring,
        // which the provenance getter reports.
        expect(service.agentModel.contextWindow, 1048576);
        service.applyContextWindowCap(null);
        expect(service.modelContextWindow!.window, 1048576);
        expect(service.modelContextWindow!.cap, isNull);
      },
    );

    test('applyModelWindowOverride rebuilds the active model; clearing '
        'restores the chain value', () async {
      final service = _service(
        agent: _agentModel(
          const Model(
            id: 'big',
            api: 'openai-completions',
            provider: 'aiin',
            baseUrl: 'https://aiin.example/v1',
            contextWindow: 200000,
            maxTokens: 16384,
          ),
        ),
        tmp: tmp,
      );
      await service.reconfigure(_config(contextWindow: 1048576));
      // Simulate the persisted write + reinstall: inject the layer and
      // apply — the active model follows the pin.
      final pinned = ModelCapabilityOverrides()
        ..set(
          'aiin',
          'big',
          const ModelCapabilityOverride(contextWindow: 200000),
        );
      service.applyModelWindowOverride('aiin', 'big', layer: pinned);
      expect(service.agentModel.contextWindow, 200000);
      expect(
        service.modelContextWindow!.source,
        CapabilityWindowLayer.override,
      );

      // Clearing the pin (the persisted write removed it — the fresh
      // layer is empty) restores the chain value.
      service.applyModelWindowOverride(
        'aiin',
        'big',
        layer: ModelCapabilityOverrides(),
      );
      expect(service.agentModel.contextWindow, 1048576);
      expect(
        service.modelContextWindow!.source,
        CapabilityWindowLayer.endpoint,
      );
    });

    test('applyModelWindowOverride leaves OTHER models untouched', () async {
      final service = _service(
        agent: _agentModel(
          const Model(
            id: 'big',
            api: 'openai-completions',
            provider: 'aiin',
            baseUrl: 'https://aiin.example/v1',
            contextWindow: 200000,
            maxTokens: 16384,
          ),
        ),
        tmp: tmp,
      );
      await service.reconfigure(_config(contextWindow: 1048576));
      final before = service.agentModel;
      service.applyModelWindowOverride('kimi', 'kimi/m1');
      expect(service.agentModel.contextWindow, before.contextWindow);
    });
  });
}
