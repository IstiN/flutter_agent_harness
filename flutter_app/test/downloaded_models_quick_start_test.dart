import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fa/services/agent_service.dart';
import 'package:fa/ui/widgets/downloaded_models_quick_start.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [WebLlmEngineApi] answering cache queries from a script and
/// recording loads; can hold a load open (to assert mid-load UI) or fail it.
final class _FakeWebLlmEngine implements WebLlmEngineApi {
  _FakeWebLlmEngine(this.cache);

  final Map<String, WebLlmCacheInfo> cache;
  bool available = true;
  Object? loadError;

  final progress = StreamController<WebLlmProgress>.broadcast();

  WebLlmModelPreset? loadedPreset;

  /// While non-null and incomplete, `loadModel` awaits it after emitting
  /// [pendingProgress].
  Completer<void>? loadGate;

  /// Emitted by `loadModel` before the gate.
  WebLlmProgress? pendingProgress;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<WebLlmProgress> get progressEvents => progress.stream;

  @override
  Future<void> loadModel(WebLlmModelPreset preset) async {
    final error = loadError;
    if (error != null) throw error;
    final pending = pendingProgress;
    if (pending != null) progress.add(pending);
    final gate = loadGate;
    if (gate != null) await gate.future;
    loadedPreset = preset;
  }

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
  }
}

/// Fake [TransformersJsEngineApi] (same script-and-record pattern).
final class _FakeTransformersJsEngine implements TransformersJsEngineApi {
  _FakeTransformersJsEngine(this.cache);

  final Map<String, TransformersJsCacheInfo> cache;
  bool available = true;
  Object? loadError;

  final progress = StreamController<TransformersJsProgress>.broadcast();

  TransformersJsModelPreset? loadedPreset;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<TransformersJsProgress> get progressEvents => progress.stream;

  @override
  Future<void> loadModel(TransformersJsModelPreset preset) async {
    final error = loadError;
    if (error != null) throw error;
    loadedPreset = preset;
  }

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
  }
}

Future<void> _pumpSection(
  WidgetTester tester, {
  _FakeWebLlmEngine? webLlmEngine,
  _FakeTransformersJsEngine? transformersJsEngine,
  bool? isWeb,
  Future<void> Function(AgentConfig config)? onConnect,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: DownloadedModelsQuickStart(
            webLlmEngine: webLlmEngine,
            transformersJsEngine: transformersJsEngine,
            isWeb: isWeb,
            onConnect: onConnect ?? (_) async {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('DownloadedModelsQuickStart', () {
    testWidgets('stays hidden while nothing is downloaded', (tester) async {
      await _pumpSection(
        tester,
        webLlmEngine: _FakeWebLlmEngine({}),
        transformersJsEngine: _FakeTransformersJsEngine({}),
      );
      await tester.pumpAndSettle();

      expect(find.text('Downloaded models'), findsNothing);
      expect(find.text('Use'), findsNothing);
    });

    testWidgets('stays hidden when the engines are unavailable', (
      tester,
    ) async {
      await _pumpSection(
        tester,
        webLlmEngine: _FakeWebLlmEngine({
          'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
            cached: true,
          ),
        })..available = false,
        transformersJsEngine: _FakeTransformersJsEngine({
          'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
            cached: true,
          ),
        })..available = false,
      );
      await tester.pumpAndSettle();

      expect(find.text('Downloaded models'), findsNothing);
    });

    testWidgets('lists cached WebLLM and transformers.js models with sizes', (
      tester,
    ) async {
      await _pumpSection(
        tester,
        webLlmEngine: _FakeWebLlmEngine({
          'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
            cached: true,
            bytes: 800 * 1024 * 1024,
          ),
          // An entry that is not cached must not produce a row.
          'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: false),
        }),
        transformersJsEngine: _FakeTransformersJsEngine({
          'onnx-community/gemma-4-E2B-it-ONNX': const TransformersJsCacheInfo(
            cached: true,
          ),
        }),
      );
      await tester.pumpAndSettle();

      expect(find.text('Downloaded models'), findsOneWidget);
      expect(find.text('SmolLM2 1.7B'), findsOneWidget);
      expect(find.textContaining('800 MB cached'), findsOneWidget);
      expect(find.text('Gemma 4 E2B (ONNX)'), findsOneWidget);
      // Unknown byte count falls back to the preset's size label.
      expect(find.text('~3.4 GB'), findsOneWidget);
      expect(find.text('Qwen3 4B'), findsNothing);
      expect(find.text('Use'), findsNWidgets(2));
    });

    testWidgets('a failing cache query hides its row, not the section', (
      tester,
    ) async {
      // The cache query throws (blocked storage API): the transformers.js
      // row is hidden, the WebLLM row still lists.
      final throwing = _ThrowingCacheTransformersJsEngine();
      await _pumpSection(
        tester,
        webLlmEngine: _FakeWebLlmEngine({
          'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
            cached: true,
          ),
        }),
        transformersJsEngine: throwing,
      );
      await tester.pumpAndSettle();

      expect(find.text('SmolLM2 1.7B'), findsOneWidget);
      expect(find.text('Gemma 4 E2B (ONNX)'), findsNothing);
    });

    testWidgets('Use loads the WebLLM model and connects with its config', (
      tester,
    ) async {
      final engine = _FakeWebLlmEngine({
        'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
      });
      AgentConfig? connected;
      await _pumpSection(
        tester,
        webLlmEngine: engine,
        onConnect: (config) async => connected = config,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();

      final preset = findWebLlmPreset('Qwen3-4B-q4f16_1-MLC')!;
      expect(engine.loadedPreset?.id, preset.id);
      expect(connected?.providerKind, webLlmProviderKind);
      expect(connected?.modelId, preset.id);
      expect(connected?.baseUrl, isEmpty);
      expect(connected?.apiKey, isEmpty);
      expect(connected?.contextWindow, preset.contextWindow);
      expect(connected?.maxTokens, 1024);
    });

    testWidgets('Use loads the transformers.js model and connects with its '
        'config', (tester) async {
      final engine = _FakeTransformersJsEngine({
        'onnx-community/gemma-4-E4B-it-ONNX': const TransformersJsCacheInfo(
          cached: true,
        ),
      });
      AgentConfig? connected;
      await _pumpSection(
        tester,
        transformersJsEngine: engine,
        onConnect: (config) async => connected = config,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();

      final preset = findTransformersJsPreset(
        'onnx-community/gemma-4-E4B-it-ONNX',
      )!;
      expect(engine.loadedPreset?.id, preset.id);
      expect(connected?.providerKind, transformersJsProviderKind);
      expect(connected?.modelId, preset.id);
      expect(connected?.baseUrl, isEmpty);
      expect(connected?.apiKey, isEmpty);
      expect(connected?.contextWindow, preset.contextWindow);
      expect(connected?.maxTokens, 1024);
    });

    testWidgets('shows progress mid-load and disables the Use buttons', (
      tester,
    ) async {
      final engine =
          _FakeWebLlmEngine({
              'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
                cached: true,
              ),
            })
            ..pendingProgress = const WebLlmProgress(
              fraction: 0.6,
              text: 'Compiling shaders… 60%',
            )
            ..loadGate = Completer<void>();
      var connected = false;
      await _pumpSection(
        tester,
        webLlmEngine: engine,
        onConnect: (_) async => connected = true,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Compiling shaders… 60%'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.6);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(connected, isFalse);

      engine.loadGate!.complete();
      await tester.pumpAndSettle();

      expect(connected, isTrue);
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a failed load surfaces the engine error', (tester) async {
      final engine = _FakeWebLlmEngine({
        'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
          cached: true,
        ),
      })..loadError = StateError('no WebGPU support');
      var connected = false;
      await _pumpSection(
        tester,
        webLlmEngine: engine,
        onConnect: (_) async => connected = true,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();

      expect(find.textContaining('no WebGPU support'), findsOneWidget);
      expect(connected, isFalse);
      expect(engine.loadedPreset, isNull);
    });
  });
}

/// A transformers.js engine whose cache query throws — the best-effort
/// `_queryCache` guard must hide the row without breaking the scan.
final class _ThrowingCacheTransformersJsEngine
    implements TransformersJsEngineApi {
  @override
  bool get isAvailable => true;

  @override
  String? get loadedModelId => null;

  @override
  Stream<TransformersJsProgress> get progressEvents =>
      const Stream<TransformersJsProgress>.empty();

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
      throw StateError('storage blocked');

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}
