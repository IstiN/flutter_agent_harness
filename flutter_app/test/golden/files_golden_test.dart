/// Golden (screenshot) tests for `lib/ui/widgets/file_browser.dart` and
/// `lib/ui/widgets/file_preview.dart` — the Files panel: listing, empty/
/// error states, and the inline markdown/image previews.
///
/// Fakes mirror `test/file_browser_test.dart`: a `MemoryExecutionEnv` seeded
/// with fixed files (no real file system, no timestamps rendered — tiles
/// show names and byte sizes only). The tree is a realistic Flutter project
/// layout so the snapshots double as marketing material.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:fa/ui/widgets/file_browser.dart';
import 'package:fa/ui/widgets/file_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';
import '../fake_media_controllers.dart';

/// Loads the MaterialIcons font from the local Flutter SDK so icon glyphs
/// (folder/file/refresh/chevron icons) render instead of tofu boxes.
/// No-ops when the SDK font cannot be located. Same approach as
/// `settings_golden_test.dart`.
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

/// 96x96 opaque PNG: teal square with a darker border, so the image preview
/// shows a visible, deterministic picture instead of a transparent pixel.
const _logoPngBytes = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x60,
  0x00,
  0x00,
  0x00,
  0x60,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0xE2,
  0x98,
  0x77,
  0x38,
  0x00,
  0x00,
  0x00,
  0xB8,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0xDA,
  0xED,
  0xD1,
  0x41,
  0x15,
  0x00,
  0x10,
  0x10,
  0x40,
  0xC1,
  0x6D,
  0x20,
  0x89,
  0x6A,
  0x8E,
  0xEA,
  0x29,
  0xA1,
  0x0F,
  0x29,
  0x58,
  0xEF,
  0x99,
  0xC3,
  0x2F,
  0xF0,
  0x27,
  0x4A,
  0x6F,
  0x4B,
  0x79,
  0x85,
  0x09,
  0x00,
  0x00,
  0xE8,
  0x21,
  0x80,
  0x3A,
  0x87,
  0x0E,
  0x06,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x60,
  0x12,
  0x00,
  0x00,
  0x02,
  0x00,
  0x40,
  0x00,
  0x00,
  0x08,
  0x00,
  0x00,
  0x01,
  0x00,
  0x20,
  0x00,
  0x00,
  0x04,
  0x00,
  0x80,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x02,
  0x00,
  0x40,
  0x00,
  0x00,
  0x08,
  0x00,
  0x00,
  0x01,
  0x00,
  0x20,
  0x00,
  0x00,
  0x04,
  0x00,
  0x80,
  0x00,
  0x00,
  0x10,
  0x00,
  0x00,
  0x02,
  0x00,
  0x40,
  0x00,
  0x00,
  0x08,
  0x00,
  0x00,
  0x01,
  0x00,
  0x20,
  0x00,
  0x00,
  0x04,
  0x00,
  0x80,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x00,
  0x60,
  0x12,
  0x00,
  0x00,
  0x02,
  0x00,
  0x40,
  0x00,
  0xFE,
  0x04,
  0xD0,
  0xDD,
  0x00,
  0x00,
  0x00,
  0x60,
  0x44,
  0x62,
  0x1B,
  0x93,
  0x67,
  0x46,
  0xC3,
  0xE3,
  0x9D,
  0x16,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];

const _readmeMd = '''
# Fa — Flutter Agent

An on-device AI coding agent with a **sandboxed filesystem** and
tool-using chat.

## Features

- Chat with tool-using agents on every platform
- Sandboxed file browser with rich previews
- Markdown, HTML and image rendering inline
- Web, macOS, iOS and Android from one codebase

## Quick start

```dart
final service = await AgentService.create(config);
await service.sendText('List the files in lib/');
```

See `pubspec.yaml` for the package layout.
''';

const _pubspecYaml = '''
name: fa
description: On-device AI coding agent.
publish_to: none
version: 0.4.2+1

environment:
  sdk: ^3.5.0

dependencies:
  flutter:
    sdk: flutter
  flutter_agent_harness: ^0.4.0
  flutter_markdown: ^0.7.0
''';

const _changelogMd = '''
# Changelog

## 0.4.2

- Files panel gains inline image previews.

## 0.4.1

- Fix breadcrumb navigation on nested folders.
''';

const _notesMd = '''
# Release notes draft

- [ ] Record demo of the files panel
- [x] Land golden screenshots for CI
- [ ] Publish site update
''';

/// A realistic Flutter project tree: folders first, then well-known files.
Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  await env.createDir('lib/src');
  await env.writeFile(
    'lib/main.dart',
    'void main() => runApp(const FaApp());\n',
  );
  await env.writeFile('lib/src/agent.dart', 'class Agent {}\n');
  await env.createDir('test');
  await env.writeFile('test/widget_test.dart', '// golden tests live here\n');
  await env.createDir('docs');
  await env.writeFile(
    'analysis_options.yaml',
    'include: package:flutter_lints/flutter.yaml\n',
  );
  await env.writeFile('CHANGELOG.md', _changelogMd);
  await env.writeBinaryFile('logo.png', Uint8List.fromList(_logoPngBytes));
  await env.writeFile('notes.md', _notesMd);
  await env.writeFile('pubspec.yaml', _pubspecYaml);
  await env.writeFile('README.md', _readmeMd);
  return env;
}

/// Full-frame host: the browser fills the scaffold body edge to edge.
Future<void> _pumpBrowser(
  WidgetTester tester,
  MemoryExecutionEnv env, {
  Size size = goldenSizeDesktop,
}) {
  return pumpGolden(
    tester,
    FileBrowser(env: env),
    size: size,
    wrap: (child) => Scaffold(body: child),
  );
}

void main() {
  setUpAll(() async {
    await ensureGoldenFonts();
    await _ensureMaterialIcons();
  });

  group('files goldens', () {
    testWidgets('file listing of a realistic project tree', (tester) async {
      final env = await _seededEnv();
      await _pumpBrowser(tester, env);
      await expectGolden(tester, 'files_listing');
    });

    testWidgets('markdown preview with the Preview/Source segments', (
      tester,
    ) async {
      final env = await _seededEnv();
      await _pumpBrowser(tester, env);
      await tester.tap(find.text('README.md'));
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewView), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Source'), findsOneWidget);
      await expectGolden(tester, 'files_preview_markdown');
    });

    testWidgets('image preview renders the in-memory PNG', (tester) async {
      final env = await _seededEnv();
      await _pumpBrowser(tester, env);
      // runAsync lets the real image codec complete outside the fake zone
      // (same approach as `file_browser_test.dart`); pumpAndSettle cannot be
      // used while the preview is mid-decode. Poll until the RawImage holds
      // the decoded frame so the snapshot actually paints the picture.
      await tester.runAsync(() async {
        await tester.tap(find.text('logo.png'));
        await tester.pump();
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
          final raw = tester
              .widgetList<RawImage>(find.byType(RawImage))
              .toList();
          if (raw.isNotEmpty && raw.first.image != null) return;
        }
        fail('image preview never decoded logo.png');
      });
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await expectGolden(tester, 'files_preview_image');
    });

    testWidgets('audio preview renders the inline player', (tester) async {
      final env = MemoryExecutionEnv();
      await env.writeBinaryFile(
        'generated/speech-1785084305459.mp3',
        Uint8List(11976),
      );
      final audio = FakeAudioController(duration: const Duration(seconds: 9));
      await pumpGolden(
        tester,
        FilePreviewScreen(
          env: env,
          path: 'generated/speech-1785084305459.mp3',
          name: 'speech-1785084305459.mp3',
          audioControllerFactory: (_) => audio,
        ),
        size: goldenSizePhone,
        wrap: (child) => child,
      );
      await tester.pumpAndSettle();
      expect(find.text('0:00 / 0:09'), findsOneWidget);
      await expectGolden(tester, 'files_preview_audio');
    });

    testWidgets('empty folder state', (tester) async {
      final env = await _seededEnv();
      await _pumpBrowser(tester, env, size: goldenSizeWide);
      await tester.tap(find.text('docs'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'files_empty_folder');
    });

    testWidgets('listing failure shows the error state with retry', (
      tester,
    ) async {
      // cwd '/missing' is never created, so listing '.' reports notFound.
      final env = MemoryExecutionEnv(cwd: '/missing');
      await _pumpBrowser(tester, env, size: goldenSizeWide);
      expect(find.text('Could not open folder'), findsOneWidget);
      await expectGolden(tester, 'files_error');
    });
  });
}
