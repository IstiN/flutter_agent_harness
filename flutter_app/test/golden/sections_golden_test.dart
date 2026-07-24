/// Golden (screenshot) tests for the setup-screen model sections and the
/// mobile/desktop HTML preview stub.
///
/// Engine fakes are reused verbatim from the sections' widget tests
/// (`gemma_cache_section_test.dart`, `webllm_cache_section_test.dart`,
/// `transformers_js_cache_section_test.dart`); the same three fakes also
/// drive `DownloadedModelsQuickStart` (the quick-start test's own fakes only
/// add progress/load scripting that the resting-state snapshots below do not
/// need). `HtmlFilePreview` needs a registered webview platform
/// implementation, so a minimal fake `WebViewPlatform` stands in and renders
/// the markup it was fed — the real webview only exists on device.
library;

import 'package:fa/downloaded_models_quick_start.dart';
import 'package:fa/gemma/gemma_cache_section.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/html_preview_stub.dart';
import 'package:fa/transformers_js/transformers_js_cache_section.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_cache_section.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'golden_test_helper.dart';

/// Fake Gemma engine with a scripted repository: [installed] maps install
/// file names to recorded byte sizes (reused from
/// `gemma_cache_section_test.dart`).
final class _FakeGemmaEngine implements GemmaEngineApi {
  _FakeGemmaEngine({Map<String, int?>? installed})
    : installed = installed ?? {};

  /// The golden states only use the mobile install file names.
  static const bool isWeb = false;

  /// Repository contents: install filename → recorded byte size.
  final Map<String, int?> installed;

  bool available = true;
  GemmaModelPreset? loadedPreset;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<GemmaProgress> get progressEvents => const Stream.empty();

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async =>
      installed.containsKey(preset.filenameFor(isWeb: isWeb));

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {}

  @override
  Future<void> loadModel(GemmaModelPreset preset) async {
    loadedPreset = preset;
  }

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
  Future<void> unload() async {
    loadedPreset = null;
  }

  @override
  Future<List<GemmaInstalledModel>> installedModels() async => [
    for (final entry in installed.entries)
      GemmaInstalledModel(filename: entry.key, sizeBytes: entry.value),
  ];

  @override
  Future<void> uninstall(String filename) async {
    installed.remove(filename);
  }
}

/// Fake WebLLM engine answering cache queries from a script (reused from
/// `webllm_cache_section_test.dart`).
final class _FakeWebLlmEngine implements WebLlmEngineApi {
  _FakeWebLlmEngine(this.cache);

  final Map<String, WebLlmCacheInfo> cache;

  bool available = true;
  String? loadedId;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedId;

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
  Future<void> deleteCachedModel(String modelId) async {
    cache.remove(modelId);
    if (loadedId == modelId) loadedId = null;
  }
}

/// Fake transformers.js engine answering cache queries from a script
/// (reused from `transformers_js_cache_section_test.dart`).
final class _FakeTransformersJsEngine implements TransformersJsEngineApi {
  _FakeTransformersJsEngine(this.cache);

  final Map<String, TransformersJsCacheInfo> cache;

  bool available = true;
  String? loadedId;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedId;

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
  Future<void> deleteCachedModel(String modelId) async {
    cache.remove(modelId);
    if (loadedId == modelId) loadedId = null;
  }
}

/// Minimal fake webview platform so `HtmlFilePreview` (which constructs a
/// real `WebViewController`) can build in a host test. The fake "view" is a
/// light box showing the exact markup the controller was asked to load —
/// native rendering is exercised on device only.
final class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakePlatformWebViewController(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);
}

final class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  /// The last markup passed to `loadHtmlString`.
  String? lastLoadedHtml;

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate handler,
  ) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    lastLoadedHtml = html;
  }
}

final class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}
}

final class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    final controller = params.controller as _FakePlatformWebViewController;
    return ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Text(
          controller.lastLoadedHtml ?? '',
          style: const TextStyle(color: Color(0xFF111111), fontSize: 10),
        ),
      ),
    );
  }
}

/// Sections render full-width inside a scroll view on the settings/setup
/// screens, so goldens pump them the same way.
Widget _sectionHost(Widget child) {
  return Scaffold(body: SingleChildScrollView(child: child));
}

void main() {
  group('sections goldens', () {
    testWidgets('quick-start with cached models list', (tester) async {
      await pumpGolden(
        tester,
        DownloadedModelsQuickStart(
          onConnect: (_) async {},
          isWeb: false,
          webLlmEngine: _FakeWebLlmEngine({
            'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
              cached: true,
              bytes: 800 * 1024 * 1024,
            ),
          }),
          transformersJsEngine: _FakeTransformersJsEngine({
            'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
              cached: true,
            ),
          }),
          gemmaEngine: _FakeGemmaEngine(
            installed: {'gemma-4-E2B-it.litertlm': 2000 * 1024 * 1024},
          ),
        ),
        wrap: _sectionHost,
      );
      await expectGolden(tester, 'sections_quick_start');
    });

    testWidgets('WebLLM cache section with two cached models', (tester) async {
      await pumpGolden(
        tester,
        WebLlmCacheSection(
          engine: _FakeWebLlmEngine({
            'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
              cached: true,
              bytes: 800 * 1024 * 1024,
            ),
            'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
          }),
        ),
        wrap: _sectionHost,
      );
      await expectGolden(tester, 'sections_webllm_cache');
    });

    testWidgets('transformers.js cache section with two cached models', (
      tester,
    ) async {
      await pumpGolden(
        tester,
        TransformersJsCacheSection(
          engine: _FakeTransformersJsEngine({
            'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
              cached: true,
              bytes: 3400000000,
            ),
            'onnx-community/gemma-4-E4B-it-ONNX': const TransformersJsCacheInfo(
              cached: true,
            ),
          }),
        ),
        wrap: _sectionHost,
      );
      await expectGolden(tester, 'sections_transformers_js_cache');
    });

    testWidgets('Gemma cache section with two installed models', (
      tester,
    ) async {
      await pumpGolden(
        tester,
        GemmaCacheSection(
          engine: _FakeGemmaEngine(
            installed: {
              'gemma-4-E2B-it.litertlm': 2576980378,
              'gemma-4-E4B-it.litertlm': null,
            },
          ),
        ),
        wrap: _sectionHost,
      );
      await expectGolden(tester, 'sections_gemma_cache');
    });

    testWidgets('html preview stub rendering a small document', (tester) async {
      WebViewPlatform.instance = _FakeWebViewPlatform();
      await pumpGolden(
        tester,
        const HtmlFilePreview(html: '<h1>Notes</h1><p>Hello <b>world</b></p>'),
        wrap: (child) => Scaffold(body: child),
      );
      await expectGolden(tester, 'sections_html_preview');
    });
  });
}
