@TestOn('vm')
/// Regression for the Duo session-rename red screen (issue #2062 field
/// feedback): the session-info dialog's TextEditingController must
/// outlive the pop route's exit animation — disposing it when the
/// dialog future completed raced the still-mounted TextField and
/// tripped framework.dart:6281 '_dependents.isEmpty'.
library;

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/main.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/session_names_store.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:fa_ui/fa_ui.dart'
    show FaVisualDirection, buildFaTheme, debugFaGlassAlwaysFake;
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

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

AgentService _listedService(ExecutionEnv env) {
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
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  )..messages.add(FahChatMessage(role: 'user', content: 'Listed conversation'));
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('en');
    await initializeDateFormatting('ru');
  });
  setUp(() => debugFaGlassAlwaysFake = true);
  tearDown(() => debugFaGlassAlwaysFake = false);

  testWidgets('Duo session rename keeps inherited dependents alive', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final service = _listedService(env);
    await service.initialize();
    final sessionId = service.currentSessionId!;
    final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession(sessionId, service);
    final names = SessionNamesStore.inMemory({sessionId: 'hello'});
    tester.view.padding = const FakeViewPadding(right: 84);
    debugFaGlassAlwaysFake = false;
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = const Size(1230, 880);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: buildFaTheme(
          direction: FaVisualDirection.glass,
          brightness: Brightness.light,
        ),
        home: Builder(
          builder: (context) => faHomeScreen(
            context: context,
            manager: manager,
            sessionNamesStore: names,
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('faChatHeaderTitlePill')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'hello do',
    );
    await tester.tap(find.text('Save'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(names.titleFor(sessionId), 'hello do');
    expect(
      tester.widget<ChatScreen>(find.byType(ChatScreen)).sessionTitle,
      'hello do',
    );
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
