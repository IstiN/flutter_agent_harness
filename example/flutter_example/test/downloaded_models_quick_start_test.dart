import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/downloaded_models_quick_start.dart';
import 'package:flutter_agent_example/gemma/gemma_types.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_types.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
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

/// Fake [GemmaEngineApi] answering the repository scan from a script and
/// recording install/load calls.
final class _FakeGemmaEngine implements GemmaEngineApi {
  _FakeGemmaEngine(this.installed);

  final List<GemmaInstalledModel> installed;
  bool available = true;
  Object? scanError;

  final progress = StreamController<GemmaProgress>.broadcast();

  GemmaModelPreset? installedPreset;
  GemmaModelPreset? loadedPreset;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<GemmaProgress> get progressEvents => progress.stream;

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async => true;

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {
    installedPreset = preset;
  }

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
  Future<void> unload() async {}

  @override
  Future<List<GemmaInstalledModel>> installedModels() async {
    final error = scanError;
    if (error != null) throw error;
    return installed;
  }

  @override
  Future<void> uninstall(String filename) async {}
}

Future<void> _pumpSection(
  WidgetTester tester, {
  _FakeWebLlmEngine? webLlmEngine,
  _FakeGemmaEngine? gemmaEngine,
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
            gemmaEngine: gemmaEngine,
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
        gemmaEngine: _FakeGemmaEngine(const []),
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
        gemmaEngine: _FakeGemmaEngine(const [
          GemmaInstalledModel(filename: 'gemma-4-E2B-it.litertlm'),
        ])..available = false,
      );
      await tester.pumpAndSettle();

      expect(find.text('Downloaded models'), findsNothing);
    });

    testWidgets('lists cached WebLLM and transformers.js models with sizes', (
      tester,
    ) async {
      await _pumpSection(
        tester,
        gemmaEngine: _FakeGemmaEngine(const []),
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

    testWidgets('lists installed Gemma models (mobile file names)', (
      tester,
    ) async {
      await _pumpSection(
        tester,
        isWeb: false,
        gemmaEngine: _FakeGemmaEngine(const [
          GemmaInstalledModel(
            filename: 'gemma-4-E2B-it.litertlm',
            sizeBytes: 2000 * 1024 * 1024,
          ),
          // A stale orphan entry (no matching preset) produces no row.
          GemmaInstalledModel(filename: 'some-old-model.litertlm'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Gemma 4 E2B'), findsOneWidget);
      expect(find.textContaining('2.0 GB cached'), findsOneWidget);
      expect(find.text('Gemma 4 E4B'), findsNothing);
      expect(find.text('some-old-model.litertlm'), findsNothing);
    });

    testWidgets('a failed Gemma repository scan hides its rows, not the '
        'section', (tester) async {
      await _pumpSection(
        tester,
        webLlmEngine: _FakeWebLlmEngine({
          'SmolLM2-1.7B-Instruct-q4f16_1-MLC': const WebLlmCacheInfo(
            cached: true,
          ),
        }),
        gemmaEngine: _FakeGemmaEngine(const [])
          ..scanError = StateError('OPFS locked'),
      );
      await tester.pumpAndSettle();

      expect(find.text('SmolLM2 1.7B'), findsOneWidget);
      expect(find.text('Gemma 4 E2B'), findsNothing);
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
        gemmaEngine: _FakeGemmaEngine(const []),
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

    testWidgets('Use marks the Gemma model active, loads it, and connects', (
      tester,
    ) async {
      final engine = _FakeGemmaEngine(const [
        GemmaInstalledModel(filename: 'gemma-4-E4B-it.litertlm'),
      ]);
      AgentConfig? connected;
      await _pumpSection(
        tester,
        isWeb: false,
        gemmaEngine: engine,
        onConnect: (config) async => connected = config,
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Use'));
      await tester.pumpAndSettle();

      final preset = findGemmaPreset('gemma-4-E4B-it')!;
      expect(engine.installedPreset?.id, preset.id);
      expect(engine.loadedPreset?.id, preset.id);
      expect(connected?.providerKind, gemmaProviderKind);
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
        gemmaEngine: _FakeGemmaEngine(const []),
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
        gemmaEngine: _FakeGemmaEngine(const []),
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
        gemmaEngine: _FakeGemmaEngine(const []),
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
