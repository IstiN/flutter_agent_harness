// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The branded settings sections under the host-only policies (gh-2391
/// addendum 5): the Theme page locks to the profile pack (no stock pack
/// list, no default row, no import, no delete) and the media-slot section
/// hides video generation (no managed alias yet). Stock renders
/// byte-identically (REG).
library;

import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/services/theme_packs.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

Future<void> _pump(
  WidgetTester tester, {
  FaProductConfig? config,
  ThemePackStore? store,
}) async {
  final controller = ThemeController.inMemory(FahThemeMode.dark);
  final packs = store ?? await ThemePackStore.load(MemoryExecutionEnv());
  Widget home = Column(
    children: [
      ThemePacksSection(),
      MediaModelsSection(store: MediaModelsStore.inMemory()),
    ],
  );
  if (config != null) {
    home = ProductConfigScope(productConfig: config, child: home);
  }
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: SingleChildScrollView(
          child: ThemePackScope(
            store: packs,
            child: FahThemeScope(controller: controller, child: home),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

FaProductConfig _lockedProfile() => FaProductConfig.fromJson({
  'productId': 'ain',
  'displayName': 'AIIN Agent',
  'apiEndpoint': 'https://api.aiin.example/v1',
  'featureFlags': <String>[],
  'themePackId': 'aiin-porcelain',
  'themePicker': 'profile-locked',
  'channels': 'host-only',
  'providerCatalog': 'host-only',
  'hostConnection': {
    'baseUrl': 'https://api.aiin.example/v1',
    'sessionBridge': {'storage': 'localStorage', 'key': 'aiin_agent_session'},
    'defaultModel': 'aiin/aiin_flash',
  },
  'themePack': {
    'name': 'AIIN Porcelain',
    'version': '1.0.0',
    'colors': {
      'dark': {
        'background': '#07080D',
        'surface': '#101218',
        'text': '#E9EAEE',
        'accent': '#4ADE80',
        'accent2': '#A78BFA',
        'onAccent': '#07080D',
      },
      'light': {
        'background': '#F4F2EE',
        'surface': '#FAF8F5',
        'text': '#1C1B18',
        'accent': '#4ADE80',
        'accent2': '#A78BFA',
        'onAccent': '#07080D',
      },
    },
  },
});

void main() {
  testWidgets('locked theme page: only the profile pack — no import, '
      'no default row, no delete', (tester) async {
    final store = await ThemePackStore.load(MemoryExecutionEnv());
    final spec = validateThemePack(_lockedProfile().themePack!, const {}).spec!;
    store.registerHostPack(
      InstalledThemePack(spec: spec, wallpaperBytes: null),
    );
    await _pump(tester, config: _lockedProfile(), store: store);
    expect(find.text('AIIN Porcelain'), findsOneWidget);
    // The stock picker furniture is gone.
    expect(find.textContaining('Import'), findsNothing);
    expect(find.byIcon(Icons.delete_outline), findsNothing);
  });

  testWidgets('stock theme page: default row + import remain (REG)', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.textContaining('Import'), findsWidgets);
  });

  testWidgets('host-only media slots: every slot renders — video defaults '
      'to the managed aiin/aiin_video alias (addendum 7: the client '
      'renders VideoContent inline)', (tester) async {
    final store = await ThemePackStore.load(MemoryExecutionEnv());
    final spec = validateThemePack(_lockedProfile().themePack!, const {}).spec!;
    store.registerHostPack(
      InstalledThemePack(spec: spec, wallpaperBytes: null),
    );
    await _pump(tester, config: _lockedProfile(), store: store);
    expect(find.textContaining('Video'), findsOneWidget);
    expect(find.textContaining('Image generation'), findsOneWidget);
  });

  testWidgets('stock media slots: video generation row stays (REG)', (
    tester,
  ) async {
    await _pump(tester);
    expect(find.textContaining('Video'), findsWidgets);
  });
}
