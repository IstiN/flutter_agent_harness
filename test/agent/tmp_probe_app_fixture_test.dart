import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

/// gh-2044 rework probe: replicate the flutter_app over-window relief
/// fixture at the core level — [user 'go', assistant toolUse, tool result
/// y*34000] over an 8192 window; the fake stream answers call 1 with a
/// toolUse turn and every later call with text 'continued'.
void main() {
  test('PROBE: app over-window relief fixture through AutoCompactorFactory',
      () async {
    final session = SessionRecord(
      messages: const [
        TextMessage(role: SessionRole.user, text: 'go'),
        TextMessage(role: SessionRole.assistant, text: ''),
      ],
      toolResults: const [
        ToolResultRecord(
          id: 'tc-1',
          name: 'echo',
          result: ToolResultPayload(text: 'y' * 34000),
        ),
      ],
    );
    var calls = 0;
    Stream<LlmStreamEvent> fake(Model model, List<Message> messages,
        {bool thinking = false}) async* {
      calls++;
      if (calls == 1) {
        yield MessageEvent(
          message: AssistantMessage(
            content: const [ToolUseContent(id: 'tc-1', name: 'echo', input: {})],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.toolUse,
            timestamp: DateTime.now(),
          ),
        );
      } else {
        yield MessageEvent(
          message: AssistantMessage(
            content: const [TextContent(text: 'continued')],
            api: model.api,
            provider: model.provider,
            model: model.id,
            usage: Usage.zero,
            stopReason: StopReason.stop,
            timestamp: DateTime.now(),
          ),
        );
      }
      yield const DoneEvent(reason: StopReason.stop);
    }

    final model = Model(
      id: 'test-model',
      name: 'test-model',
      api: ModelApi.anthropic,
      provider: 'test',
      contextWindow: 8192,
    );
    final hooks = _Hooks();
    final ok = await AutoCompactorFactory(
      session: session,
      state: const AgentState(
        messages: [],
        model: Model(
          id: 'test-model',
          name: 'test-model',
          api: ModelApi.anthropic,
          provider: 'test',
          contextWindow: 8192,
        ),
      ),
      window: 8192,
      settings: CompactionSettings.fromWindow(8192),
      sources: AutoCompactorSources(
        smolStream: fake,
        smolModel: model,
        mainStream: fake,
        mainModel: model,
      ),
      hooks: hooks,
      prompts: const CompactionPrompts(),
      engine: CompactionEngine.structured,
    ).run();
    // ignore: avoid_print
    print('PROBE run()=$ok streamCalls=$calls hooks=${hooks.log}');
    // ignore: avoid_print
    print(
        'PROBE session after: ${session.messages.length} messages, '
        '${session.toolResults.length} toolResults');
    for (final m in session.messages) {
      // ignore: avoid_print
      print(
          'PROBE   msg role=${m.role} text=${m.text.length > 60 ? '${m.text.substring(0, 60)}…' : m.text}');
    }
    for (final r in session.toolResults) {
      // ignore: avoid_print
      print('PROBE   tool ${r.name} len=${r.result.text.length}');
    }
    for (final c in session.checkpoints) {
      // ignore: avoid_print
      print('PROBE   checkpoint kind=${c.kind} summaryLen=${c.summary.length}');
    }
    expect(ok, isTrue, reason: 'relief must land: the app turn continues');
  });
}

class _Hooks implements AutoCompactorHooks {
  final log = <String>[];
  @override
  void onDelta(String delta) => log.add('delta:${delta.length}');
  @override
  void onAttemptStart(int attempt) => log.add('attempt:$attempt');
  @override
  void onPass(CompactionPassReceipt receipt) =>
      log.add('pass:${receipt.kind} ok=${receipt.ok} '
          'err=${receipt.error} after=${receipt.afterTokens}');
  @override
  void onFallback(String reason) => log.add('fallback:$reason');
  @override
  void onNotice(String message) => log.add('notice:$message');
}
