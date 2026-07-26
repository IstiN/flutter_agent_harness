/// Golden (screenshot) tests for `lib/main.dart`'s [SetupScreen] — the
/// first-run connection form with the downloaded-models quick start on top.
/// Fakes mirror `test/setup_prefill_test.dart`: scripted engine cache
/// answers, in-memory registry/store, no real IO or plugins.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/main.dart';
import 'package:fa/services/last_connection.dart';
import 'package:fa/services/provider_registry.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Loads the MaterialIcons font from the local Flutter SDK so icon glyphs
/// (dropdown chevrons, add/lock/info icons) render instead of tofu boxes
/// (same loader as `settings_golden_test.dart`). No-ops when the SDK font
/// cannot be located.
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

/// Fake [WebLlmEngineApi] answering cache queries from a script (the same
/// fake as `test/setup_prefill_test.dart`).
final class _FakeWebLlmEngine implements WebLlmEngineApi {
  _FakeWebLlmEngine(this.cache);

  final Map<String, WebLlmCacheInfo> cache;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => null;

  @override
  Stream<WebLlmProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(WebLlmModelPreset preset) async {}

  @override
  Future<void Function()> chatStream({
    required List<WebLlmChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async => () {};

  @override
  Future<void> interrupt() async {}

  @override
  Future<WebLlmCacheInfo?> modelCacheInfo(String modelId) async =>
      cache[modelId];

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

/// Fake [GemmaEngineApi] answering the installed-models scan from a script.
final class _FakeGemmaEngine implements GemmaEngineApi {
  _FakeGemmaEngine(this.installed);

  final List<GemmaInstalledModel> installed;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => null;

  @override
  Stream<GemmaProgress> get progressEvents => const Stream.empty();

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async => false;

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {}

  @override
  Future<void> loadModel(GemmaModelPreset preset) async {}

  @override
  Future<void> chatStream({
    required List<GemmaChatMessage> messages,
    required void Function(String chunk) onChunk,
    String? systemInstruction,
    void Function()? onDone,
    void Function(String message)? onError,
    void Function(String toolCallsJson)? onToolCalls,
    List<Map<String, dynamic>>? tools,
    int? maxOutputTokens,
  }) async {}

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> unload() async {}

  @override
  Future<List<GemmaInstalledModel>> installedModels() async => installed;

  @override
  Future<void> uninstall(String filename) async {}
}

/// Fake [TransformersJsEngineApi] answering cache queries from a script.
final class _FakeTransformersJsEngine implements TransformersJsEngineApi {
  _FakeTransformersJsEngine(this.cache);

  final Map<String, TransformersJsCacheInfo> cache;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => null;

  @override
  Stream<TransformersJsProgress> get progressEvents => const Stream.empty();

  @override
  Future<void> loadModel(TransformersJsModelPreset preset) async {}

  @override
  Future<void Function()> chatStream({
    required List<TransformersJsChatMessage> messages,
    required void Function(String chunk) onChunk,
    void Function(String finishReason)? onDone,
    void Function(String message)? onError,
    int? maxTokens,
  }) async => () {};

  @override
  Future<void> interrupt() async {}

  @override
  Future<void> unloadModel() async {}

  @override
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async =>
      cache[modelId];

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

/// Pumps [SetupScreen] full-screen (it is itself a `Scaffold`) with
/// deterministic fakes: in-memory env/registry/store and scripted engines.
///
/// The theme's `filledButtonTheme.textStyle` carries no `fontFamily` (the
/// `styleFrom` textStyle replaces `labelLarge`), which renders tofu in tests
/// — the wrap pins it to Inter, matching the app's one-typeface intent (same
/// fix as `settings_golden_test.dart`).
Future<void> _pumpSetup(
  WidgetTester tester, {
  Size size = goldenSizeDesktop,
  ProviderRegistry? registry,
  LastConnection? lastConnection,
  _FakeWebLlmEngine? webLlmEngine,
  _FakeGemmaEngine? gemmaEngine,
  _FakeTransformersJsEngine? transformersJsEngine,
}) async {
  final store = LastConnectionStore.inMemory();
  if (lastConnection != null) await store.save(lastConnection);
  await pumpGolden(
    tester,
    SetupScreen(
      env: MemoryExecutionEnv(),
      registry: registry ?? ProviderRegistry.inMemory(),
      lastConnectionStore: store,
      webLlmEngine: webLlmEngine ?? _FakeWebLlmEngine(const {}),
      gemmaEngine: gemmaEngine ?? _FakeGemmaEngine(const []),
      transformersJsEngine:
          transformersJsEngine ?? _FakeTransformersJsEngine(const {}),
    ),
    size: size,
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
          child: child,
        );
      },
    ),
  );
}

/// Engines scripted with three already-downloaded on-device models: one per
/// engine family, with fixed byte counts so the size labels are stable.
({
  _FakeWebLlmEngine webLlm,
  _FakeGemmaEngine gemma,
  _FakeTransformersJsEngine transformersJs,
})
_downloadedEngines() {
  return (
    webLlm: _FakeWebLlmEngine(const {
      'Qwen3-4B-q4f16_1-MLC': WebLlmCacheInfo(cached: true, bytes: 2900000000),
    }),
    gemma: _FakeGemmaEngine(const [
      GemmaInstalledModel(
        filename: 'gemma-4-E4B-it.litertlm',
        sizeBytes: 4300000000,
      ),
    ]),
    transformersJs: _FakeTransformersJsEngine(const {
      'onnx-community/gemma-4-E2B-it-ONNX': TransformersJsCacheInfo(
        cached: true,
        bytes: 2500000000,
      ),
    }),
  );
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureMaterialIcons();
  });

  testWidgets('first run on a phone: empty quick start, default hosted form', (
    tester,
  ) async {
    await _pumpSetup(tester, size: goldenSizePhone);
    await expectGolden(tester, 'setup_first_run_phone');
  });

  testWidgets('quick start lists cached/installed on-device models', (
    tester,
  ) async {
    final engines = _downloadedEngines();
    await _pumpSetup(
      tester,
      webLlmEngine: engines.webLlm,
      gemmaEngine: engines.gemma,
      transformersJsEngine: engines.transformersJs,
    );
    await expectGolden(tester, 'setup_quick_start_desktop');
  });

  testWidgets('quick start on a phone frame', (tester) async {
    final engines = _downloadedEngines();
    await _pumpSetup(
      tester,
      size: goldenSizePhone,
      webLlmEngine: engines.webLlm,
      gemmaEngine: engines.gemma,
      transformersJsEngine: engines.transformersJs,
    );
    await expectGolden(tester, 'setup_quick_start_phone');
  });

  testWidgets('a saved hosted connection prefills the form', (tester) async {
    await _pumpSetup(
      tester,
      lastConnection: const LastConnection(
        providerKind: 'openai-completions',
        modelId: 'gpt-oss:120b',
        baseUrl: 'https://ollama.com/v1',
      ),
    );
    await expectGolden(tester, 'setup_prefilled_hosted_desktop');
  });

  testWidgets('a saved custom provider is re-selected with the edit action', (
    tester,
  ) async {
    final registry = ProviderRegistry.inMemory();
    await registry.add(
      name: 'Acme',
      baseUrl: 'https://acme.example/v1',
      modelId: 'acme-1',
    );
    await _pumpSetup(
      tester,
      registry: registry,
      lastConnection: const LastConnection(
        providerKind: 'openai-completions',
        modelId: 'acme-1',
        baseUrl: 'https://acme.example/v1',
      ),
    );
    await expectGolden(tester, 'setup_custom_provider_desktop');
  });

  testWidgets('a removed on-device model falls back with a note', (
    tester,
  ) async {
    await _pumpSetup(
      tester,
      lastConnection: const LastConnection(
        providerKind: webLlmProviderKind,
        modelId: 'Qwen3-4B-q4f16_1-MLC',
        webllmPresetId: 'Qwen3-4B-q4f16_1-MLC',
      ),
      webLlmEngine: _FakeWebLlmEngine(const {
        // The cache query answers "gone".
        'Qwen3-4B-q4f16_1-MLC': WebLlmCacheInfo(cached: false),
      }),
    );
    await expectGolden(tester, 'setup_model_removed_note_desktop');
  });
}
