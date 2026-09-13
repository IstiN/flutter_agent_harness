// Copyright (c) 2026, the Flutter agent harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration coverage for issue #336: a `dynamic_message` tool call in a
/// LIVE turn must mount the interactive `DynamicWidgetTile` in the chat
/// transcript — on the app's REAL construction path (`AgentService.create`
/// → `_withEnv`, the registry the iOS/Android/desktop app boots with) with
/// the pumped [ChatScreen], never degrading to the plain tool-result card.
///
/// The engine itself is not the subject here: without the quickjs test
/// bridge the tile shows the boot/error state, which still proves the
/// MOUNT (the #336 regression was the tile never mounting at all).
library;

import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/chat_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'integration_fakes.dart';

const _widgetJs = 'jsr.render({type:"text",data:"hello"});';

Future<AgentService> _bootRealPath(
  WidgetTester tester,
  MemoryExecutionEnv env, {
  required String jsSource,
}) async {
  final service = await AgentService.create(
    config: AgentConfig(
      providerKind: 'test',
      modelId: 'test-model',
      baseUrl: 'https://example.test',
      apiKey: 'k',
    ),
    env: env,
    streamFunction: scriptedTurns([
      (model) => toolCallTurn(model, [
        ToolCall(
          id: 'dm-call-1',
          name: 'dynamic_message',
          arguments: {'title': 'Демо', 'jsSource': jsSource},
        ),
      ]),
      (model) => textTurn(model, 'Готово.'),
    ]),
    sessionsRoot: '/sessions',
    watchExternalSessions: false,
  );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('s1', service);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(manager: manager),
    ),
  );
  return service;
}

void main() {
  testWidgets(
    'live turn: dynamic_message call mounts the interactive tile in the '
    'transcript (issue #336 AC1)',
    (tester) async {
      final env = MemoryExecutionEnv(cwd: '/');
      AgentService? service;
      addTearDown(() => service?.dispose());

      // The whole boot + live turn rides the real event loop (the agent
      // loop streams on real timers — the fake-test clock never advances
      // it), mirroring chat_generated_images_test.dart.
      await tester.runAsync(() async {
        service = await _bootRealPath(tester, env, jsSource: _widgetJs);
        await service!.sendText('сделай динамическое сообщение');
        for (var i = 0; i < 40 && service!.isStreaming; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
        await service!.waitForIdle();
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pump();
        }
      });
      await tester.pumpAndSettle();
      // The splice queued exactly one widget marker for the tool call...
      expect(service!.messages.where((m) => m.role == 'widget'), hasLength(1));
      // ...the interactive tile mounted in the transcript (AC1)...
      expect(find.byType(DynamicWidgetTile), findsOneWidget);
      // ...and the emitting tool card stays (audit trail, AC E3).
      expect(find.textContaining('presented to the user'), findsOneWidget);
    },
  );
}
