/// Golden (snapshot) tests for the composer-adjacent live run status row
/// (issue #865): the phase/tool/elapsed line that keeps the chat from
/// looking dead while the agent works — provider wait («Thinking...») and
/// an in-flight tool call («Running bash»), light + dark.
///
/// Full [ChatScreen] frames over a REAL [AgentService] forced into the
/// streaming state (the setter's OS hooks are iOS-gated / try-caught, so
/// they no-op on the host); elapsed shows 0s — the capture never crosses a
/// ticker second. Review every regenerated PNG by eye.
library;

import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

AgentService _streamingService(ExecutionEnv env, List<FahChatMessage> rows) {
  final service = AgentService(
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
      streamFunction: (model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        stream.end();
        return stream;
      },
      toolRegistry: ToolRegistry(const []),
    ),
    watchExternalSessions: false,
    env: env,
    sessionsRoot: '/sessions',
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.com',
      apiKey: '',
    ),
  );
  service.messages.addAll(rows);
  service.isStreaming = true;
  return service;
}

Future<void> _pumpStatusFrame(
  WidgetTester tester, {
  required List<FahChatMessage> rows,
  required bool light,
}) async {
  final env = MemoryExecutionEnv();
  final service = _streamingService(env, rows);
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', service);
  await pumpGolden(
    tester,
    ChatScreen(manager: manager),
    size: goldenSizePhone,
    theme: light ? buildFahThemeLight() : buildFahTheme(),
    locale: const Locale('en'),
    wrap: (child) => child,
    // The row's spinner never settles; settle with single frames instead —
    // short of a ticker second, so the elapsed stays 0s (deterministic).
    settle: false,
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(ensureGoldenFonts);

  testWidgets('provider wait — thinking row above the composer (light)', (
    tester,
  ) async {
    await _pumpStatusFrame(
      tester,
      rows: [
        FahChatMessage(role: 'user', content: 'run the test suite for me'),
      ],
      light: true,
    );
    await expectGolden(tester, 'chat/run_status_thinking_light');
  });

  testWidgets('in-flight tool — running row above the composer (light)', (
    tester,
  ) async {
    await _pumpStatusFrame(
      tester,
      rows: [
        FahChatMessage(role: 'user', content: 'run the test suite for me'),
        FahChatMessage(
          role: 'system',
          content: '[bash] {"command": "flutter test"}',
        ),
      ],
      light: true,
    );
    await expectGolden(tester, 'chat/run_status_tool_light');
  });

  testWidgets('in-flight tool — running row above the composer (dark)', (
    tester,
  ) async {
    await _pumpStatusFrame(
      tester,
      rows: [
        FahChatMessage(role: 'user', content: 'run the test suite for me'),
        FahChatMessage(
          role: 'system',
          content: '[bash] {"command": "flutter test"}',
        ),
      ],
      light: false,
    );
    await expectGolden(tester, 'chat/run_status_tool_dark');
  });
}
