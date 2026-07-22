import 'package:flutter/material.dart';
import 'package:fa/gemma/gemma_cache_section.dart';
import 'package:fa/gemma/gemma_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake engine with a scripted repository: [installed] maps install file
/// names to recorded byte sizes. [uninstall] mirrors the real engine's
/// documented active-clear sequence in [calls] (close the loaded model and
/// clear the plugin's persisted active identity, then delete metadata +
/// files) — the actual sequence lives in `GemmaService.uninstall`, which
/// host tests cannot drive; here it documents the contract the section
/// relies on.
final class _FakeEngine implements GemmaEngineApi {
  _FakeEngine({this.isWeb = false, Map<String, int?>? installed})
    : installed = installed ?? {};

  final bool isWeb;

  /// Repository contents: install filename → recorded byte size.
  final Map<String, int?> installed;

  /// Uninstall call log (see the class doc).
  final List<String> calls = [];

  bool available = true;
  GemmaModelPreset? loadedPreset;
  Object? uninstallError;

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
    final error = uninstallError;
    if (error != null) throw error;
    final loaded = loadedPreset;
    if (loaded != null && loaded.filenameFor(isWeb: isWeb) == filename) {
      calls.add('unload');
      calls.add('clearActiveIdentity');
      loadedPreset = null;
    }
    calls.add('uninstall:$filename');
    installed.remove(filename);
  }
}

Future<void> _pumpSection(
  WidgetTester tester,
  _FakeEngine engine, {
  bool isWeb = false,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: GemmaCacheSection(engine: engine, isWeb: isWeb),
        ),
      ),
    ),
  );
}

void main() {
  group('GemmaCacheSection', () {
    testWidgets('lists installed presets with sizes; an absent preset shows '
        'as not downloaded', (tester) async {
      final engine = _FakeEngine(
        installed: {'gemma-4-E2B-it.litertlm': 2576980378},
      );
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      expect(find.text('On-device models (Gemma)'), findsOneWidget);
      expect(find.text('Gemma 4 E2B'), findsOneWidget);
      // Recorded byte count is formatted next to the size label.
      expect(find.text('~2.4 GB · 2.4 GB cached'), findsOneWidget);
      // Repository-absent preset: listed as not installed, no delete.
      expect(find.text('Gemma 4 E4B'), findsOneWidget);
      expect(find.text('Not downloaded · ~4.3 GB'), findsOneWidget);
      final e4bDelete = tester.widget<IconButton>(
        find.descendant(
          of: find.ancestor(
            of: find.text('Gemma 4 E4B'),
            matching: find.byType(ListTile),
          ),
          matching: find.byType(IconButton),
        ),
      );
      expect(e4bDelete.onPressed, isNull);
    });

    testWidgets('shows an empty message when nothing is installed', (
      tester,
    ) async {
      await _pumpSection(tester, _FakeEngine());
      await tester.pumpAndSettle();

      expect(find.text('No models downloaded yet.'), findsOneWidget);
      expect(find.text('Gemma 4 E2B'), findsNothing);
    });

    testWidgets('on an unsupported platform it collapses to a note', (
      tester,
    ) async {
      final engine = _FakeEngine()..available = false;
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('available in the iOS/Android builds only'),
        findsOneWidget,
      );
      expect(find.text('On-device models (Gemma)'), findsNothing);
    });

    testWidgets('web resolves the distinct -web filename for state and '
        'delete', (tester) async {
      final engine = _FakeEngine(
        isWeb: true,
        installed: {'gemma-4-E2B-it-web.litertlm': 2008432640},
      );
      await _pumpSection(tester, engine, isWeb: true);
      await tester.pumpAndSettle();

      // The web build is installed under the web file name, with the web
      // (smaller) size label.
      expect(find.text('~1.9 GB · 1.9 GB cached'), findsOneWidget);
      expect(find.text('Not downloaded · ~2.8 GB'), findsOneWidget);

      await tester.tap(find.byTooltip('Delete Gemma 4 E2B'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Gemma 4 E2B?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // The engine is asked to delete the web file name, never the mobile
      // one.
      expect(engine.calls, ['uninstall:gemma-4-E2B-it-web.litertlm']);
      expect(find.text('Deleted Gemma 4 E2B.'), findsOneWidget);
      expect(find.text('No models downloaded yet.'), findsOneWidget);
    });

    testWidgets('lists the stale mobile-named file as a deletable orphan '
        'on web', (tester) async {
      final engine = _FakeEngine(
        isWeb: true,
        installed: {
          'gemma-4-E2B-it-web.litertlm': 2008432640,
          // The broken pre-fix install: mobile bytes in the browser's OPFS.
          'gemma-4-E2B-it.litertlm': 2576980378,
        },
      );
      await _pumpSection(tester, engine, isWeb: true);
      await tester.pumpAndSettle();

      expect(find.text('gemma-4-E2B-it.litertlm'), findsOneWidget);
      expect(
        find.text('Leftover mobile build — not used on web · 2.4 GB'),
        findsOneWidget,
      );

      await tester.tap(find.byTooltip('Delete gemma-4-E2B-it.litertlm'));
      await tester.pumpAndSettle();
      // The orphan confirm dialog does not promise a re-download.
      expect(find.text('Delete gemma-4-E2B-it.litertlm?'), findsOneWidget);
      expect(
        find.textContaining('Installed models are not affected'),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(engine.calls, ['uninstall:gemma-4-E2B-it.litertlm']);
      // The proper web install is untouched.
      expect(engine.installed.keys, ['gemma-4-E2B-it-web.litertlm']);
      expect(find.text('~1.9 GB · 1.9 GB cached'), findsOneWidget);
      expect(find.text('Deleted gemma-4-E2B-it.litertlm.'), findsOneWidget);
    });

    testWidgets('deleting the loaded model runs the active-clear sequence '
        'and says so', (tester) async {
      final engine = _FakeEngine(installed: {'gemma-4-E2B-it.litertlm': null})
        ..loadedPreset = gemmaModelPresets.first;
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete Gemma 4 E2B'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      // Close the in-memory model and clear the persisted active identity
      // BEFORE the files go away (mirrored from GemmaService.uninstall).
      expect(engine.calls, [
        'unload',
        'clearActiveIdentity',
        'uninstall:gemma-4-E2B-it.litertlm',
      ]);
      expect(engine.loadedModelId, isNull);
      expect(
        find.textContaining('downloads again on next use'),
        findsOneWidget,
      );
    });

    testWidgets('deleting a non-loaded model skips the active-clear', (
      tester,
    ) async {
      final engine = _FakeEngine(
        installed: {
          'gemma-4-E2B-it.litertlm': null,
          'gemma-4-E4B-it.litertlm': null,
        },
      )..loadedPreset = gemmaModelPresets.first;
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete Gemma 4 E4B'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(engine.calls, ['uninstall:gemma-4-E4B-it.litertlm']);
      expect(engine.loadedModelId, gemmaModelPresets.first.id);
      expect(find.text('Deleted Gemma 4 E4B.'), findsOneWidget);
    });

    testWidgets('cancelling the confirm dialog keeps the model', (
      tester,
    ) async {
      final engine = _FakeEngine(installed: {'gemma-4-E2B-it.litertlm': null});
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete Gemma 4 E2B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(engine.calls, isEmpty);
      expect(find.text('Gemma 4 E2B'), findsOneWidget);
    });

    testWidgets('a failed uninstall surfaces the error and keeps the entry', (
      tester,
    ) async {
      final engine = _FakeEngine(installed: {'gemma-4-E2B-it.litertlm': null})
        ..uninstallError = StateError('OPFS entry is locked');
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Delete Gemma 4 E2B'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Failed to delete Gemma 4 E2B'),
        findsOneWidget,
      );
      expect(find.textContaining('OPFS entry is locked'), findsOneWidget);
      expect(engine.installed.keys, ['gemma-4-E2B-it.litertlm']);
      expect(find.text('Gemma 4 E2B'), findsOneWidget);
    });
  });
}
