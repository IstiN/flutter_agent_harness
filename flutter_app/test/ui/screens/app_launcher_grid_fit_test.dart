// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Regression tests for the Launchpad grid track-fit contract (debt #2357,
/// deferred from the PR #2354 review): `_buildDraggableGrid` must NOT
/// pre-subtract the scroll view's gutters before calling `_crossAxisCount`
/// — the method reserves the 32pt gutter pair exactly once itself. The
/// pre-fix code subtracted it twice, so a pane within 32pt above a column
/// boundary dropped a track (64pt reserved for a 32pt gutter pair).
///
/// Fit contract (single subtraction), cell 60pt, embedded spacing 12 /
/// desktop spacing 24: k tracks ⇔ lane ≥ (cell + spacing)·k − spacing + 32.
/// The tests pump the REAL `AppLauncherScreen` at band-edge widths and read
/// the rendered tile positions (`tilePos:*` keys), so any future
/// reintroduction of a double reduction fails here — on the ubuntu PR
/// shard, not only in the macOS nightly goldens.
library;

import 'package:fa/apps/apps_store.dart';
import 'package:fa/l10n/app_localizations.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/flutter_session_manager.dart';
import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/app_launcher_screen.dart';
import 'package:fa/ui/widgets/span_grid_delegate.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors the inert fake in `test/ui/chats/chat_list_delete_test.dart` —
/// the launcher only needs a session to exist, never to stream.
AgentService _service(ExecutionEnv env) => AgentService(
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
  env: env,
  sessionsRoot: '/sessions',
  config: AgentConfig(
    providerKind: 'test',
    modelId: 'test-model',
    baseUrl: 'https://example.com',
    apiKey: '',
  ),
);

/// Seeds [count] plain 1x1 apps (icon-only manifests, no live tiles) into a
/// [MemoryExecutionEnv] — enough to fill a full desktop row when measuring
/// the `fullScreen` track count.
Future<(MemoryExecutionEnv, FlutterSessionManager)> _manager(int count) async {
  final env = MemoryExecutionEnv();
  final icon =
      "<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'>"
      "<rect x='4' y='4' width='16' height='16' rx='6' fill='#0ea5e9'/></svg>";
  for (var i = 0; i < count; i++) {
    await env.writeFile(
      'apps/app$i/manifest.json',
      '{"id": "app$i", "name": "App $i", "description": "App $i app", '
          '"icon": "$icon"}',
    );
    await env.writeFile('apps/app$i/widget.js', '(function(){});');
  }
  return (
    env,
    FlutterSessionManager(env: env, sessionsRoot: '/sessions')
      ..addSession('fake-session', _service(env)),
  );
}

/// Pumps the launcher at an exact [size] with no duo rail (raw lane ==
/// surface width) and `MediaQuery` paddings at zero.
Future<void> _pumpLauncher(
  WidgetTester tester, {
  required Size size,
  int apps = 4,
  bool fullScreen = false,
  int? gridColumns,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final (env, manager) = await _manager(apps);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildFahTheme(),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AppLauncherScreen(
        manager: manager,
        layoutStore: LauncherLayoutStore.inMemory(
          order: [
            for (var i = 0; i < apps; i++) 'app$i',
            LauncherLayoutStore.settingsKey,
            LauncherLayoutStore.filesKey,
          ],
          gridColumns: gridColumns,
        ),
        appsStore: AppsStore(
          env,
          readAsset: (path) async =>
              throw StateError('no bundled assets in this test'),
          seedDemoIds: const [],
        ),
        fullScreen: fullScreen,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The single-subtraction fit spec the screen must implement.
int _fittedTracks(double lane, {required double spacing}) =>
    ((lane - 32 + spacing) / (LauncherGridSpec.cellCrossExtent + spacing))
        .floor();

Rect _tileRect(WidgetTester tester, Widget w) =>
    tester.getRect(find.byWidget(w));

List<Widget> _tiles(WidgetTester tester) => tester
    .widgetList(
      find.byWidgetPredicate(
        (w) =>
            w.key is ValueKey<String> &&
            (w.key! as ValueKey<String>).value.startsWith('tilePos:'),
      ),
    )
    .toList();

/// Distinct tile-column origins of the settled grid — for a full first row
/// of 1x1 tiles this equals the rendered track count.
int _renderedColumns(WidgetTester tester) =>
    _tiles(tester).map((w) => _tileRect(tester, w).left).toSet().length;

/// Width of the grid Stack — the screen's `gridWidth`
/// (min(availableGridWidth, occupiedWidth)) in GRID space: tile rects live
/// inside the scroll view's padding + Align centering, so their GLOBAL
/// rights are offset; the Stack width is the exact contract value. For a
/// full first row this equals the occupied width.
double _gridWidth(WidgetTester tester) => tester
    .getSize(
      find
          .descendant(
            of: find.byKey(const ValueKey('appsGridScrollView')),
            matching: find.byType(Stack),
          )
          .first,
    )
    .width;

void main() {
  group('launcher grid track fit (debt #2357, single 32pt gutter pair)', () {
    testWidgets('phone default 390pt lane keeps 5 tracks (pre-fix dropped '
        'to 4)', (tester) async {
      await _pumpLauncher(tester, size: const Size(390, 844));
      const lanes = 390.0;
      expect(_fittedTracks(lanes, spacing: LauncherGridSpec.spacing), 5);
      expect(_renderedColumns(tester), 5);
      expect(
        _gridWidth(tester),
        5 * LauncherGridSpec.cellCrossExtent + 4 * LauncherGridSpec.spacing,
      );
    });

    testWidgets('exact 5-track boundary: 380 fits 5, 379 fits 4', (
      tester,
    ) async {
      // 380: usable 348 == 5·60 + 4·12 — the grid fills the lane exactly.
      await _pumpLauncher(tester, size: const Size(380, 844));
      expect(_renderedColumns(tester), 5);
      expect(
        _gridWidth(tester),
        5 * LauncherGridSpec.cellCrossExtent + 4 * LauncherGridSpec.spacing,
      );
      expect(_gridWidth(tester), lessThanOrEqualTo(380 - 32));

      // One point lower the fifth track must drop (no over-fitting here).
      await _pumpLauncher(tester, size: const Size(379, 844));
      expect(_renderedColumns(tester), 4);
    });

    testWidgets('a 6-track layout override clamps to the 5-track fit', (
      tester,
    ) async {
      await _pumpLauncher(tester, size: const Size(390, 844), gridColumns: 6);
      expect(_renderedColumns(tester), 5);
    });

    testWidgets('fullScreen desktop 1280pt lane keeps 15 tracks (pre-fix '
        'dropped to 14)', (tester) async {
      await _pumpLauncher(
        tester,
        size: const Size(1280, 800),
        apps: 16,
        fullScreen: true,
      );
      const lanes = 1280.0;
      expect(
        _fittedTracks(lanes, spacing: LauncherGridSpec.desktopSpacing),
        15,
      );
      expect(_renderedColumns(tester), 15);
      expect(
        _gridWidth(tester),
        15 * LauncherGridSpec.cellCrossExtent +
            14 * LauncherGridSpec.desktopSpacing,
      );
      expect(_gridWidth(tester), lessThanOrEqualTo(1280 - 32));
    });
  });
}
