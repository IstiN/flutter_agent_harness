// Copyright (c) 2026, the Flutter agent harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Integration E2E for issue #378 AC5 (headless driver, phone size): a
/// dynamic message arrives through a REAL `dynamic_message` tool call on
/// the app's REAL construction path ([AgentService.create] + pumped
/// [ChatScreen]) → the user opens the tile's ⋮ menu → "Open as app
/// (without saving)" → the ephemeral full-screen view renders the widget →
/// back → the transcript is unchanged and `apps/` never gained an entry.
///
/// The quickjs bridge is unavailable in the headless host (see
/// dynamic_message_live_tile_test.dart), so the live engine is replaced by
/// an engine shell whose tree is pre-seeded through the service's test
/// seam — the MOUNT + navigation + no-persistence contract is the subject,
/// not the JS runtime.
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/apps/dynamic_messages.dart';
import 'package:fa/apps/dynamic_widget_tile.dart';
import 'package:fa/apps/js_app_engine.dart';
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

Future<DynamicMessagesService> _bootAndReceiveWidget(
  WidgetTester tester,
  MemoryExecutionEnv env,
) async {
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
  tester.view.physicalSize = const Size(1170, 2532);
  tester.view.devicePixelRatio = 3.0; // 390x844 logical, phone width.
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: ChatScreen(manager: manager),
    ),
  );
  // The whole turn rides the real event loop. NO pumps during streaming:
  // a mid-turn frame would mount the tile, the bridge-less host would
  // boot (and fail), and Open would degrade to disabled. The renderable
  // engine shell is seeded BEFORE the tile's first build instead - the
  // canvas sees a running engine and never schedules a real boot.
  await service.sendText('сделай динамическое сообщение');
  while (service.isStreaming) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  await service.waitForIdle();
  final dm = service.dynamicMessages;
  final definition = dm.widgets.single;
  final shell = JsAppEngine(
    app: JsAppInfo.fromManifest(
      {'id': definition.id, 'name': definition.title, 'version': '1.0.0'},
      bundled: false,
      fallbackId: definition.id,
    ),
    env: env,
    permissions: const AppPermissions(),
  );
  shell.tree.value = {'type': 'text', 'data': 'hello from the widget'};
  dm.debugAdd(definition, engine: shell);
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    await tester.pump();
  }
  await tester.pump();
  return dm;
}

void main() {
  testWidgets(
    'E2E: ⋮ → Open as app renders full-screen ephemerally, back leaves '
    'chat and apps grid untouched (issue #378 AC5)',
    timeout: const Timeout(Duration(minutes: 3)),
    (tester) async {
      final env = MemoryExecutionEnv(cwd: '/');
      // create/sendText ride the real event loop: outside runAsync the
      // test zone's fake clock never advances their real timers.
      // runAsync's result is nullable by signature; the body never
      // completes null.
      final dm = (await tester.runAsync(
        () => _bootAndReceiveWidget(tester, env),
      ))!;
      await tester.pumpAndSettle();
      addTearDown(dm.dispose);

      // The live tile mounted in the transcript at phone width.
      expect(
        find.byType(DynamicWidgetTile, skipOffstage: false),
        findsOneWidget,
      );
      // ⋮ → Open as app (without saving).
      await tester.tap(find.byTooltip('More actions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Open as app (without saving)'));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      // Full-screen renders the widget tree, no JS runtime needed.
      expect(
        find.byKey(const ValueKey('ephemeral-dynamic-app')),
        findsOneWidget,
      );
      expect(find.text('hello from the widget'), findsOneWidget);
      // Graduation writes apps/<id>/...; the bundled js-apps skill seeded
      // under .fah/skills at create() is not persistence.
      bool graduated(String path) =>
          path == '/apps' || path.startsWith('/apps/');
      expect(
        (env as FsSnapshotExporter).exportSnapshot().files.keys.where(
          graduated,
        ),
        isEmpty,
      );
      // Back → the ephemeral route is gone, the transcript is unchanged.
      await tester.pageBack();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byKey(const ValueKey('ephemeral-dynamic-app')), findsNothing);
      expect(
        find.byType(DynamicWidgetTile, skipOffstage: false),
        findsOneWidget,
      );
      expect(find.text('hello from the widget'), findsOneWidget);
      expect(
        (env as FsSnapshotExporter).exportSnapshot().files.keys.where(
          graduated,
        ),
        isEmpty,
      );
    },
  );
}
