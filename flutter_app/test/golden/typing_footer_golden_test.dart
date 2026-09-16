/// Golden (screenshot) tests for the in-list typing indicator footer
/// (issue #459, AC4): the streaming indicator rendered as the visually
/// LAST item of the scrollable transcript — right above the composer —
/// across transcript lengths (a bare session, a half-filled and a full
/// viewport of history) in light + dark.
///
/// Full [ChatScreen] frames (the composer-golden pattern); a hung stream
/// keeps the footer mounted, timed pumps keep the spinner phase
/// deterministic. Review every regenerated PNG by eye.
library;

import 'dart:async';

import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

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
      systemPrompt: 'You are Fa.',
      // Hung stream (the launcher-golden pattern): the run stays open
      // until aborted, keeping the typing footer mounted.
      streamFunction: _hungResponse(),
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
}

/// Never completes: the typing footer stays mounted for the snapshot.
StreamFunction _hungResponse() {
  fn(Model model, dynamic context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final partial = AssistantMessage(
      content: const [],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime(2026),
    );
    stream.push(StartEvent(partial: partial));
    cancelToken?.onCancel.then((_) {
      stream.push(ErrorEvent(reason: StopReason.aborted, error: partial));
      stream.end();
    });
    return stream; // stays open until aborted
  }

  return fn;
}

Future<void> _pumpFooterFrame(
  WidgetTester tester, {
  required int turns,
  required bool light,
}) async {
  final env = MemoryExecutionEnv();
  final service = _fakeService(env);
  // Seed the transcript: alternating user/assistant turns; assistant
  // replies grow with the turn index so the long variant visibly fills
  // the viewport.
  for (var i = 0; i < turns; i++) {
    service.messages.add(
      FahChatMessage(role: 'user', content: 'Question ${i + 1}?'),
    );
    service.messages.add(
      FahChatMessage(
        role: 'assistant',
        content: List.generate(
          (i % 3) + 1,
          (line) => 'Answer line ${line + 1} for turn ${i + 1}.',
        ).join('\n'),
      ),
    );
  }
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('fake-session', service);

  tester.view.physicalSize = goldenSizePhone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: light ? buildFahThemeLight() : buildFahTheme(),
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(manager: manager),
    ),
  );
  await tester.pumpAndSettle();

  // Start the hung run OUTSIDE the composer (the footer must appear with
  // zero user input), then pump deterministic timed frames — the spinner
  // never settles.
  await tester.runAsync(() async {
    unawaited(service.sendText('long task'));
    await Future<void>.delayed(const Duration(milliseconds: 100));
  });
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
  });

  for (final (light, suffix) in [(false, 'dark'), (true, 'light')]) {
    testWidgets('typing footer — empty transcript ($suffix)', (tester) async {
      await _pumpFooterFrame(tester, turns: 0, light: light);
      await expectGolden(tester, 'chat/typing_footer_empty_$suffix');
    });

    testWidgets('typing footer — short transcript ($suffix)', (tester) async {
      await _pumpFooterFrame(tester, turns: 1, light: light);
      await expectGolden(tester, 'chat/typing_footer_short_$suffix');
    });

    testWidgets('typing footer — full transcript ($suffix)', (tester) async {
      await _pumpFooterFrame(tester, turns: 12, light: light);
      await expectGolden(tester, 'chat/typing_footer_full_$suffix');
    });
  }
}
