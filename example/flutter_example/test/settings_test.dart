import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/gemma/gemma_types.dart';
import 'package:flutter_agent_example/main.dart';
import 'package:flutter_agent_example/provider_registry.dart';
import 'package:flutter_agent_example/settings.dart';
import 'package:flutter_agent_example/transformers_js/transformers_js_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_test/flutter_test.dart';

StreamFunction _singleTextResponse(String text) {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    final message = AssistantMessage(
      content: [TextContent(text: text)],
      api: model.api,
      provider: model.provider,
      model: model.id,
      usage: Usage.zero,
      stopReason: StopReason.stop,
      timestamp: DateTime.now(),
    );
    stream.push(DoneEvent(reason: StopReason.stop, message: message));
    stream.end();
    return stream;
  };
}

AgentService _fakeService() {
  return AgentService(
    agent: Agent(
      model: Model(
        id: 'test-model',
        api: 'test-api',
        provider: 'test',
        baseUrl: 'https://example.com',
        contextWindow: 100000,
        maxTokens: 4096,
      ),
      systemPrompt: 'You are fah.',
      streamFunction: _singleTextResponse('hi'),
      toolRegistry: ToolRegistry(const []),
    ),
    env: MemoryExecutionEnv(),
    sessionsRoot: '/sessions',
  );
}

TextField _field(WidgetTester tester, String label) {
  return tester.widget<TextField>(find.widgetWithText(TextField, label));
}

/// Opens the provider dropdown and picks the entry labelled [label].
Future<void> _selectProvider(WidgetTester tester, String label) async {
  await tester.tap(find.byType(DropdownButtonFormField<Object>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

/// Taps the form's primary button, scrolling it into view first (the form
/// can overflow small test surfaces).
Future<void> _tapConnect(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.text(label));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pump();
}

/// A TextField inside the provider add/edit dialog.
Finder _editorField(String label) {
  return find.descendant(
    of: find.byType(ProviderEditorDialog),
    matching: find.widgetWithText(TextField, label),
  );
}

Future<void> _pumpForm(
  WidgetTester tester,
  ProviderRegistry registry, {
  Future<void> Function(AgentConfig config)? onConnect,
  GemmaEngineApi? gemmaEngine,
  TransformersJsEngineApi? transformersJsEngine,
  bool? isWeb,
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AgentSettingsForm(
            registry: registry,
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

/// Fake [TransformersJsEngineApi] for the settings form: records load calls,
/// emits scripted progress reports, and can hold the load open (to assert
/// mid-download UI) or fail it.
final class FakeTransformersJsEngine implements TransformersJsEngineApi {
  var available = true;
  Object? loadError;

  /// Standard (async) broadcast, like the real engine: progress lands on a
  /// later microtask, so tests pump to let it render.
  final progress = StreamController<TransformersJsProgress>.broadcast();

  TransformersJsModelPreset? loadedPreset;

  /// While non-null and incomplete, `loadModel` awaits it after emitting
  /// [pendingProgress].
  Completer<void>? loadGate;

  /// Emitted by `loadModel` before the gate.
  TransformersJsProgress? pendingProgress;

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
    final pending = pendingProgress;
    if (pending != null) progress.add(pending);
    final gate = loadGate;
    if (gate != null) await gate.future;
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
  Future<TransformersJsCacheInfo?> modelCacheInfo(String modelId) async => null;

  @override
  Future<void> deleteCachedModel(String modelId) async {}
}

/// Fake [GemmaEngineApi] for the settings form: records install/load calls,
/// emits scripted progress reports, and can hold the install open (to assert
/// mid-download UI) or fail it.
final class FakeGemmaEngine implements GemmaEngineApi {
  var available = true;
  Object? installError;

  /// Standard (async) broadcast, like the real engine: progress lands on a
  /// later microtask, so tests pump to let it render.
  final progress = StreamController<GemmaProgress>.broadcast();

  GemmaModelPreset? installedPreset;
  String? installedWithToken;
  GemmaModelPreset? loadedPreset;

  /// While non-null and incomplete, `installModel` awaits it after emitting
  /// [pendingProgress].
  Completer<void>? installGate;

  /// Emitted by `installModel` before the gate.
  GemmaProgress? pendingProgress;

  @override
  bool get isAvailable => available;

  @override
  String? get loadedModelId => loadedPreset?.id;

  @override
  Stream<GemmaProgress> get progressEvents => progress.stream;

  @override
  Future<bool> isModelInstalled(GemmaModelPreset preset) async => false;

  @override
  Future<void> installModel(
    GemmaModelPreset preset, {
    String? huggingFaceToken,
  }) async {
    final error = installError;
    if (error != null) throw error;
    installedPreset = preset;
    installedWithToken = huggingFaceToken;
    final pending = pendingProgress;
    if (pending != null) progress.add(pending);
    final gate = installGate;
    if (gate != null) await gate.future;
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
  Future<List<GemmaInstalledModel>> installedModels() async => const [];

  @override
  Future<void> uninstall(String filename) async {}
}

void main() {
  group('BYOK setup screen', () {
    testWidgets('shows the provider picker, key/model/url fields, and the '
        'in-memory notice', (tester) async {
      await tester.pumpWidget(const MyApp());

      expect(find.text('Connect to fah'), findsOneWidget);
      // The closed picker shows the default selection; opening it lists all
      // built-in presets.
      expect(find.text('Provider'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      await tester.tap(find.byType(DropdownButtonFormField<Object>));
      await tester.pumpAndSettle();
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('On-device (WebLLM)'), findsOneWidget);
      await tester.tap(find.text('OpenRouter').last);
      await tester.pumpAndSettle();

      expect(find.text('Add provider'), findsOneWidget);
      expect(find.text('API key'), findsOneWidget);
      expect(find.text('Model id'), findsOneWidget);
      expect(find.text('Base URL'), findsOneWidget);
      expect(find.textContaining('never persisted'), findsOneWidget);
      expect(find.textContaining('gone on reload'), findsOneWidget);
      expect(find.text('Start chat'), findsOneWidget);
    });

    testWidgets('requires an API key before connecting', (tester) async {
      await tester.pumpWidget(const MyApp());

      await _tapConnect(tester, 'Start chat');

      expect(find.text('API key is required'), findsOneWidget);
      // Still on the setup screen — no navigation happened.
      expect(find.text('Connect to fah'), findsOneWidget);
    });

    testWidgets('defaults to OpenRouter with a read-only base URL', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      final url = _field(tester, 'Base URL');
      expect(url.enabled, isFalse);
      expect(url.controller!.text, 'https://openrouter.ai/api/v1');
      expect(_field(tester, 'Model id').controller!.text, 'openai/gpt-4o-mini');
      // Built-in presets cannot be edited or deleted.
      expect(find.text('Edit'), findsNothing);
      expect(find.text('Delete'), findsNothing);
    });

    testWidgets('switching presets updates the base URL and model default', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await _selectProvider(tester, 'Ollama');

      expect(
        _field(tester, 'Base URL').controller!.text,
        'https://ollama.com/v1',
      );
      expect(_field(tester, 'Model id').controller!.text, 'gpt-oss:120b');
      // Ollama Cloud may block browser calls — the UI must say so.
      expect(find.textContaining('CORS'), findsOneWidget);
    });

    testWidgets('custom preset enables the base URL field and shows the '
        'CORS note', (tester) async {
      await tester.pumpWidget(const MyApp());

      await _selectProvider(tester, 'Custom');

      expect(_field(tester, 'Base URL').enabled, isTrue);
      expect(find.textContaining('CORS'), findsOneWidget);
      expect(find.textContaining('api.anthropic.com'), findsOneWidget);
    });

    testWidgets('on-device preset shows the model picker and offline note', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await _selectProvider(tester, 'On-device (WebLLM)');

      // The key/model/URL fields are replaced by the on-device model picker.
      expect(find.text('API key'), findsNothing);
      expect(find.text('Base URL'), findsNothing);
      expect(find.text('On-device model'), findsOneWidget);
      expect(find.textContaining('SmolLM2 135M'), findsOneWidget);
      expect(
        find.textContaining('Runs fully offline after download'),
        findsOneWidget,
      );
      expect(find.textContaining('WebGPU'), findsOneWidget);
    });

    testWidgets('host build reports on-device inference as unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await _selectProvider(tester, 'On-device (WebLLM)');
      await _tapConnect(tester, 'Start chat');
      await tester.pump();

      // The stub engine (non-web platform) fails politely, no crash.
      expect(
        find.textContaining('only available in the web build'),
        findsOneWidget,
      );
      expect(find.text('Connect to fah'), findsOneWidget);
    });

    testWidgets('a typed model is not clobbered by preset switching', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await tester.enterText(
        find.widgetWithText(TextField, 'Model id'),
        'my-own-model',
      );
      await _selectProvider(tester, 'Ollama');

      expect(_field(tester, 'Model id').controller!.text, 'my-own-model');
    });
  });

  group('Custom providers', () {
    testWidgets('adding a provider puts it in the picker and prefills the '
        'form', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await _pumpForm(tester, registry);

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderEditorDialog), findsOneWidget);

      await tester.enterText(_editorField('Name'), 'Acme');
      await tester.enterText(
        _editorField('Base URL'),
        'https://acme.example/v1',
      );
      await tester.enterText(_editorField('Model id'), 'acme-1');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers, hasLength(1));
      // The new provider is selected and prefills the connection fields.
      expect(find.text('Acme'), findsOneWidget);
      expect(
        _field(tester, 'Base URL').controller!.text,
        'https://acme.example/v1',
      );
      expect(_field(tester, 'Model id').controller!.text, 'acme-1');
      // Custom providers offer edit/delete; built-ins never do.
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
      expect(
        find.textContaining(
          'The provider definition (name, URL, model) is '
          'saved',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the editor validates required fields', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await _pumpForm(tester, registry);

      await tester.tap(find.text('Add provider'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();

      expect(find.text('Name is required'), findsOneWidget);
      expect(registry.providers, isEmpty);
    });

    testWidgets('a provider key is remembered for the session after connect', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      final provider = await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      AgentConfig? connected;
      await _pumpForm(
        tester,
        registry,
        onConnect: (config) async => connected = config,
      );

      await _selectProvider(tester, 'Acme');
      await tester.enterText(
        find.widgetWithText(TextField, 'API key'),
        'sk-acme',
      );
      await _tapConnect(tester, 'Start chat');
      await tester.pumpAndSettle();

      expect(connected?.apiKey, 'sk-acme');
      expect(connected?.baseUrl, 'https://acme.example/v1');
      expect(registry.keyFor(provider.id), 'sk-acme');

      // Re-picking the provider prefills the remembered key.
      await _selectProvider(tester, 'Ollama');
      await _selectProvider(tester, 'Acme');
      expect(_field(tester, 'API key').controller!.text, 'sk-acme');
    });

    testWidgets('editing a provider updates the saved definition', (
      tester,
    ) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpForm(tester, registry);
      await _selectProvider(tester, 'Acme');

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(_editorField('Name')).controller!.text,
        'Acme',
      );

      await tester.enterText(_editorField('Model id'), 'acme-2');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(registry.providers.single.modelId, 'acme-2');
      expect(_field(tester, 'Model id').controller!.text, 'acme-2');
    });

    testWidgets('deleting a provider removes it from the picker and resets '
        'the selection', (tester) async {
      final registry = ProviderRegistry.inMemory();
      await registry.add(
        name: 'Acme',
        baseUrl: 'https://acme.example/v1',
        modelId: 'acme-1',
      );
      await _pumpForm(tester, registry);
      await _selectProvider(tester, 'Acme');

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text('Delete Acme?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(registry.providers, isEmpty);
      expect(find.text('Acme'), findsNothing);
      // Selection fell back to a built-in preset.
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('Delete'), findsNothing);

      // And it is gone from the picker entries too.
      await tester.tap(find.byType(DropdownButtonFormField<Object>));
      await tester.pumpAndSettle();
      expect(find.text('Acme'), findsNothing);
      expect(find.text('Ollama'), findsOneWidget);
    });
  });

  group('Chat screen settings gear', () {
    testWidgets('opens the settings dialog with the cache section', (
      tester,
    ) async {
      final service = _fakeService();
      await service.initialize();
      await tester.pumpWidget(MaterialApp(home: ChatScreen(service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('Add provider'), findsOneWidget);
      expect(find.textContaining('never persisted'), findsOneWidget);
      expect(find.textContaining('gone on reload'), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
      // Host build: the WebLLM stub is unavailable, so the downloaded-
      // models cache section collapses to the platform note.
      expect(
        find.textContaining('managed by the OS/app storage'),
        findsOneWidget,
      );
    });

    testWidgets('dialog validates the key without touching the network', (
      tester,
    ) async {
      final service = _fakeService();
      await service.initialize();
      await tester.pumpWidget(MaterialApp(home: ChatScreen(service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();
      await _tapConnect(tester, 'Apply');

      expect(find.text('API key is required'), findsOneWidget);
    });
  });

  group('On-device (Gemma) provider', () {
    // Widget tests run with defaultTargetPlatform = android by default, so
    // the Gemma preset is visible unless a test overrides the platform. The
    // override must be reset before the test body ends (the binding's
    // invariant check runs before addTearDown callbacks).
    void setPlatform(TargetPlatform? platform) {
      debugDefaultTargetPlatformOverride = platform;
    }

    testWidgets('shows the model picker and the HF token field on mobile', (
      tester,
    ) async {
      setPlatform(TargetPlatform.android);
      await tester.pumpWidget(const MyApp());

      await _selectProvider(tester, 'On-device (Gemma)');

      // The key/model/URL fields are replaced by the on-device model picker.
      expect(find.text('API key'), findsNothing);
      expect(find.text('Base URL'), findsNothing);
      expect(find.text('On-device model'), findsOneWidget);
      expect(find.textContaining('Gemma 4 E2B'), findsOneWidget);
      expect(find.text('HuggingFace token (optional)'), findsOneWidget);
      expect(
        find.textContaining('Runs fully offline after download'),
        findsOneWidget,
      );
      // The mobile note points at on-device storage (the web variant —
      // "cached by the browser (OPFS)" — is pure-function tested; kIsWeb is
      // a compile-time constant widget tests cannot flip).
      expect(find.textContaining('weights stay on the device'), findsOneWidget);

      // The picker offers both presets, E2B first (E4B is the ~4.3 GB one).
      await tester.tap(find.byType(DropdownButtonFormField<GemmaModelPreset>));
      await tester.pumpAndSettle();
      expect(find.textContaining('Gemma 4 E2B'), findsWidgets);
      expect(find.textContaining('Gemma 4 E4B'), findsOneWidget);
      await tester.tap(find.textContaining('Gemma 4 E4B'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Gemma 4 E4B'), findsOneWidget);
      setPlatform(null);
    });

    testWidgets('is hidden on desktop (and on web, where transformers.js '
        'replaces it)', (tester) async {
      setPlatform(TargetPlatform.macOS);
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.byType(DropdownButtonFormField<Object>));
      await tester.pumpAndSettle();
      expect(find.text('On-device (Gemma)'), findsNothing);
      // WebLLM stays offered everywhere (its stub reports unavailable).
      expect(find.text('On-device (WebLLM)'), findsOneWidget);
      // The transformers.js provider is web-only: hidden on desktop.
      expect(find.text('On-device (Gemma, transformers.js)'), findsNothing);
      await tester.tap(find.text('OpenRouter').last);
      await tester.pumpAndSettle();
      setPlatform(null);
    });

    testWidgets('connect installs with progress and hands over the gemma '
        'config', (tester) async {
      setPlatform(TargetPlatform.android);
      final engine = FakeGemmaEngine()
        ..pendingProgress = const GemmaProgress(
          fraction: 0.4,
          text: 'Downloading Gemma 4 E2B… 40%',
        )
        ..installGate = Completer<void>();
      AgentConfig? connected;
      await _pumpForm(
        tester,
        ProviderRegistry.inMemory(),
        gemmaEngine: engine,
        onConnect: (config) async => connected = config,
      );

      await _selectProvider(tester, 'On-device (Gemma)');
      await tester.enterText(
        find.widgetWithText(TextField, 'HuggingFace token (optional)'),
        'hf_test_token',
      );

      await tester.ensureVisible(find.text('Start chat'));
      await tester.tap(find.text('Start chat'));
      // Let the connect flow reach the (held) install and render progress.
      await tester.pump();
      await tester.pump();

      expect(find.text('Downloading Gemma 4 E2B… 40%'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);
      expect(engine.installedPreset?.id, gemmaModelPresets.first.id);
      expect(engine.installedWithToken, 'hf_test_token');
      expect(connected, isNull);

      engine.installGate!.complete();
      await tester.pumpAndSettle();

      expect(engine.loadedPreset?.id, gemmaModelPresets.first.id);
      expect(connected?.providerKind, gemmaProviderKind);
      expect(connected?.modelId, gemmaModelPresets.first.id);
      expect(connected?.baseUrl, isEmpty);
      expect(connected?.apiKey, isEmpty);
      expect(connected?.contextWindow, gemmaModelPresets.first.contextWindow);
      expect(connected?.maxTokens, 1024);
      // Progress UI is cleared once the connect flow finishes.
      expect(find.byType(LinearProgressIndicator), findsNothing);
      setPlatform(null);
    });

    testWidgets('a failed install surfaces the engine error', (tester) async {
      setPlatform(TargetPlatform.android);
      final engine = FakeGemmaEngine()
        ..installError = StateError('403: gated repo, token required');
      await _pumpForm(tester, ProviderRegistry.inMemory(), gemmaEngine: engine);

      await _selectProvider(tester, 'On-device (Gemma)');
      await _tapConnect(tester, 'Start chat');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('403: gated repo, token required'),
        findsOneWidget,
      );
      expect(engine.loadedPreset, isNull);
      setPlatform(null);
    });

    testWidgets('an unavailable engine surfaces the platform message', (
      tester,
    ) async {
      setPlatform(TargetPlatform.android);
      final engine = FakeGemmaEngine()..available = false;
      await _pumpForm(tester, ProviderRegistry.inMemory(), gemmaEngine: engine);

      await _selectProvider(tester, 'On-device (Gemma)');
      await _tapConnect(tester, 'Start chat');
      await tester.pumpAndSettle();

      expect(
        find.textContaining('not available in this build'),
        findsOneWidget,
      );
      setPlatform(null);
    });
  });

  group('On-device (Gemma, transformers.js) provider', () {
    // The provider is web-only; host widget tests exercise the web case
    // through the form's isWeb seam (kIsWeb is a compile-time constant).
    testWidgets('is visible on web, where flutter_gemma is hidden', (
      tester,
    ) async {
      await _pumpForm(tester, ProviderRegistry.inMemory(), isWeb: true);

      await tester.tap(find.byType(DropdownButtonFormField<Object>));
      await tester.pumpAndSettle();
      expect(find.text('On-device (Gemma, transformers.js)'), findsOneWidget);
      expect(find.text('On-device (Gemma)'), findsNothing);
      expect(find.text('On-device (WebLLM)'), findsOneWidget);
      await tester.tap(find.text('OpenRouter').last);
      await tester.pumpAndSettle();
    });

    testWidgets('is hidden on mobile (flutter_gemma shown instead)', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.byType(DropdownButtonFormField<Object>));
      await tester.pumpAndSettle();
      expect(find.text('On-device (Gemma, transformers.js)'), findsNothing);
      expect(find.text('On-device (Gemma)'), findsOneWidget);
      await tester.tap(find.text('OpenRouter').last);
      await tester.pumpAndSettle();
    });

    testWidgets('shows the model picker with vision/tools badges and the '
        'public-repo note', (tester) async {
      await _pumpForm(tester, ProviderRegistry.inMemory(), isWeb: true);

      await _selectProvider(tester, 'On-device (Gemma, transformers.js)');

      // The key/model/URL fields are replaced by the on-device model picker;
      // no HuggingFace token field (the ONNX repo is public).
      expect(find.text('API key'), findsNothing);
      expect(find.text('Base URL'), findsNothing);
      expect(find.text('HuggingFace token (optional)'), findsNothing);
      expect(find.text('On-device model'), findsOneWidget);
      expect(find.textContaining('Gemma 4 E2B (ONNX)'), findsOneWidget);
      expect(find.textContaining('~3.4 GB'), findsOneWidget);
      expect(find.text('vision'), findsOneWidget);
      expect(find.text('tools via prompt'), findsOneWidget);
      expect(
        find.textContaining('Runs fully offline after download'),
        findsOneWidget,
      );
      expect(find.textContaining('no token'), findsOneWidget);
    });

    testWidgets('connect loads with progress and hands over the '
        'transformers_js config', (tester) async {
      final engine = FakeTransformersJsEngine()
        ..pendingProgress = const TransformersJsProgress(
          fraction: 0.4,
          text: 'Downloading model weights…',
        )
        ..loadGate = Completer<void>();
      AgentConfig? connected;
      await _pumpForm(
        tester,
        ProviderRegistry.inMemory(),
        transformersJsEngine: engine,
        isWeb: true,
        onConnect: (config) async => connected = config,
      );

      await _selectProvider(tester, 'On-device (Gemma, transformers.js)');
      await tester.ensureVisible(find.text('Start chat'));
      await tester.tap(find.text('Start chat'));
      // Let the connect flow reach the (held) load and render progress.
      await tester.pump();
      await tester.pump();

      expect(find.text('Downloading model weights…'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, 0.4);
      expect(connected, isNull);

      engine.loadGate!.complete();
      await tester.pumpAndSettle();

      expect(engine.loadedPreset?.id, transformersJsModelPresets.first.id);
      expect(connected?.providerKind, transformersJsProviderKind);
      expect(connected?.modelId, transformersJsModelPresets.first.id);
      expect(connected?.baseUrl, isEmpty);
      expect(connected?.apiKey, isEmpty);
      expect(
        connected?.contextWindow,
        transformersJsModelPresets.first.contextWindow,
      );
      expect(connected?.maxTokens, 1024);
      // Progress UI is cleared once the connect flow finishes.
      expect(find.byType(LinearProgressIndicator), findsNothing);
    });

    testWidgets('a failed load surfaces the engine error', (tester) async {
      final engine = FakeTransformersJsEngine()
        ..loadError = StateError(
          'This browser has no WebGPU support, which on-device inference '
          'needs.',
        );
      await _pumpForm(
        tester,
        ProviderRegistry.inMemory(),
        transformersJsEngine: engine,
        isWeb: true,
      );

      await _selectProvider(tester, 'On-device (Gemma, transformers.js)');
      await _tapConnect(tester, 'Start chat');
      await tester.pumpAndSettle();

      expect(find.textContaining('no WebGPU support'), findsOneWidget);
      expect(engine.loadedPreset, isNull);
    });
  });

  group('transformersJsProviderVisible', () {
    test('web only', () {
      expect(transformersJsProviderVisible(isWeb: true), isTrue);
      expect(transformersJsProviderVisible(isWeb: false), isFalse);
    });
  });

  group('gemmaProviderVisible', () {
    test('iOS/Android only — web is served by the transformers.js provider, '
        'desktop by neither', () {
      for (final platform in TargetPlatform.values) {
        expect(
          gemmaProviderVisible(isWeb: true, platform: platform),
          isFalse,
          reason:
              'web replaced flutter_gemma with the transformers.js '
              'provider (litert-lm web engine abandoned)',
        );
      }
      expect(
        gemmaProviderVisible(isWeb: false, platform: TargetPlatform.iOS),
        isTrue,
      );
      expect(
        gemmaProviderVisible(isWeb: false, platform: TargetPlatform.android),
        isTrue,
      );
      for (final desktop in [
        TargetPlatform.macOS,
        TargetPlatform.linux,
        TargetPlatform.windows,
      ]) {
        expect(
          gemmaProviderVisible(isWeb: false, platform: desktop),
          isFalse,
          reason: 'desktop needs extra native packaging — hidden for now',
        );
      }
    });
  });

  group('gemmaStorageNote', () {
    test(
      'web cites the one-time OPFS download, mobile the on-device weights',
      () {
        final e2b = gemmaModelPresets.first;
        expect(
          gemmaStorageNote(isWeb: true, preset: e2b),
          allOf([
            // The web download is the (smaller) `-web.litertlm` build.
            contains('downloads ~1.9 GB once'),
            contains('cached by the browser (OPFS)'),
            contains('Runs fully offline after download'),
            // Honest about the web engine dropping image/audio inputs.
            contains('text-only on web'),
            contains('never persisted'),
          ]),
        );
        final e4b = gemmaModelPresets.last;
        expect(
          gemmaStorageNote(isWeb: true, preset: e4b),
          contains('downloads ~2.8 GB once'),
        );
        expect(
          gemmaStorageNote(isWeb: false, preset: e2b),
          allOf([
            contains('weights stay on the device'),
            isNot(contains('OPFS')),
            isNot(contains('text-only')),
            contains('never persisted'),
          ]),
        );
      },
    );
  });
}
