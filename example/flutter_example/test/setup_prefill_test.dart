import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/gemma/gemma_types.dart';
import 'package:flutter_agent_example/last_connection.dart';
import 'package:flutter_agent_example/main.dart';
import 'package:flutter_agent_example/provider_registry.dart';
import 'package:flutter_agent_example/settings.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_types.dart';
import 'package:flutter_agent_example/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:flutter_test/flutter_test.dart';

/// Fake [WebLlmEngineApi] answering cache queries from a script (the form's
/// prefill verification is all these tests exercise).
final class _FakeWebLlmEngine implements WebLlmEngineApi {
  _FakeWebLlmEngine(this.cache);

  final Map<String, WebLlmCacheInfo> cache;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => null;

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
  Future<void> deleteCachedModel(String modelId) async {}
}

/// Fake [GemmaEngineApi] answering the installed-models scan from a script.
final class _FakeGemmaEngine implements GemmaEngineApi {
  _FakeGemmaEngine(this.installed);

  final List<GemmaInstalledModel> installed;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => null;

  @override
  Stream<GemmaProgress> get progressEvents => const Stream.empty();

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async => false;

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {}

  @override
  Future<void> loadModel(GemmaModelPreset preset) async {}

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
  Future<List<GemmaInstalledModel>> installedModels() async => installed;

  @override
  Future<void> uninstall(String filename) async {}
}

/// Fake [TransformersJsEngineApi] answering cache queries from a script.
final class _FakeTransformersJsEngine implements TransformersJsEngineApi {
  _FakeTransformersJsEngine(this.cache);

  final Map<String, TransformersJsCacheInfo> cache;
  bool available = true;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => null;

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
  Future<void> deleteCachedModel(String modelId) async {}
}

TextField _field(WidgetTester tester, String label) {
  return tester.widget<TextField>(find.widgetWithText(TextField, label));
}

Future<void> _pumpForm(
  WidgetTester tester, {
  ProviderRegistry? registry,
  LastConnection? initialConnection,
  _FakeWebLlmEngine? webLlmEngine,
  _FakeGemmaEngine? gemmaEngine,
  _FakeTransformersJsEngine? transformersJsEngine,
  bool? isWeb,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AgentSettingsForm(
            registry: registry ?? ProviderRegistry.inMemory(),
            initialConnection: initialConnection,
            webLlmEngine: webLlmEngine,
            gemmaEngine: gemmaEngine,
            transformersJsEngine: transformersJsEngine,
            isWeb: isWeb,
            onConnect: (_) async {},
          ),
        ),
      ),
    ),
  );
}

/// Opens the provider dropdown and picks the entry labelled [label].
Future<void> _selectProvider(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<Object>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  group('Last-connection prefill', () {
    testWidgets('a hosted connection pre-selects provider, model and URL; '
        'the env-seeded key is untouched', (tester) async {
      dotenv.loadFromString(envString: 'OPENROUTER_API_KEY=sk-env-seeded');
      addTearDown(dotenv.clean);
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: 'openai-completions',
          modelId: 'my-ollama-model',
          baseUrl: 'https://ollama.com/v1',
        ),
      );

      expect(find.text('Ollama'), findsOneWidget);
      expect(_field(tester, 'Model id').controller!.text, 'my-ollama-model');
      expect(
        _field(tester, 'Base URL').controller!.text,
        'https://ollama.com/v1',
      );
      // Keys are never persisted; the env-provided one survives prefill.
      expect(_field(tester, 'API key').controller!.text, 'sk-env-seeded');
    });

    testWidgets('an unknown hosted endpoint pre-selects the custom preset '
        'with an editable URL', (tester) async {
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: 'openai-completions',
          modelId: 'acme-1',
          baseUrl: 'https://acme.example/v1',
        ),
      );

      expect(find.text('Custom'), findsOneWidget);
      expect(_field(tester, 'Base URL').enabled, isTrue);
      expect(
        _field(tester, 'Base URL').controller!.text,
        'https://acme.example/v1',
      );
      expect(_field(tester, 'Model id').controller!.text, 'acme-1');
    });

    testWidgets('a saved custom provider matching the endpoint is '
        're-selected', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpForm(
        tester,
        registry: registry,
        initialConnection: const LastConnection(
          providerKind: 'openai-completions',
          modelId: 'acme-1',
          baseUrl: 'https://acme.example/v1',
        ),
      );

      expect(find.text('Acme'), findsOneWidget);
      // The registry match (not the bare custom preset) brings edit/delete.
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('a cached WebLLM model is pre-selected without a note', (
      tester,
    ) async {
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: webLlmProviderKind,
          modelId: 'Qwen3-4B-q4f16_1-MLC',
          webllmPresetId: 'Qwen3-4B-q4f16_1-MLC',
        ),
        webLlmEngine: _FakeWebLlmEngine({
          'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
        }),
      );
      await tester.pumpAndSettle();

      expect(find.text('On-device (WebLLM)'), findsOneWidget);
      expect(find.text('Qwen3 4B · ~2.8 GB'), findsOneWidget);
      expect(find.textContaining('previously used model'), findsNothing);
    });

    testWidgets('a WebLLM model deleted meanwhile falls back to the default '
        'preset with a note', (tester) async {
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: webLlmProviderKind,
          modelId: 'Qwen3-4B-q4f16_1-MLC',
          webllmPresetId: 'Qwen3-4B-q4f16_1-MLC',
        ),
        webLlmEngine: _FakeWebLlmEngine({
          // The cache query answers "gone".
          'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: false),
        }),
      );
      await tester.pumpAndSettle();

      // The provider stays pre-selected…
      expect(find.text('On-device (WebLLM)'), findsOneWidget);
      // …the model falls back to the default preset…
      expect(find.text('SmolLM2 1.7B · ~1.8 GB'), findsOneWidget);
      // …and a small note says why.
      expect(find.textContaining('previously used model'), findsOneWidget);
      expect(find.textContaining('was removed'), findsOneWidget);
      expect(find.textContaining('Qwen3 4B'), findsOneWidget);
    });

    testWidgets('an engine that cannot answer keeps the stored model and '
        'shows no note', (tester) async {
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: webLlmProviderKind,
          modelId: 'Qwen3-4B-q4f16_1-MLC',
          webllmPresetId: 'Qwen3-4B-q4f16_1-MLC',
        ),
        // Unavailable engine → cache state unknown.
        webLlmEngine: _FakeWebLlmEngine({})..available = false,
      );
      await tester.pumpAndSettle();

      expect(find.text('Qwen3 4B · ~2.8 GB'), findsOneWidget);
      expect(find.textContaining('previously used model'), findsNothing);
    });

    testWidgets('an unknown WebLLM preset id keeps the env defaults', (
      tester,
    ) async {
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: webLlmProviderKind,
          modelId: 'no-such-model-MLC',
          webllmPresetId: 'no-such-model-MLC',
        ),
        webLlmEngine: _FakeWebLlmEngine({}),
      );

      expect(find.text('OpenRouter'), findsOneWidget);
    });

    testWidgets('an installed Gemma model is pre-selected on mobile', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: gemmaProviderKind,
          modelId: 'gemma-4-E4B-it',
          gemmaPresetId: 'gemma-4-E4B-it',
        ),
        gemmaEngine: _FakeGemmaEngine(const [
          GemmaInstalledModel(filename: 'gemma-4-E4B-it.litertlm'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('On-device (Gemma)'), findsOneWidget);
      expect(find.text('Gemma 4 E4B · ~4.3 GB'), findsOneWidget);
      expect(find.textContaining('previously used model'), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a Gemma model uninstalled meanwhile falls back with a note', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: gemmaProviderKind,
          modelId: 'gemma-4-E4B-it',
          gemmaPresetId: 'gemma-4-E4B-it',
        ),
        gemmaEngine: _FakeGemmaEngine(const []),
      );
      await tester.pumpAndSettle();

      expect(find.text('On-device (Gemma)'), findsOneWidget);
      expect(find.text('Gemma 4 E2B · ~2.4 GB'), findsOneWidget);
      expect(find.textContaining('previously used model'), findsOneWidget);
      expect(find.textContaining('was removed'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a Gemma record is ignored where the provider is hidden', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: gemmaProviderKind,
          modelId: 'gemma-4-E2B-it',
          gemmaPresetId: 'gemma-4-E2B-it',
        ),
        gemmaEngine: _FakeGemmaEngine(const [
          GemmaInstalledModel(filename: 'gemma-4-E2B-it.litertlm'),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('OpenRouter'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('a cached transformers.js model is pre-selected on web', (
      tester,
    ) async {
      await _pumpForm(
        tester,
        isWeb: true,
        initialConnection: const LastConnection(
          providerKind: transformersJsProviderKind,
          modelId: 'onnx-community/gemma-4-E4B-it-ONNX',
          transformersJsPresetId: 'onnx-community/gemma-4-E4B-it-ONNX',
        ),
        transformersJsEngine: _FakeTransformersJsEngine({
          'onnx-community/gemma-4-E4B-it-ONNX': const TransformersJsCacheInfo(
            cached: true,
          ),
        }),
      );
      await tester.pumpAndSettle();

      expect(find.text('On-device (Gemma, transformers.js)'), findsOneWidget);
      expect(find.text('Gemma 4 E4B (ONNX) · ~5.2 GB'), findsOneWidget);
      expect(find.textContaining('previously used model'), findsNothing);
    });

    testWidgets('a transformers.js model deleted meanwhile falls back with a '
        'note', (tester) async {
      await _pumpForm(
        tester,
        isWeb: true,
        initialConnection: const LastConnection(
          providerKind: transformersJsProviderKind,
          modelId: 'onnx-community/gemma-4-E4B-it-ONNX',
          transformersJsPresetId: 'onnx-community/gemma-4-E4B-it-ONNX',
        ),
        transformersJsEngine: _FakeTransformersJsEngine({
          'onnx-community/gemma-4-E4B-it-ONNX': const TransformersJsCacheInfo(
            cached: false,
          ),
        }),
      );
      await tester.pumpAndSettle();

      expect(find.text('On-device (Gemma, transformers.js)'), findsOneWidget);
      expect(find.text('Gemma 4 E2B (ONNX) · ~3.4 GB'), findsOneWidget);
      expect(find.textContaining('previously used model'), findsOneWidget);
      expect(find.textContaining('was removed'), findsOneWidget);
    });

    testWidgets('prefill survives a rebuild (the reload path)', (tester) async {
      const connection = LastConnection(
        providerKind: webLlmProviderKind,
        modelId: 'Qwen3-4B-q4f16_1-MLC',
        webllmPresetId: 'Qwen3-4B-q4f16_1-MLC',
      );
      final engine = _FakeWebLlmEngine({
        'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: true),
      });
      await _pumpForm(
        tester,
        initialConnection: connection,
        webLlmEngine: engine,
      );
      await tester.pumpAndSettle();
      expect(find.text('Qwen3 4B · ~2.8 GB'), findsOneWidget);

      // Tear the tree down and rebuild a fresh form, as a reload would.
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await _pumpForm(
        tester,
        initialConnection: connection,
        webLlmEngine: engine,
      );
      await tester.pumpAndSettle();

      expect(find.text('On-device (WebLLM)'), findsOneWidget);
      expect(find.text('Qwen3 4B · ~2.8 GB'), findsOneWidget);
    });

    testWidgets('switching providers clears the stale-model note', (
      tester,
    ) async {
      await _pumpForm(
        tester,
        initialConnection: const LastConnection(
          providerKind: webLlmProviderKind,
          modelId: 'Qwen3-4B-q4f16_1-MLC',
          webllmPresetId: 'Qwen3-4B-q4f16_1-MLC',
        ),
        webLlmEngine: _FakeWebLlmEngine({
          'Qwen3-4B-q4f16_1-MLC': const WebLlmCacheInfo(cached: false),
        }),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('previously used model'), findsOneWidget);

      await _selectProvider(tester, 'Ollama');
      expect(find.textContaining('previously used model'), findsNothing);
    });
  });

  group('SetupScreen last-connection persistence', () {
    testWidgets('a successful connect is saved and pre-selects the form '
        'after a reload; the key is never persisted', (tester) async {
      // AgentService.create reads the real .env file through dart:io; real
      // IO futures never complete inside the fake test zone, so point the
      // current directory at an empty one (no .env → no real IO).
      await IOOverrides.runZoned(() async {
        final env = MemoryExecutionEnv();
        final store = await LastConnectionStore.load(env);
        await tester.pumpWidget(
          MaterialApp(
            home: SetupScreen(
              env: env,
              registry: ProviderRegistry.inMemory(),
              lastConnectionStore: store,
              // Engine fakes keep the quick-start scan off the real plugin
              // singleton (its method channel has no answer in host tests).
              webLlmEngine: _FakeWebLlmEngine({}),
              gemmaEngine: _FakeGemmaEngine(const []),
              transformersJsEngine: _FakeTransformersJsEngine({}),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Connect via Ollama so the prefill differs from the defaults.
        await _selectProvider(tester, 'Ollama');
        await tester.enterText(
          find.widgetWithText(TextField, 'API key'),
          'sk-reload-test',
        );
        await tester.ensureVisible(find.text('Start chat'));
        await tester.tap(find.text('Start chat'));
        await tester.pumpAndSettle();

        // Connected: the chat screen replaced the setup screen…
        expect(find.byType(ChatScreen), findsOneWidget);
        // …and the connection was saved (non-secret parts only).
        final connection = store.connection;
        expect(connection, isNotNull);
        expect(connection!.providerKind, 'openai-completions');
        expect(connection.modelId, 'gpt-oss:120b');
        expect(connection.baseUrl, 'https://ollama.com/v1');
        final raw = (await env.readTextFile(
          '${env.cwd}/${LastConnectionStore.fileName}',
        )).valueOrNull!;
        expect(raw, isNot(contains('sk-reload-test')));

        // Simulate a reload: a fresh store over the same env, a fresh screen.
        // The new root key forces a full tree replacement — without it the
        // surviving Navigator keeps showing the chat route (`home` only
        // seeds the initial route stack).
        final reloaded = await LastConnectionStore.load(env);
        await tester.pumpWidget(
          MaterialApp(
            key: const ValueKey('reload'),
            home: SetupScreen(
              env: env,
              registry: ProviderRegistry.inMemory(),
              lastConnectionStore: reloaded,
              webLlmEngine: _FakeWebLlmEngine({}),
              gemmaEngine: _FakeGemmaEngine(const []),
              transformersJsEngine: _FakeTransformersJsEngine({}),
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Connect to fah'), findsOneWidget);
        expect(find.text('Ollama'), findsOneWidget);
        expect(_field(tester, 'Model id').controller!.text, 'gpt-oss:120b');
        // The key is empty again — session-only by policy.
        expect(_field(tester, 'API key').controller!.text, isEmpty);
      }, getCurrentDirectory: () => Directory('/nonexistent-fah-test-dir'));
    });
  });
}
