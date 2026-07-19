import 'package:flutter/material.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_cache_section.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake engine answering cache queries from a script and recording deletes;
/// mirrors the real web service's loaded-model reset on delete.
final class _FakeEngine implements TransformersJsEngineApi {
  _FakeEngine(this.cache);

  final Map<String, TransformersJsCacheInfo> cache;
  final deleted = <String>[];

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
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async =>
      cache[modelId];

  @override
  Future<void> deleteCachedModel(String modelId) async {
    deleted.add(modelId);
    cache.remove(modelId);
    if (loadedId == modelId) loadedId = null;
  }
}

Future<void> _pumpSection(WidgetTester tester, _FakeEngine engine) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: TransformersJsCacheSection(engine: engine),
        ),
      ),
    ),
  );
}

void main() {
  group('TransformersJsCacheSection', () {
    testWidgets('lists cached models with their sizes', (tester) async {
      final engine = _FakeEngine({
        'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
          cached: true,
          bytes: 3400000000,
        ),
      });
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      expect(find.text('Downloaded models (transformers.js)'), findsOneWidget);
      expect(find.text('Gemma 4 E2B (ONNX)'), findsOneWidget);
      // Known byte count is formatted next to the preset's size label.
      expect(find.textContaining('3.2 GB cached'), findsOneWidget);
    });

    testWidgets('shows an empty message when nothing is cached', (
      tester,
    ) async {
      await _pumpSection(tester, _FakeEngine({}));
      await tester.pumpAndSettle();

      expect(find.text('No models downloaded yet.'), findsOneWidget);
    });

    testWidgets('off the web it collapses to a web-build-only note', (
      tester,
    ) async {
      final engine = _FakeEngine({})..available = false;
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('available in the web build only'),
        findsOneWidget,
      );
      expect(find.text('Downloaded models (transformers.js)'), findsNothing);
    });

    testWidgets('delete calls the engine seam and refreshes the list', (
      tester,
    ) async {
      final engine = _FakeEngine({
        'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
          cached: true,
        ),
      });
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      // Confirm dialog names the model.
      expect(find.text('Delete Gemma 4 E2B (ONNX)?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(engine.deleted, ['onnx-community/gemma-4-E2B-it-ONNX']);
      expect(find.text('Gemma 4 E2B (ONNX)'), findsNothing);
      expect(find.text('Deleted Gemma 4 E2B (ONNX).'), findsOneWidget);
    });

    testWidgets('deleting the loaded model resets the loaded state and says '
        'so', (tester) async {
      final engine = _FakeEngine({
        'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
          cached: true,
        ),
      })..loadedId = 'onnx-community/gemma-4-E2B-it-ONNX';
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(engine.loadedId, isNull);
      expect(
        find.textContaining('downloads again on next use'),
        findsOneWidget,
      );
    });

    testWidgets('cancelling the confirm dialog keeps the model', (
      tester,
    ) async {
      final engine = _FakeEngine({
        'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
          cached: true,
        ),
      });
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(engine.deleted, isEmpty);
      expect(find.text('Gemma 4 E2B (ONNX)'), findsOneWidget);
    });
  });
}
