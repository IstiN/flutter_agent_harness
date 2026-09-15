// Copyright (c) 2026, the Flutter agent harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #379 AC5 `E2E-mobile`: the full scenario on the app's REAL
/// construction path at phone size — widget presented mid-turn, text
/// follows, the widget stays visible (the follow clamp), the bottom chip
/// opens it ephemerally through the host hook, back returns, the x
/// dismiss leaves a stable state. E3 re-arm semantics are covered by the
/// fa_ui unit suite.
///
/// Same harness as `dynamic_message_live_tile_test.dart` (issue #336):
/// `AgentService.create` + scripted turns on the real event loop; without
/// the quickjs test bridge the tile shows the boot/error state, which is
/// still a mounted widget surface for the clamp and the chip.
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

Future<AgentService> _bootRealPath(WidgetTester tester) async {
  final env = MemoryExecutionEnv(cwd: '/');
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
          arguments: {'title': 'Демо', 'jsSource': _widgetJs},
        ),
      ]),
      (model) => textTurn(model, 'Готово.'),
    ]),
    sessionsRoot: '/sessions',
    watchExternalSessions: false,
  );
  final manager = FlutterSessionManager(env: env, sessionsRoot: '/sessions')
    ..addSession('s1', service);
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
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

/// Streams the next scripted turn on the real event loop (the agent loop
/// runs on real timers - the fake-test clock never advances it).
Future<void> _runTurn(WidgetTester tester, AgentService service) async {
  await service.sendText('go');
  for (var i = 0; i < 40 && service.isStreaming; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await tester.pump();
  }
  await service.waitForIdle();
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }
}

void main() {
  testWidgets('E2E-mobile: widget stays visible mid-turn, chip opens it '
      'ephemerally, back and dismiss are stable (issue #379)', (tester) async {
    AgentService? service;
    addTearDown(() => service?.dispose());

    await tester.runAsync(() async {
      service = await _bootRealPath(tester);
      await _runTurn(tester, service!);
    });
    await tester.pumpAndSettle();

    final chip = find.byKey(const Key('fa-widget-open-chip'));
    // The widget marker mounted in the transcript and the chip is up.
    expect(find.byType(DynamicWidgetTile, skipOffstage: false), findsOneWidget);
    expect(chip, findsOneWidget);

    // AC1: after the full turn (widget -> text) the widget's leading
    // edge is still inside the viewport - the follow clamped instead of
    // pinning the tail past it.
    final tileRect = tester.getRect(
      find.byType(DynamicWidgetTile, skipOffstage: false),
    );
    expect(tileRect.top, greaterThanOrEqualTo(0));
    expect(tileRect.top, lessThan(844));

    // AC3: the chip tap opens the ephemeral full-screen view (host
    // hook) ...
    await tester.tap(chip, warnIfMissed: false);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsOneWidget);
    // ... and back returns to a stable state: ephemeral gone, the chip
    // still offered (not dismissed by the open).
    await tester.tap(
      find.descendant(
        of: find.byKey(const ValueKey('ephemeral-dynamic-app')),
        matching: find.byType(BackButton),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsNothing);
    expect(chip, findsOneWidget);

    // The x button dismisses for this message; the dismissed state is
    // stable: the widget stays mounted, the chip stays gone. (E3
    // re-arm is covered by the fa_ui unit suite.)
    await tester.tap(find.byKey(const Key('fa-widget-open-chip-dismiss')));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(DynamicWidgetTile, skipOffstage: false), findsOneWidget);
    expect(chip, findsNothing);
  });
}
