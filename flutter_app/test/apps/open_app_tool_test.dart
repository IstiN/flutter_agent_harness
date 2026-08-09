// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/apps/open_app_tool.dart';
import 'package:fa/services/agent_service.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

AgentService _fakeService(ExecutionEnv env, {bool withConfig = false}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: withConfig
        ? AgentConfig(
            providerKind: 'test',
            modelId: 'test-model',
            baseUrl: 'https://example.com',
            apiKey: '',
          )
        : null,
  );
}

Future<void> _seedDemoApp(ExecutionEnv env) async {
  await env.writeFile(
    'apps/demo/manifest.json',
    '{"id":"demo","name":"Demo App"}',
  );
  await env.writeFile(
    'apps/demo/widget.js',
    '(function(){jsr.render({type:"text",data:"hi"});})();',
  );
}

AgentTool _openAppToolOf(AgentService service) => service.toolsForTest
    .where((tool) => tool.name == openAppToolName)
    .cast<AgentTool>()
    .first;

void main() {
  group('openAppTool', () {
    test(
      'success invokes the launcher and returns "Opened app" text',
      () async {
        final env = MemoryExecutionEnv();
        await _seedDemoApp(env);
        final launched = <String>[];
        final tool = openAppTool(env, launcher: (app) => launched.add(app.id));

        final result = await tool.execute({'id': 'demo'}, null, null);

        expect(launched, ['demo']);
        expect(
          result.content.whereType<TextContent>().map((b) => b.text).join(),
          "Opened app 'Demo App'",
        );
      },
    );

    test('unknown id fails with the list of available ids', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      var launcherCalled = false;
      final tool = openAppTool(env, launcher: (_) => launcherCalled = true);

      await expectLater(
        tool.execute({'id': 'nope'}, null, null),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('unknown app "nope"'), contains('demo')),
          ),
        ),
      );
      expect(launcherCalled, isFalse);
    });

    test('empty id fails cleanly', () async {
      final env = MemoryExecutionEnv();
      final tool = openAppTool(env, launcher: (_) {});
      await expectLater(
        tool.execute(const {'id': ' '}, null, null),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('AgentService.appLauncher', () {
    test('tool is absent by default, registered when the launcher is set, '
        'gone when cleared (pre-constructed agent path)', () {
      final service = _fakeService(MemoryExecutionEnv());
      expect(
        service.toolsForTest.any((t) => t.name == openAppToolName),
        isFalse,
      );

      service.appLauncher = (_) {};
      expect(
        service.toolsForTest.any((t) => t.name == openAppToolName),
        isTrue,
      );

      service.appLauncher = null;
      expect(
        service.toolsForTest.any((t) => t.name == openAppToolName),
        isFalse,
      );
    });

    test('setting the launcher twice does not duplicate the tool', () {
      final service = _fakeService(MemoryExecutionEnv());
      service.appLauncher = (_) {};
      service.appLauncher = (_) {};
      expect(
        service.toolsForTest.where((t) => t.name == openAppToolName),
        hasLength(1),
      );
    });

    test(
      'registered on a cloned service (registry path) and cleared again',
      () {
        final service = _fakeService(
          MemoryExecutionEnv(),
          withConfig: true,
        ).clone();
        expect(
          service.toolsForTest.any((t) => t.name == openAppToolName),
          isFalse,
        );

        service.appLauncher = (_) {};
        expect(
          service.toolsForTest.where((t) => t.name == openAppToolName),
          hasLength(1),
        );

        service.appLauncher = null;
        expect(
          service.toolsForTest.any((t) => t.name == openAppToolName),
          isFalse,
        );
      },
    );

    test('the registered tool executes against the service env', () async {
      final env = MemoryExecutionEnv();
      await _seedDemoApp(env);
      final service = _fakeService(env);
      final launched = <String>[];
      service.appLauncher = (app) => launched.add(app.id);

      final result = await _openAppToolOf(
        service,
      ).execute({'id': 'demo'}, null, null);

      expect(launched, ['demo']);
      expect(
        result.content.whereType<TextContent>().map((b) => b.text).join(),
        "Opened app 'Demo App'",
      );
    });
  });
}
