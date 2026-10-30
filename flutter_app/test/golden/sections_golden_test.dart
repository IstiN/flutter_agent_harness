/// Golden (screenshot) tests for the setup-screen model sections and the
/// mobile/desktop HTML preview stub.
///
/// Engine fakes are reused verbatim from the sections' widget tests
/// (`webllm_cache_section_test.dart`,
/// `transformers_js_cache_section_test.dart`). `HtmlFilePreview` needs a
/// registered webview platform
/// implementation, so a minimal fake `WebViewPlatform` stands in and renders
/// the markup it was fed — the real webview only exists on device.
///
/// Frames mirror the real hosts: the quick-start section sits in the setup
/// screen's centered 480-wide column (`main.dart`), the cache sections stack
/// in the settings screen's scroll view (`ui/screens/settings.dart`), and
/// the HTML preview fills the preview pane.
library;

import 'dart:io';

import 'package:fa/l10n/l10n_ext.dart';
import 'package:fa/transformers_js/transformers_js_cache_section.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/ui/widgets/html_preview_stub.dart';
import 'package:fa/webllm/webllm_cache_section.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'golden_test_helper.dart';

/// Loads the Material icons font from the Flutter SDK cache so `Icon` widgets
/// render real glyphs — flutter_test does not bundle it (golden_toolkit's
/// approach). No-op when the SDK layout is unfamiliar: icons fall back to
/// boxes rather than failing the suite.
Future<void> _ensureIconFont() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final file = File(
    '$root/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  );
  if (!file.existsSync()) return;
  final bytes = await file.readAsBytes();
  final loader = FontLoader('MaterialIcons')
    ..addFont(Future.value(bytes.buffer.asByteData()));
  await loader.load();
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
/// light canvas showing the exact markup the controller was asked to load —
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
    // The light canvas of the real preview (see `lightCanvasDocument`),
    // filled so the snapshot has no dead area. Render a readable
    // approximation of the fed markup instead of raw tags: strip the
    // injected <style>, lift the <h1>, and un-tag the rest.
    var markup = controller.lastLoadedHtml ?? '';
    markup = markup.replaceAll(RegExp('<style>.*?</style>'), '');
    final heading = RegExp('<h1>(.*?)</h1>').firstMatch(markup)?.group(1);
    final body = markup
        .replaceAll(RegExp('<h1>.*?</h1>'), '')
        .replaceAll(RegExp('<[^>]+>'), '')
        .trim();
    return Container(
      color: const Color(0xFFFFFFFF),
      padding: const EdgeInsets.all(24),
      alignment: Alignment.topLeft,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (heading != null)
            Text(
              heading,
              style: const TextStyle(
                color: Color(0xFF111111),
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
          if (heading != null) const SizedBox(height: 8),
          if (body.isNotEmpty)
            Text(
              body,
              style: const TextStyle(color: Color(0xFF333333), fontSize: 14),
            ),
        ],
      ),
    );
  }
}

/// The settings screen's frame (`ui/screens/settings.dart`): app bar +
/// 24px-padded scrollable stretch column.
Widget _settingsFrame(Widget child) {
  return Builder(
    builder: (context) => Scaffold(
      appBar: AppBar(title: Text(context.l10n.settingsTitle)),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: child,
        ),
      ),
    ),
  );
}

/// gh-2004: the committed `sections_cache_settings` baseline no longer
/// matches the rendered surface (the stacked cache sections lost the
/// GemmaCacheSection and its 24px spacer). Baselines are only valid when
/// baked on the pinned macOS release runner (memory n_1018_80a7 — a
/// linux re-bake corrupts them), so the scenario skips instead of
/// failing the nightly against a stale PNG. Flip to false IN THE SAME
/// CHANGE as the release-runner `flutter test test/golden
/// --update-goldens` re-bake of sections_cache_settings.png.
const _cacheSettingsRebakePending = true;

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureIconFont();
  });

  group('sections goldens', () {
    // gh-2004: the stacked cache sections lost the GemmaCacheSection
    // (and its 24px spacer), so the committed baseline no longer matches
    // what this scenario renders. Baselines are only valid when baked on
    // the pinned macOS release runner (memory n_1018_80a7 — a linux
    // re-bake corrupts them), so the scenario is skipped, not run against
    // a stale PNG. UNSKIP in the same change as the release-runner
    // `flutter test test/golden --update-goldens` re-bake of
    // sections_cache_settings.png.
    testWidgets('cache sections stacked as on the settings screen', (
      tester,
    ) async {
      await pumpGolden(
        tester,
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            WebLlmCacheSection(
              engine: _FakeWebLlmEngine({
                'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
                  cached: true,
                  bytes: 800 * 1024 * 1024,
                ),
                'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
              }),
            ),
            const SizedBox(height: 24),
            TransformersJsCacheSection(
              engine: _FakeTransformersJsEngine({
                'onnx-community/gemma-4-E2B-it-ONNX':
                    const TransformersJsCacheInfo(
                      cached: true,
                      bytes: 3400000000,
                    ),
                'onnx-community/gemma-4-E4B-it-ONNX':
                    const TransformersJsCacheInfo(cached: true),
              }),
            ),
          ],
        ),
        wrap: _settingsFrame,
      );
      await expectGolden(tester, 'sections_cache_settings');
    }, skip: _cacheSettingsRebakePending);

    testWidgets('html preview stub rendering a small document full-frame', (
      tester,
    ) async {
      WebViewPlatform.instance = _FakeWebViewPlatform();
      await pumpGolden(
        tester,
        const HtmlFilePreview(
          html:
              '<h1>Release notes</h1><p>Hello <b>world</b> — this build '
              'adds on-device models.</p>',
        ),
        size: goldenSizeDesktop,
        wrap: (child) => Scaffold(
          appBar: AppBar(title: const Text('notes.html')),
          body: child,
        ),
      );
      await expectGolden(tester, 'sections_html_preview');
    });
  });
}
