/// Golden (screenshot) tests for `lib/file_browser.dart` and
/// `lib/file_preview.dart` — the Files panel: listing, empty/error states,
/// and the inline text/markdown/image previews.
///
/// Fakes mirror `test/file_browser_test.dart`: a `MemoryExecutionEnv` seeded
/// with fixed files (no real file system, no timestamps rendered — tiles
/// show names and byte sizes only).
library;

import 'dart:typed_data';

import 'package:fa/file_browser.dart';
import 'package:fa/file_preview.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

import 'golden_test_helper.dart';

/// Valid 1x1 transparent PNG (same fixture as `file_browser_test.dart`).
const _pngBytes = <int>[
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
  0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
  0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
  0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
  0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
  0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
  0x42, 0x60, 0x82,
];

/// Fixed contents, fixed order: two folders (one empty) then files.
Future<MemoryExecutionEnv> _seededEnv() async {
  final env = MemoryExecutionEnv();
  await env.writeFile('aaa.txt', 'first file');
  await env.createDir('zzz_dir');
  await env.writeFile('zzz_dir/inner.txt', 'inner content');
  await env.writeFile('notes.txt', 'hello notes');
  await env.writeFile(
    'readme.md',
    '# Title\n\nSome **bold** text\n\n- one\n- two\n',
  );
  await env.writeBinaryFile('logo.png', Uint8List.fromList(_pngBytes));
  await env.createDir('empty_dir');
  return env;
}

void main() {
  group('files goldens', () {
    testWidgets('file listing with folders and files', (tester) async {
      final env = await _seededEnv();
      await pumpGolden(tester, FileBrowser(env: env), size: goldenSizeWide);
      await expectGolden(tester, 'files_listing');
    });

    testWidgets('empty folder state', (tester) async {
      final env = await _seededEnv();
      await pumpGolden(tester, FileBrowser(env: env), size: goldenSizeWide);
      await tester.tap(find.text('empty_dir'));
      await tester.pumpAndSettle();
      await expectGolden(tester, 'files_empty_folder');
    });

    testWidgets('listing failure shows the error state with retry', (
      tester,
    ) async {
      // cwd '/missing' is never created, so listing '.' reports notFound.
      final env = MemoryExecutionEnv(cwd: '/missing');
      await pumpGolden(tester, FileBrowser(env: env), size: goldenSizeWide);
      expect(find.text('Could not open folder'), findsOneWidget);
      await expectGolden(tester, 'files_error');
    });

    testWidgets('markdown preview with the Preview/Source segments', (
      tester,
    ) async {
      final env = await _seededEnv();
      await pumpGolden(tester, FileBrowser(env: env), size: goldenSizeWide);
      await tester.tap(find.text('readme.md'));
      await tester.pumpAndSettle();
      expect(find.byType(FilePreviewView), findsOneWidget);
      expect(find.text('Preview'), findsOneWidget);
      expect(find.text('Source'), findsOneWidget);
      await expectGolden(tester, 'files_preview_markdown');
    });

    testWidgets('image preview renders the in-memory PNG', (tester) async {
      final env = await _seededEnv();
      await pumpGolden(tester, FileBrowser(env: env), size: goldenSizeWide);
      // runAsync lets the real image codec complete outside the fake zone
      // (same approach as `file_browser_test.dart`); pumpAndSettle cannot be
      // used while the preview is mid-decode.
      await tester.runAsync(() async {
        await tester.tap(find.text('logo.png'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
      });
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      await expectGolden(tester, 'files_preview_image');
    });
  });
}
