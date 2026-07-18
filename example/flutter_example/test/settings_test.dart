import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/main.dart';
import 'package:flutter_agent_example/provider_registry.dart';
import 'package:flutter_agent_example/settings.dart';
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
}) {
  return tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: AgentSettingsForm(
            registry: registry,
            onConnect: onConnect ?? (_) async {},
          ),
        ),
      ),
    ),
  );
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
}
