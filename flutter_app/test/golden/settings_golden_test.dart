/// Golden (screenshot) tests for `lib/ui/screens/settings.dart` and the
/// providers-first settings pages (`provider_editor_page.dart`,
/// `providers_section.dart`, `media_slot_picker_page.dart`) — plus the BYOK
/// connection form (`AgentSettingsForm`) shared by the setup screen and the
/// on-device route of the default-chat-model flow. Fakes and pump patterns
/// mirror `test/settings_test.dart` (in-memory `ProviderRegistry`, no
/// engines needed: no test connects, so no network/file/JS backends are
/// touched).
///
/// Every shot pumps the form inside a realistic app frame — a `Scaffold`
/// with the settings `AppBar`, the form centered in a max-width column —
/// like `SettingsScreen` does, so the snapshots double as marketing
/// material.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/services/media_models_store.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/services/session_keys_store.dart';
import 'package:fa/services/theme_controller.dart';
import 'package:fa/ui/app_theme.dart';
import 'package:fa/ui/screens/media_slot_picker_page.dart';
import 'package:fa/ui/screens/provider_editor_page.dart';
import 'package:fa/ui/screens/providers_section.dart';
import 'package:fa/ui/screens/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// The editor page's `/models` fetch: image, TTS and vision ids so the
/// capability chips render.
Future<ModelsEndpointInfo> _editorModels(
  String baseUrl, {
  required String apiKey,
}) async => (
  const ['gpt-image-1', 'dall-e-3', 'tts-1', 'gpt-4o'],
  const <String, int>{},
  const <String, int>{},
);

/// Loads the MaterialIcons font from the local Flutter SDK so icon glyphs
/// (dropdown chevrons, add/lock/info icons) render instead of tofu boxes.
/// No-ops when the SDK font cannot be located.
Future<void> _ensureMaterialIcons() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!file.existsSync()) return;
  final bytes = file.readAsBytesSync();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

/// Pumps [child] (the settings form by default) in the same frame
/// `SettingsScreen` uses (app bar + padded scroll view), centered in a
/// readable max-width column so the content fills wide frames instead of
/// getting lost at the edge.
///
/// The theme's `filledButtonTheme.textStyle` carries no `fontFamily` (the
/// `styleFrom` textStyle replaces `labelLarge`), which falls back to the
/// platform font on device but renders tofu in tests — so the frame pins it
/// to Inter, matching the app's one-typeface intent.
Future<void> _pumpSettingsFrame(
  WidgetTester tester, {
  ProviderRegistry? registry,
  Size size = goldenSizeDesktop,
  ThemeData? theme,
  Widget? child,
  bool? isWeb,
}) {
  return pumpGolden(
    tester,
    child ??
        AgentSettingsForm(
          registry: registry,
          connectLabel: 'Apply',
          onConnect: (_) async {},
          isWeb: isWeb,
        ),
    size: size,
    theme: theme,
    wrap: (child) => Builder(
      builder: (context) {
        final theme = Theme.of(context);
        return Theme(
          data: theme.copyWith(
            filledButtonTheme: FilledButtonThemeData(
              style: theme.filledButtonTheme.style?.copyWith(
                textStyle: const WidgetStatePropertyAll(
                  TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),
          child: Scaffold(
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
        );
      },
    ),
  );
}

/// A minimal [AgentService] for the sections that show the active
/// connection (never connected: no network/file/JS backends are touched).
AgentService _fakeService({
  String baseUrl = 'https://openrouter.ai/api/v1',
  String provider = 'openai-completions',
  String modelId = 'z-ai/glm-5.2',
}) {
  return AgentService(
    agent: Agent(
      model: Model(
        id: modelId,
        api: 'test-api',
        provider: provider,
        baseUrl: baseUrl,
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

/// Wraps a full-screen page with the FilledButton font pinned to Inter (see
/// [_pumpSettingsFrame]).
Widget _wrapPage(Widget child) => Builder(
  builder: (context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: theme.filledButtonTheme.style?.copyWith(
            textStyle: const WidgetStatePropertyAll(
              TextStyle(fontFamily: 'Inter', fontWeight: FontWeight.w600),
            ),
          ),
        ),
      ),
      child: child,
    );
  },
);

/// Opens the provider dropdown and picks the entry labelled [label]
/// (verbatim from `test/settings_test.dart`).
Future<void> _selectProvider(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<Object>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureMaterialIcons();
  });

  group('settings goldens', () {
    testWidgets('hosted provider form (OpenRouter)', (tester) async {
      await _pumpSettingsFrame(tester);
      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-or-test-key',
      );
      await tester.pumpAndSettle();

      // Key/model/url fields, the vision checkbox (auto-checked: the default
      // OpenRouter model id suggests vision), and the hosted key note.
      await expectGolden(tester, 'settings_hosted');
    });

    testWidgets('hosted provider form on a portrait frame', (tester) async {
      await _pumpSettingsFrame(tester, size: goldenSizeTall);
      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-or-test-key',
      );
      await tester.pumpAndSettle();

      await expectGolden(tester, 'settings_hosted_tall');
    });

    testWidgets('custom preset form with editable base URL', (tester) async {
      await _pumpSettingsFrame(tester);
      await _selectProvider(tester, 'Custom');
      await tester.enterText(
        find.widgetWithText(TextField, 'Base URL'),
        'http://localhost:8080/v1',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'llama3',
      );
      await tester.pumpAndSettle();

      // Optional key + helper, editable URL, and the CORS note.
      await expectGolden(tester, 'settings_custom');
    });

    testWidgets('saved custom provider shows edit/delete actions', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpSettingsFrame(tester, registry: registry);
      await _selectProvider(tester, 'Acme');

      // Edit/Delete buttons and the "definition is saved" key note.
      await expectGolden(tester, 'settings_custom_saved');
    });

    testWidgets('on-device WebLLM form', (tester) async {
      // WebLLM is hidden on host platforms, so exercise the web provider
      // picker even though the test surface is a desktop frame.
      await _pumpSettingsFrame(tester, isWeb: true);
      await _selectProvider(tester, 'On-device (WebLLM)');

      // The key/model/URL fields are replaced by the model picker with the
      // prompt-tools badge plus the offline/WebGPU notes.
      await expectGolden(tester, 'settings_webllm');
    });

    testWidgets('hosted apply without a key shows the validation error', (
      tester,
    ) async {
      await _pumpSettingsFrame(tester);

      await tester.ensureVisible(find.text('Apply'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      expect(find.text('API key is required'), findsOneWidget);
      await expectGolden(tester, 'settings_validation');
    });

    testWidgets('hosted provider form — light theme', (tester) async {
      await _pumpSettingsFrame(tester, theme: buildFahThemeLight());
      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-or-test-key',
      );
      await tester.pumpAndSettle();

      // The light palette: white inputs on the gray page, darkened
      // indigo/teal accents, dark text.
      await expectGolden(tester, 'settings_hosted_light');
    });

    testWidgets('media models section', (tester) async {
      final store = MediaModelsStore.inMemory();
      await store.setOverride(
        MediaSlot.imageGeneration,
        const MediaSlotOverride(
          providerKind: 'openai-completions',
          baseUrl: 'https://openrouter.ai/api/v1',
          modelId: 'gpt-image-1',
        ),
      );
      await _pumpSettingsFrame(tester, child: MediaModelsSection(store: store));

      // One row per slot: the overridden image slot shows
      // `model · provider name`, the rest fall back to the main connection.
      await expectGolden(tester, 'settings_media_models');
    });

    testWidgets('providers-first settings list', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      final service = _fakeService();
      await _pumpSettingsFrame(
        tester,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ProvidersSection(service: service, registry: registry),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            DefaultChatModelSection(service: service, registry: registry),
          ],
        ),
      );

      // The Providers section on top (the OpenRouter preset marked current,
      // one saved provider, the add row) and the Default chat model row.
      await expectGolden(tester, 'settings_providers');
    });

    testWidgets('provider editor page', (tester) async {
      const provider = CustomProvider(
        id: 'p1',
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await pumpGolden(
        tester,
        size: goldenSizeDesktop,
        wrap: _wrapPage,
        const ProviderEditorPage(
          title: 'Edit provider',
          initial: provider,
          hasSavedKey: true,
        ),
      );
      await tester.pumpAndSettle();

      // Full-screen editor: prefilled fields, the write-only key field with
      // the keep-key note, and the Delete/Save actions.
      await expectGolden(tester, 'settings_provider_editor');
    });

    testWidgets('default model picker page', (tester) async {
      await pumpGolden(
        tester,
        size: goldenSizeDesktop,
        wrap: _wrapPage,
        DefaultModelPickerPage(
          provider: ProviderPreset.openrouter,
          onApply: (_) async {},
          modelsFetcher: _editorModels,
        ),
      );
      // The post-frame /models fetch feeds the quick select.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // The provider header, the prefilled model field and Apply.
      await expectGolden(tester, 'settings_model_picker');
    });

    testWidgets('media slot provider picker page', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await pumpGolden(
        tester,
        size: goldenSizeDesktop,
        wrap: _wrapPage,
        MediaSlotProviderPickerPage(
          slot: MediaSlot.imageGeneration,
          title: 'Edit Image generation',
          mainBaseUrl: 'https://openrouter.ai/api/v1',
          initial: const MediaSlotOverride(
            providerKind: 'openai-completions',
            baseUrl: 'https://openrouter.ai/api/v1',
            modelId: 'gpt-image-1',
          ),
          registry: registry,
          modelsFetcher: _editorModels,
        ),
      );
      await tester.pumpAndSettle();

      // The provider list: the main connection row, the hosted presets (the
      // override's OpenRouter checked), the saved provider, the add row.
      await expectGolden(tester, 'settings_media_provider_picker');
    });

    testWidgets('media slot model page', (tester) async {
      await pumpGolden(
        tester,
        size: goldenSizeDesktop,
        wrap: _wrapPage,
        const MediaSlotModelPage(
          slot: MediaSlot.audioTts,
          provider: ProviderPreset.openrouter,
          initialModel: 'gemini-2.5-flash-preview-tts',
          initialVoice: 'Kore',
          modelsFetcher: _editorModels,
        ),
      );
      // The post-frame /models fetch feeds the chips and the quick select.
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      // The provider header, the prefilled model field, the voice preset
      // picker (Gemini voices, with the sample preview button), the Save
      // action, and the capability chips derived from the endpoint's
      // /models list.
      await expectGolden(tester, 'settings_media_model_page');
    });

    testWidgets('theme and keys sections', (tester) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      registry.rememberKey(provider.id, 'acme-secret');
      final store = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-saved',
      });
      await _pumpSettingsFrame(
        tester,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeModeSection(
              controller: ThemeController.inMemory(FahThemeMode.dark),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            KeysSection(store: store, registry: registry),
          ],
        ),
      );

      // The theme dropdown plus the key rows with their sources (saved /
      // not set / provider session) — values are never shown.
      await expectGolden(tester, 'settings_keys_theme');
    });

    testWidgets('theme and keys sections — light theme', (tester) async {
      final store = SessionKeysStore.inMemory({
        'OPENROUTER_API_KEY': 'sk-or-saved',
      });
      await _pumpSettingsFrame(
        tester,
        theme: buildFahThemeLight(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ThemeModeSection(
              controller: ThemeController.inMemory(FahThemeMode.light),
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            KeysSection(store: store),
          ],
        ),
      );

      await expectGolden(tester, 'settings_keys_theme_light');
    });
  });
}
