// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/agent_service.dart';
import 'package:fa/apps/js_app_view.dart';
import 'package:fa/flutter_session_manager.dart';
import 'package:fa/session_sidebar.dart';
import 'package:flutter/material.dart';
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

AgentService _fakeService(ExecutionEnv env) {
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
      systemPrompt: 'You are fah.',
      streamFunction: _singleTextResponse('ok'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
}

void main() {
  testWidgets('first app message creates + binds a session, next reuses it', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    final original = _fakeService(env);
    manager.addSession('original-session', original);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSidebar(manager: manager)),
      ),
    );
    await tester.pumpAndSettle();

    final state = tester.state<SessionSidebarState>(
      find.byType(SessionSidebar),
    );
    const message = FaAppMessage(text: 'make it purple', appId: 'notes');

    await state.sendAppMessageToAgent(message);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();

    // A binding file appeared and a NEW session became active.
    final binding = await env.readTextFile('apps/notes/session.json');
    expect(binding.valueOrNull, isNotNull);
    final boundId = manager.activeId;
    expect(boundId, isNot('original-session'));
    expect(binding.valueOrNull, contains(boundId));

    // Second message goes to the SAME bound session, not a new one.
    final sessionCount = manager.sessions.length;
    await state.sendAppMessageToAgent(message);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    expect(manager.sessions.length, sessionCount);
    expect(manager.activeId, boundId);

    // Shut down services so their idle watchdogs don't outlive the test.
    for (final session in manager.sessions) {
      session.service.dispose();
    }
  });
}
