// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// REAL end-to-end scenario: the production agent (real LLM endpoint)
/// builds a mini app with a live tile, the launcher shows both, the
/// agent itself sorts the board, and a second session builds another
/// app in parallel.
///
/// Run with:
///   flutter test integration_test/agent_e2e_test.dart -d macos \
///     --dart-define=KIMI_TEST_KEY=<key>
///
/// The key is NEVER committed; without it the test self-skips.
library;

import 'dart:convert';

import 'package:fa/services/launcher_layout_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'e2e_support/e2e_harness.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('E2E: real agent builds apps, a tile, and sorts the board', (
    tester,
  ) async {
    if (!e2eEnabled) {
      // ignore: avoid_print
      print('SKIPPED: needs --dart-define=KIMI_TEST_KEY=<key>');
      return;
    }
    // Real engines under the test binding (we clean them up explicitly).
    AppTileHost.allowEnginesInTests = true;
    addTearDown(() => AppTileHost.allowEnginesInTests = false);

    final world = await bootRealAgent(tester);

    // Start from a CLEAN slate: leftover apps from previous runs would
    // let the agent take the "already exists" shortcut instead of
    // actually building (which is what this test verifies).
    await world.env.exec('rm -rf apps/notes-mini apps/pomo-timer');

    // 1. The agent creates a mini app WITH a live tile.
    await runAgent(
      tester,
      world.service,
      'Create a tiny markdown notes mini app in this sandbox at '
      'apps/notes-mini (manifest.json + widget.js). ALSO give it a live '
      'launcher tile: declare the "widget" section in the manifest and '
      'write apps/notes-mini/widget_tile.js rendering a compact tile. '
      'Keep everything small and simple.',
    );
    final manifest = await readEnvJson(
      world.env,
      'apps/notes-mini/manifest.json',
    );
    expect(
      manifest['widget'],
      isA<Map<String, Object?>>(),
      reason: 'the agent must declare the tile widget section',
    );

    // 2. The launcher shows the app AND boots its live tile. (The live
    // tile renders its own JS content — assert by the host's app id, not
    // a label that may or may not contain the app name. Other demo tiles
    // are on the grid too.)
    await pumpLauncherSettled(tester, world.manager);
    await expectApp(world.apps, 'notes-mini');
    final tileIds = tester
        .widgetList<AppTileHost>(find.byType(AppTileHost))
        .map((h) => h.app.id);
    expect(tileIds, contains('notes-mini'));
    expectTileBooted(tester);

    // 3. The AGENT itself sorts the board: seed a known layout first so
    // the swap is exactly checkable (LLM instructions are
    // non-deterministic; the MECHANISM is what's under test).
    final seededOrder = <String>[
      'app:weather',
      'app:notes-mini',
      'app:contacts',
      'app:reminders',
      LauncherLayoutStore.settingsKey,
      LauncherLayoutStore.filesKey,
    ];
    await world.env.writeFile(
      '${world.env.cwd}/${LauncherLayoutStore.fileName}',
      jsonEncode({
        'version': 2,
        'order': seededOrder,
        'folders': <Object?>[],
        'grid': <String, Object?>{},
        'tileSizes': <String, Object?>{},
      }),
    );
    await runAgent(
      tester,
      world.service,
      'In the sandbox file launcher_layout.json, swap the positions of '
      '"app:weather" and "app:contacts" in the "order" array — contacts '
      'first, then weather. Change NOTHING else in the file.',
    );
    await pumpBounded(tester);
    final layout = await LauncherLayoutStore.load(world.env);
    final contacts = layout.topLevelKeys.indexOf('app:contacts');
    final weather = layout.topLevelKeys.indexOf('app:weather');
    expect(
      contacts >= 0 && weather >= 0 && contacts < weather,
      isTrue,
      reason:
          'the agent must swap contacts before weather in '
          'launcher_layout.json, got ${layout.topLevelKeys}',
    );

    // 4. A SECOND session builds another app in parallel.
    final second = await openSecondSession(world, 'e2e-second');
    await runAgent(
      tester,
      second,
      'Create a tiny pomodoro timer mini app in this sandbox at '
      'apps/pomo-timer (manifest.json + widget.js). Small and simple.',
    );
    await readEnvJson(world.env, 'apps/pomo-timer/manifest.json');

    await pumpBounded(tester);
    final pomoApp = await expectApp(world.apps, 'pomo-timer');
    // notes-mini renders as its live tile (no label), pomo as icon+label.
    final idsAfter = tester
        .widgetList<AppTileHost>(find.byType(AppTileHost))
        .map((h) => h.app.id);
    expect(idsAfter, contains('notes-mini'));
    expect(find.text(pomoApp.name), findsWidgets);

    await unmountAll(tester);
  });
}
