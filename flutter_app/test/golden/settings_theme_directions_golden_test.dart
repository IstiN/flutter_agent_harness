/// Golden (screenshot) tests for the rebuilt settings surfaces across the
/// Fa 2.0 visual directions: every major settings screen now renders on
/// styleguide primitives (FaButton/FaIconButton/FaSurface/FaSwitch and the
/// shared token rows in `settings_tiles.dart`), so each screen is shot in
/// the default glass direction AND an opaque direction (graphite,
/// porcelain), in light and dark brightness — the theme-apply regression
/// sweep for the "settings leak Material styling" fix.
///
/// Stores and services are fully mocked (in-memory registries/stores, a
/// never-connected [AgentService], a scripted [DapHubService]) — no app
/// launch, no network, no engines. Fakes mirror
/// `test/golden/settings_golden_test.dart`.
library;

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/dap_service.dart';
import 'package:fa/services/image_preview_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/services/theme_pack_store.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/ui/screens/dap_settings_page.dart';
import 'package:fa/ui/screens/model_presets.dart';
import 'package:fa/ui/screens/redaction_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:fa/ui/screens/skills_toggles_section.dart';
import 'package:fa/ui/screens/tools_availability_section.dart';
import 'package:fa_ui/fa_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// A minimal never-connected [AgentService] (the settings_golden pattern).
AgentService _fakeService() {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'z-ai/glm-5.2',
        api: 'test-api',
        provider: 'openai-completions',
        baseUrl: 'https://openrouter.ai/api/v1',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are Fa.',
      streamFunction: (model, context, {cancelToken}) =>
          AssistantMessageEventStream()..end(),
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

/// The never-picking picker seam: `canPick` resolves deterministically to
/// true, so the section's FaButton import action renders on every host.
class _NoopPicker implements UploadPicker {
  const _NoopPicker();

  @override
  Future<List<UploadFile>> pick() async => const <UploadFile>[];
}

/// Deterministic [DapHubService]: one connected snapshot, no `~/.dap`.
class _FakeDapHubService implements DapHubService {
  const _FakeDapHubService(this.snapshot);

  final DapHubSnapshot snapshot;

  @override
  Future<DapHubSnapshot> load() async => snapshot;

  @override
  Future<DapHubSnapshot> probe() async => snapshot.withProbe(true);

  @override
  Future<void> saveConnection({
    required String url,
    required String name,
    String? secret,
  }) async {}

  @override
  Future<List<DapBindableSession>> listBindableSessions() async => const [];

  @override
  Future<void> saveBinding(
    DapInboundMode mode, {
    String? sessionId,
    String? sessionTitle,
  }) async {}
}

/// One direction/brightness combination to shoot every screen in.
typedef _Variant = ({String name, FaVisualDirection direction, Brightness brightness});

const _variants = <_Variant>[
  (
    name: 'glass_dark',
    direction: FaVisualDirection.glass,
    brightness: Brightness.dark,
  ),
  (
    name: 'glass_light',
    direction: FaVisualDirection.glass,
    brightness: Brightness.light,
  ),
  (
    name: 'graphite_dark',
    direction: FaVisualDirection.graphite,
    brightness: Brightness.dark,
  ),
  (
    name: 'porcelain_light',
    direction: FaVisualDirection.porcelain,
    brightness: Brightness.light,
  ),
];

/// Pumps [child] in the settings frame (app bar + centered 560px column)
/// under [variant]'s real shared theme builder.
Future<void> _pumpSection(WidgetTester tester, _Variant variant, Widget child) {
  return pumpGolden(
    tester,
    child,
    theme: buildFaTheme(
      direction: variant.direction,
      brightness: variant.brightness,
    ),
    wrap: (child) => Builder(
      builder: (context) => Scaffold(
        appBar: AppBar(title: Text(context.l10n.settingsTitle)),
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 560),
                child: child,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  setUpAll(ensureGoldenFonts);

  for (final variant in _variants) {
    testWidgets('appearance sections (${variant.name})', (tester) async {
      final controller = ThemeController.inMemory(
        variant.brightness == Brightness.dark
            ? FahThemeMode.dark
            : FahThemeMode.light,
      );
      final store = await ThemePackStore.load(MemoryExecutionEnv());
      final previews = ImagePreviewStore(MemoryExecutionEnv());
      await _pumpSection(
        tester,
        variant,
        ThemePackScope(
          store: store,
          child: FahThemeScope(
            controller: controller,
            child: ImagePreviewScope(
              store: previews,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  ThemeModeSection(),
                  SizedBox(height: 24),
                  VisualDirectionSection(),
                  SizedBox(height: 24),
                  ThemePacksSection(picker: _NoopPicker()),
                  SizedBox(height: 24),
                  ImagePreviewsSection(),
                ],
              ),
            ),
          ),
        ),
      );
      await expectGolden(tester, 'settings_theme_${variant.name}');
    });

    testWidgets('control sections (${variant.name})', (tester) async {
      final service = _fakeService();
      addTearDown(service.dispose);
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'acme-secret');
      final keys = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-saved',
      });
      await _pumpSection(
        tester,
        variant,
        SessionKeysScope(
          store: keys,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              SkillsTogglesSection(service: service),
              const SizedBox(height: 24),
              ToolsAvailabilitySection(service: service),
              const SizedBox(height: 24),
              RedactionSection(service: service),
              const SizedBox(height: 24),
              KeysSection(store: keys, registry: registry),
            ],
          ),
        ),
      );
      await expectGolden(tester, 'settings_controls_${variant.name}');
    });

    testWidgets('model presets card (${variant.name})', (tester) async {
      final service = _fakeService();
      addTearDown(service.dispose);
      final mediaStore = MediaModelsStore.inMemory();
      final keys = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-saved',
      });
      await _pumpSection(
        tester,
        variant,
        SessionKeysScope(
          store: keys,
          child: MediaModelsScope(
            store: mediaStore,
            child: SizedBox(
              height: 520,
              child: ModelPresetsSection(
                service: service,
                store: mediaStore,
                taskModelsStore: TaskModelsStore.inMemory(),
              ),
            ),
          ),
        ),
      );
      await expectGolden(tester, 'settings_presets_${variant.name}');
    });
  }

  // The DAP hub page (a full-screen Scaffold of its own) in the dark
  // variants: the connection rows, status chip, FaButton actions.
  for (final variant in _variants.where((v) => v.name.endsWith('_dark'))) {
    testWidgets('dap hub list (${variant.name})', (tester) async {
      const connected = DapHubSnapshot(
        supported: true,
        url: 'ws://hub.example.com/ws',
        name: 'fa-desktop',
        agentId: 'a1b2c3d4e5f60718',
        channels: ['general', 'project-x'],
      );
      await pumpGolden(
        tester,
        const DapHubPage(service: _FakeDapHubService(connected)),
        size: goldenSizeDesktop,
        theme: buildFaTheme(
          direction: variant.direction,
          brightness: variant.brightness,
        ),
        wrap: (child) => child,
      );
      await expectGolden(tester, 'settings_dap_${variant.name}');
    });
  }
}
