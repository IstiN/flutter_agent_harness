import 'package:flutter/material.dart';
import 'package:flutter_agent_example/agent_service.dart';
import 'package:flutter_agent_example/chat_screen.dart';
import 'package:flutter_agent_example/main.dart';
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

void main() {
  group('BYOK setup screen', () {
    testWidgets('shows provider presets, key/model/url fields, and the '
        'in-memory notice', (tester) async {
      await tester.pumpWidget(const MyApp());

      expect(find.text('Connect to fah'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.text('Ollama'), findsOneWidget);
      expect(find.text('Custom'), findsOneWidget);
      expect(find.text('API key'), findsOneWidget);
      expect(find.text('Model id'), findsOneWidget);
      expect(find.text('Base URL'), findsOneWidget);
      expect(find.textContaining('never persisted'), findsOneWidget);
      expect(find.textContaining('gone on reload'), findsOneWidget);
      expect(find.text('Start chat'), findsOneWidget);
    });

    testWidgets('requires an API key before connecting', (tester) async {
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.text('Start chat'));
      await tester.pump();

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
    });

    testWidgets('switching presets updates the base URL and model default', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.text('Ollama'));
      await tester.pump();

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

      await tester.tap(find.text('Custom'));
      await tester.pump();

      expect(_field(tester, 'Base URL').enabled, isTrue);
      expect(find.textContaining('CORS'), findsOneWidget);
      expect(find.textContaining('api.anthropic.com'), findsOneWidget);
    });

    testWidgets('on-device preset shows the model picker and offline note', (
      tester,
    ) async {
      await tester.pumpWidget(const MyApp());

      await tester.tap(find.text('On-device (WebLLM)'));
      await tester.pump();

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

      await tester.tap(find.text('On-device (WebLLM)'));
      await tester.pump();
      await tester.tap(find.text('Start chat'));
      await tester.pump();
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
      await tester.tap(find.text('Ollama'));
      await tester.pump();

      expect(_field(tester, 'Model id').controller!.text, 'my-own-model');
    });
  });

  group('Chat screen settings gear', () {
    testWidgets('opens the connection settings dialog', (tester) async {
      final service = _fakeService();
      await service.initialize();
      await tester.pumpWidget(MaterialApp(home: ChatScreen(service: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.settings_outlined));
      await tester.pumpAndSettle();

      expect(find.text('Connection settings'), findsOneWidget);
      expect(find.text('OpenRouter'), findsOneWidget);
      expect(find.textContaining('never persisted'), findsOneWidget);
      expect(find.textContaining('gone on reload'), findsOneWidget);
      expect(find.text('Apply'), findsOneWidget);
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
      await tester.tap(find.text('Apply'));
      await tester.pump();

      expect(find.text('API key is required'), findsOneWidget);
    });
  });
}
