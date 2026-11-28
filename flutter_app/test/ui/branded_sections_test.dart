// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The branded settings sections under the host-only policies (gh-2391
/// addendum 5): the Theme page locks to the profile pack (no stock pack
/// list, no default row, no import, no delete) and the media-slot section
/// every media slot renders (video defaults to the managed
/// aiin/aiin_video alias — the client plays VideoContent inline). Stock
/// renders byte-identically (REG).
library;

import 'package:fa/services/launcher_layout_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/services/theme_packs.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/settings_navigation.dart';
import 'package:fa/ui/widgets/product_brand.dart';
import 'package:fa_ui/fa_ui.dart' as faui;
import 'package:fa_ui/src/providers/media_slot_picker_page.dart'
    show MediaSlotPickerCatalogScope;
import 'package:fa_ui/src/stores/provider_registry.dart';
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
      // The theme page's full furniture: direction picker + packs.
      VisualDirectionSection(),
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

  testWidgets('host-only Models category: the provider zoo is unreachable '
      '— one host row, no add-provider entry (review r3)', (tester) async {
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
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
    await service.initialize();
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'acme-1',
    );
    await registry.upsert(
      const CustomProvider(
        id: 'host',
        name: 'AIIN',
        baseUrl: 'https://api.aiin.example/v1',
        modelId: 'aiin/aiin_flash',
        provenance: 'host',
        kind: 'host-session',
      ),
    );
    await tester.pumpWidget(
      ProductConfigScope(
        productConfig: _lockedProfile(),
        child: MediaSlotPickerCatalogScope(
          restrictToProviderId: 'host',
          child: MaterialApp(
            home: SettingsScreen(
              service: service,
              env: service.env,
              registry: registry,
              layoutStore: LauncherLayoutStore.inMemory(),
              category: SettingsCategory.providersModels,
              embedded: true,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('AIIN'), findsWidgets);
    expect(find.text('Acme'), findsNothing);
    expect(find.textContaining('Add provider'), findsNothing);
  });

  testWidgets('stock Models category: the provider rows render (REG)', (
    tester,
  ) async {
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
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
    await service.initialize();
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'acme-1',
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SettingsScreen(
          service: service,
          env: service.env,
          registry: registry,
          layoutStore: LauncherLayoutStore.inMemory(),
          category: SettingsCategory.providersModels,
          embedded: true,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Acme'), findsWidgets);
    expect(find.textContaining('Add provider'), findsWidgets);
  });

  group('theme page direction picker (gh-2391 addendum 8 item 6)', () {
    testWidgets('profile-locked: the stock direction names never render — '
        'the pack row is the only theme identity', (tester) async {
      final store = await ThemePackStore.load(MemoryExecutionEnv());
      final spec = validateThemePack(
        _lockedProfile().themePack!,
        const {},
      ).spec!;
      store.registerHostPack(
        InstalledThemePack(spec: spec, wallpaperBytes: null),
      );
      await _pump(tester, config: _lockedProfile(), store: store);
      expect(find.text('Liquid Glass'), findsNothing);
      expect(find.text('Nebula'), findsNothing);
      // The profile pack stays the page's single theme identity.
      expect(find.text('AIIN Porcelain'), findsOneWidget);
    });

    testWidgets('stock: the direction previews stay (REG)', (tester) async {
      await _pump(tester);
      expect(find.text('Liquid Glass'), findsOneWidget);
    });
  });
}
