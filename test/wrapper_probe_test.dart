import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/compaction/structured/judge.dart';
import 'package:test/test.dart';

void main() {
  test('resolver wrapper delegates to the fake stream', () async {
    var calls = 0;
    AssistantMessageEventStream fake(Model m, Context c, {CancelToken? cancelToken}) {
      calls++;
      final partial = AssistantMessage(
        content: [TextContent(text: '[1]')],
        api: m.api,
        provider: m.provider,
        model: m.id,
        usage: Usage.zero,
        stopReason: StopReason.stop,
        timestamp: DateTime.utc(2026),
      );
      final s = AssistantMessageEventStream();
      s.push(StartEvent(partial: partial));
      s.push(DoneEvent(reason: StopReason.stop, message: partial));
      s.end();
      return s;
    }

    final resolver = ModelRolesResolver(
      config: ModelRolesConfig(
        roles: {
          smolModelRole: [
            const ModelRef(
              provider: 'anthropic',
              modelId: 'test-smol',
              contextWindow: 400,
              maxTokens: 256,
            ),
          ],
        },
      ),
      secrets: const {'ANTHROPIC_API_KEY': 'k'},
      streamFactory: (kind, apiKey) => fake,
    );
    final smol = resolver.resolveRole(smolModelRole)!;
    expect(smol.model.contextWindow, 400);
    final events = await smol.stream(smol.model, Context(messages: [UserMessage.text('judge me')])).toList();
    expect(calls, 1);
    expect(events, isNotEmpty);

    // The judge adapter over the wrapped stream (the exact shape
    // AutoCompactorFactory wires).
    final judge = streamFunctionHideJudge(
      smol.stream,
      smol.model,
      system: 'context-hygiene judge',
    );
    final answer = await judge('[1] hello');
    // ignore: avoid_print
    print('DEBUG judge answer=\$answer calls=\$calls');
    expect(answer, isNotNull);
  });
}
