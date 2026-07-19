import 'package:flutter/material.dart';
import 'package:flutter_agent_example/webllm/webllm_cache_section.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake engine answering cache queries from a script and recording deletes;
/// mirrors the real web service's loaded-model reset on delete.
final class _FakeEngine implements WebLlmEngineApi {
  _FakeEngine(this.cache);

  final Map<String, WebLlmCacheInfo> cache;
  final deleted = <String>[];

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
    deleted.add(modelId);
    cache.remove(modelId);
    if (loadedId == modelId) loadedId = null;
  }
}

Future<void> _pumpSection(WidgetTester tester, _FakeEngine engine) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(child: WebLlmCacheSection(engine: engine)),
      ),
    ),
  );
}

void main() {
  group('WebLlmCacheSection', () {
    testWidgets('lists cached models with their sizes', (tester) async {
      final engine = _FakeEngine({
        'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
          cached: true,
          bytes: 800 * 1024 * 1024,
        ),
        'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
      });
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      expect(find.text('Downloaded models'), findsOneWidget);
      expect(find.text('SmolLM2 1.7B'), findsOneWidget);
      expect(find.text('Qwen3 4B'), findsOneWidget);
      // Known byte count is formatted; unknown falls back to the size label.
      expect(find.textContaining('800 MB cached'), findsOneWidget);
      expect(find.text('~2.8 GB'), findsOneWidget);
      // Uncached presets are not listed.
      expect(find.text('Llama 3.2 3B'), findsNothing);
    });

    testWidgets('shows an empty message when nothing is cached', (
      tester,
    ) async {
      await _pumpSection(tester, _FakeEngine({}));
      await tester.pumpAndSettle();

      expect(find.text('No models downloaded yet.'), findsOneWidget);
    });

    testWidgets('off the web it collapses to an OS/app-storage note', (
      tester,
    ) async {
      final engine = _FakeEngine({})..available = false;
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      expect(
        find.textContaining('managed by the OS/app storage'),
        findsOneWidget,
      );
      expect(find.text('Downloaded models'), findsNothing);
    });

    testWidgets('delete calls the engine seam and refreshes the list', (
      tester,
    ) async {
      final engine = _FakeEngine({
        'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
          cached: true,
          bytes: 1000,
        ),
        'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
      });
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline).first);
      await tester.pumpAndSettle();
      // Confirm dialog names the model.
      expect(find.text('Delete SmolLM2 1.7B?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(engine.deleted, ['SmolLM2-1.7B-Instruct-q4f16_1-MLC']);
      expect(find.text('SmolLM2 1.7B'), findsNothing);
      expect(find.text('Qwen3 4B'), findsOneWidget);
      expect(find.text('Deleted SmolLM2 1.7B.'), findsOneWidget);
    });

    testWidgets('deleting the loaded model resets the loaded state and says '
        'so', (tester) async {
      final engine = _FakeEngine({
        'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
      })..loadedId = 'Qwen3-4B-q4f16_1-MLC';
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
        'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
      });
      await _pumpSection(tester, engine);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(engine.deleted, isEmpty);
      expect(find.text('Qwen3 4B'), findsOneWidget);
    });
  });
}
