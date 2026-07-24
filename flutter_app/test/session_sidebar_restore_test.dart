// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/agent_service.dart';
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
  testWidgets('persisted sessions from previous runs are listed and openable', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    // A session left on disk by a "previous app run".
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final old = await repo.create(
      JsonlSessionCreateOptions(
        cwd: 'openai-completions',
        metadata: const {'agent': 'fa', 'model': 'old-model'},
      ),
    );
    final oldMetadata = await old.getMetadata();

    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('fake-session', _fakeService(env));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SessionSidebar(manager: manager)),
      ),
    );
    await tester.pumpAndSettle();

    // The disk session shows up under "On this device".
    expect(find.text('On this device'), findsOneWidget);
    final tile = find.text('session ${oldMetadata.id.substring(0, 8)}');
    expect(tile, findsOneWidget);

    // Tapping opens it in the manager.
    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(manager.sessions.map((s) => s.id), contains(oldMetadata.id));
    expect(manager.activeId, oldMetadata.id);
  });
}
