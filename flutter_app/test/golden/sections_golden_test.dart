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

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureIconFont();
  });

  group('sections goldens', () {
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
    });

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
