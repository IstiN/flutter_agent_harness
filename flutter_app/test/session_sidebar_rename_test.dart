// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/widgets/session_sidebar.dart';
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
  testWidgets('rename flow: dialog saves, then Clear restores the derived '
      'name', (tester) async {
    final env = MemoryExecutionEnv();
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions');
    manager.addSession('fake-session-1', _fakeService(env));
    final namesStore = SessionNamesStore.inMemory();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SessionSidebar(manager: manager, sessionNamesStore: namesStore),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The row starts with the derived name.
    expect(find.text('session fake-ses'), findsOneWidget);

    // The rename affordance opens a dialog with an empty (hint-only) field.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(find.text('Rename session'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '',
    );

    await tester.enterText(find.byType(TextField), 'My chat');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('My chat'), findsOneWidget);
    expect(find.text('session fake-ses'), findsNothing);
    expect(namesStore.titleFor('fake-session-1'), 'My chat');

    // Reopening prefills the custom title; Clear restores the derived name.
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'My chat',
    );
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();

    expect(find.text('session fake-ses'), findsOneWidget);
    expect(namesStore.titleFor('fake-session-1'), isNull);
  });
}
