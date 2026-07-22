import 'package:flutter/material.dart';
import 'package:fa/agent_service.dart';
import 'package:fa/app_theme.dart';
import 'package:fa/chat_screen.dart';
import 'package:fa/flutter_session_manager.dart';
import 'package:fa/main.dart';
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

AgentService _fakeService() {
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
      streamFunction: _singleTextResponse('hi'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

/// Decoration colors of all chat bubbles currently in the tree.
Set<Color?> _bubbleColors(WidgetTester tester) {
  return tester
      .widgetList<Container>(
        find.byWidgetPredicate(
          (widget) =>
              widget is Container &&
              widget.decoration is BoxDecoration &&
              ((widget.decoration! as BoxDecoration).color ==
                      FahPalette.userBubble ||
                  (widget.decoration! as BoxDecoration).color ==
                      FahPalette.panel),
        ),
      )
      .map((container) => (container.decoration! as BoxDecoration).color)
      .toSet();
}

void main() {
  testWidgets('app theme is dark and uses the landing palette', (tester) async {
    await tester.pumpWidget(const MyApp());

    final context = tester.element(find.byType(Scaffold));
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor, FahPalette.bg);
    expect(theme.colorScheme.primary, FahPalette.indigo);
    expect(theme.colorScheme.secondary, FahPalette.teal);
    expect(theme.colorScheme.surface, FahPalette.bgAlt);
    expect(theme.dividerColor, FahPalette.border);
  });

  testWidgets('chat bubbles use the dark landing palette', (tester) async {
    final service = _fakeService();
    await service.initialize();
    final manager = FlutterSessionManager(
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    )..addSession('fake-session', service);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFahTheme(),
        home: ChatScreen(manager: manager),
      ),
    );
    await tester.pumpAndSettle();

    // Inject a user/assistant exchange directly (an agent run would leave its
    // response-timeout Timer pending in fake async).
    service.messages
      ..add(FahChatMessage(role: 'user', content: 'hello'))
      ..add(FahChatMessage(role: 'assistant', content: 'hi'));
    service.notifyListeners();
    // Flush the 50 ms sync debounce and the list insert animations.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 600));

    // One bubble per side: the user's indigo tint and the assistant's panel.
    expect(
      _bubbleColors(tester),
      containsAll(<Color>[FahPalette.userBubble, FahPalette.panel]),
    );
  });
}
