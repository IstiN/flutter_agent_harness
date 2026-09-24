import 'package:fa/services/agent_service.dart';
import 'package:fa_ui/fa_ui.dart' show ChatMessageTile, SandboxImageResolver;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Issue #867: a structured 429 renders the localized human message in the
/// app error bubble — title + server-derived countdown (ru/en), never the
/// raw payload — while a 429 mid-stream keeps the partial answer visible.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final resetsAt = DateTime.utc(2026, 10, 19, 19, 49, 31);
  const rawPayload =
      '{"error":{"type":"usage_limit_reached","plan_type":"free",'
      '"resets_at":1792439371,"resets_in_seconds":2280562}}';

  /// Streams a partial answer, then dies mid-stream with a structured 429.
  StreamFunction rateLimitedAfterPartial() => (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    const partialText = 'partial answer before the wall';
    for (var i = 1; i <= partialText.length; i++) {
      stream.push(
        TextDeltaEvent(
          contentIndex: 0,
          delta: partialText[i - 1],
          partial: AssistantMessage(
            content: [TextContent(text: partialText.substring(0, i))],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime(2026),
          ),
        ),
      );
    }
    stream.push(
      ErrorEvent(
        reason: StopReason.error,
        error: AssistantMessage(
          content: [TextContent(text: partialText)],
          api: model.api,
          provider: model.provider,
          model: model.id,
          usage: Usage.zero,
          stopReason: StopReason.error,
          errorMessage: '429: ChatGPT Free plan limit reached.',
          rateLimit: RateLimitInfo(
            errorType: 'usage_limit_reached',
            planType: 'free',
            resetsAt: resetsAt,
            resetsInSeconds: 2280562,
            // The codex adapter brands the plan title (withBrand).
            brand: 'ChatGPT',
            rawBody: rawPayload,
          ),
          timestamp: DateTime(2026),
        ),
      ),
    );
    stream.end();
    return stream;
  };

  Future<AgentService> pumpService() async {
    final service = AgentService(
      agent: Agent(
        model: Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test',
          baseUrl: 'https://example.com',
          contextWindow: 100000,
          maxTokens: 4096,
        ),
        systemPrompt: 'You are Fa.',
        streamFunction: rateLimitedAfterPartial(),
        toolRegistry: ToolRegistry(const []),
      ),
      env: MemoryExecutionEnv(),
      sessionsRoot: '/sessions',
    );
    await service.initialize();
    return service;
  }

  FahChatMessage errorTileOf(AgentService service) => service.messages
      .singleWhere((m) => m.isError && m.toolName == 'error');

  testWidgets('a structured 429 renders the localized bubble and keeps the partial answer', (
    tester,
  ) async {
    // ru: the GOAL wording family, countdown derived from resets_in_seconds.
    tester.platformDispatcher.localeTestValue = const Locale('ru');
    late final AgentService service;
    late final FahChatMessage tile;
    // The service layer is real-async (timers, persistence) — run it outside
    // the fake-async zone, then pump the widget phase normally.
    await tester.runAsync(() async {
      service = await pumpService();
      await service.sendText('hi');
      await service.waitForIdle();
      tile = errorTileOf(service);
    });

    expect(tile.content, contains('Лимит плана Free ChatGPT исчерпан.'));
    expect(tile.content, contains('через 26 дней'));
    expect(tile.content, contains('Далее: переключитесь'));
    expect(tile.content.contains('{'), isFalse);
    expect(tile.content.contains('resets_at'), isFalse);

    // E4: the mid-stream partial answer survives next to the error tile.
    expect(
      service.messages.any(
        (m) => m.role == 'assistant' && m.content.contains('partial answer'),
      ),
      isTrue,
    );

    // The bubble surface itself renders the human text.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ChatMessageTile(
            message: tile,
            images: SandboxImageResolver(MemoryExecutionEnv()),
          ),
        ),
      ),
    );
    expect(find.textContaining('через 26 дней'), findsOneWidget);
    expect(find.textContaining('{'), findsNothing);
  });

  testWidgets('the same 429 speaks english under an en locale', (tester) async {
    tester.platformDispatcher.localeTestValue = const Locale('en');
    late final FahChatMessage tile;
    await tester.runAsync(() async {
      final service = await pumpService();
      await service.sendText('hi');
      await service.waitForIdle();
      tile = errorTileOf(service);
    });

    expect(tile.content, contains('ChatGPT Free plan limit reached.'));
    expect(tile.content, contains('in 26 days'));
    expect(tile.content, contains('Next: switch to a model or provider'));
    expect(tile.content.contains('{'), isFalse);
  });
}
