// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/ui/widgets/fah_wallpaper.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

/// A standard, fully decodable 1×1 PNG (real pixels — the wallpaper layer
/// hands the bytes to [Image.memory], and an undecodable image would blow
/// the widget test up via the image resource service).
final _tinyPng = Uint8List.fromList(
  base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
    'AAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
  ),
);

Uint8List _zip(Map<String, List<int>> entries) {
  final archive = Archive();
  entries.forEach((name, bytes) {
    archive.add(ArchiveFile.bytes(name, bytes));
  });
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<ThemePackStore> _storeWithPacks(MemoryExecutionEnv env) async {
  final store = await ThemePackStore.load(env);
  final withWallpaper = await store.installFromZip(
    _zip({
      'theme.json': utf8.encode(
        jsonEncode({
          'name': 'Wallpapered',
          'version': '1.0.0',
          'colors': {
            'dark': {'accent': '#2E7D32'},
          },
          'wallpaper': {'asset': 'bg.png', 'fit': 'cover', 'opacity': 0.5},
        }),
      ),
      'bg.png': _tinyPng,
    }),
  );
  expect(withWallpaper.spec, isNotNull, reason: withWallpaper.reasons.join());
  final colorsOnly = await store.installFromZip(
    _zip({
      'theme.json': utf8.encode(
        jsonEncode({
          'name': 'Plain',
          'version': '1.0.0',
          'colors': {
            'dark': {'accent': '#1E88E5'},
          },
        }),
      ),
    }),
  );
  expect(colorsOnly.spec, isNotNull, reason: colorsOnly.reasons.join());
  return store;
}

Future<void> _pump(
  WidgetTester tester,
  ThemeController controller,
  ThemePackStore store,
) async {
  await tester.pumpWidget(
    FahThemeScope(
      controller: controller,
      child: ThemePackScope(
        store: store,
        child: const MaterialApp(home: Scaffold(body: FahWallpaper())),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('without scopes the layer renders nothing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: FahWallpaper())),
    );
    await tester.pump();

    expect(find.byType(Image), findsNothing);
    expect(find.byType(Opacity), findsNothing);
  });

  testWidgets('the active pack wallpaper paints at its declared opacity', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final store = await _storeWithPacks(env);
    final controller = ThemeController.inMemory();
    addTearDown(controller.dispose);
    await controller.setPack('wallpapered', hasWallpaper: true);
    await _pump(tester, controller, store);

    expect(find.byType(Image), findsOneWidget);
    final opacity = tester.widget<Opacity>(find.byType(Opacity));
    expect(opacity.opacity, 0.5);
  });

  testWidgets(
    'a colors-only active pack keeps the last wallpapered pack (E4)', (
    tester,
  ) async {
    final env = MemoryExecutionEnv();
    final store = await _storeWithPacks(env);
    final controller = ThemeController.inMemory();
    addTearDown(controller.dispose);
    await controller.setPack('wallpapered', hasWallpaper: true);
    await controller.setPack('plain', hasWallpaper: false);
    await _pump(tester, controller, store);

    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('no active pack paints nothing', (tester) async {
    final env = MemoryExecutionEnv();
    final store = await _storeWithPacks(env);
    final controller = ThemeController.inMemory();
    addTearDown(controller.dispose);
    await _pump(tester, controller, store);

    expect(find.byType(Image), findsNothing);
  });
}
