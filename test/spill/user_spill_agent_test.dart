// Issue #1760 — the Agent-level intake seams: every path user messages
// enter the loop (prompt batch, mid-run steering drain, follow-up drain)
// passes Agent.userMessageGuard. The guard here is the real
// UserMessageSpillGuard over a MemoryExecutionEnv, so the tests prove the
// end-to-end shape: an oversized message's transcript entry, the request
// context the provider would receive, and the spill file all agree.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// 9999 chars → estimate 2500 tokens; the test budget (4000 × 0.5 = 2000)
/// trips, and the 1024-byte floor passes. Small texts never spill.
final _bigText = 'log line\n' * 1111;

AssistantMessage _assistant(String text) => AssistantMessage(
  content: [TextContent(text: text)],
  api: 'test-api',
  provider: 'test-provider',
  model: 'test-model',
  usage: Usage.zero,
  stopReason: StopReason.stop,
  timestamp: DateTime.utc(2026),
);

/// Records every request context; blocks the call at [gateIndex] on [gate]
/// (negative = never blocks) so tests can land mid-run arrivals
/// deterministically.
final class _RecordingStream {
  final contexts = <Context>[];
  final gate = Completer<void>();
  final int gateIndex;

  _RecordingStream({this.gateIndex = -1});

  int get calls => contexts.length;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final events = AssistantMessageEventStream();
    if (calls == gateIndex) {
      unawaited(gate.future.then((_) => _emit(events)));
    } else {
      _emit(events);
    }
    return events;
  }

  void _emit(AssistantMessageEventStream events) {
    final partial = _assistant('');
    final done = _assistant('ok');
    events
      ..push(StartEvent(partial: partial))
      ..push(TextStartEvent(contentIndex: 0, partial: partial))
      ..push(TextDeltaEvent(contentIndex: 0, delta: 'ok', partial: done))
      ..push(DoneEvent(reason: StopReason.stop, message: done));
    events.end();
  }
}

String _userTextOf(Message message) {
  final content = (message as UserMessage).content;
  return content is String
      ? content
      : [
          for (final block in content as List<ContentBlock>)
            if (block is TextContent) block.text,
        ].join();
}

/// Every user message's text in a captured request context — the loop
/// may append injected user messages (budget lines) after the prompt.
String _allUserText(Context context) => [
  for (final message in context.messages)
    if (message is UserMessage) _userTextOf(message),
].join('\n---\n');

Agent _agent(_RecordingStream stream, {required ExecutionEnv env}) {
  final agent = Agent(
    model: _model,
    streamFunction: stream.call,
    toolExecutor: (call, token, onUpdate) async => ToolExecutionResult.text(''),
  );
  agent.userMessageGuard = UserMessageSpillGuard(
    env: env,
    config: const SpillsConfig(userThreshold: 1024),
    budgetTokens: () => 4000,
    sessionId: () => 'sess-1',
  ).guard;
  return agent;
}

void main() {
  test('AC1 seam: an oversized headless-style prompt is bounded before the '
      'first request and the transcript', () async {
    final stream = _RecordingStream();
    final env = MemoryExecutionEnv(cwd: '/work');
    final agent = _agent(stream, env: env);

    await agent.prompt(_bigText);

    // The transcript carries the bounded replacement, not the body.
    final transcript = agent.state.messages.whereType<UserMessage>().single;
    final transcriptText = transcript.content as String;
    expect(transcriptText.contains(_bigText), isFalse);
    expect(transcriptText, contains('.fah/spills/sess-1/user-1.md'));
    expect(transcriptText, contains('Read it in parts with the read tool'));
    // The request context the provider sees is the same message.
    expect(_allUserText(stream.contexts[0]), contains(transcriptText));
    expect(_allUserText(stream.contexts[0]), isNot(contains(_bigText)));
    // The verbatim body is on disk.
    final file = await env.readTextFile('.fah/spills/sess-1/user-1.md');
    expect(file.valueOrNull, _bigText);
  });

  test(
    'AC4 seam: mid-run steering through the drain seam spills too',
    () async {
      final stream = _RecordingStream(gateIndex: 1);
      final env = MemoryExecutionEnv(cwd: '/work');
      final agent = _agent(stream, env: env);

      final run = agent.prompt('normal question');
      // Mid-run: the oversized steer lands in the queue while the first
      // stream is held; the boundary drain passes it through the same guard.
      while (stream.calls < 1) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      agent.steer(UserMessage.text(_bigText));
      stream.gate.complete();
      await run;

      expect(stream.calls, 2);
      final steered = _allUserText(stream.contexts[1]);
      expect(steered.contains(_bigText), isFalse);
      expect(steered, contains('.fah/spills/sess-1/user-1.md'));
      // The transcript's steered user message is the replacement.
      final transcriptSteered = _userTextOf(
        agent.state.messages.whereType<UserMessage>().last,
      );
      expect(transcriptSteered, contains('.fah/spills/sess-1/user-1.md'));
      expect(steered, contains(transcriptSteered));
    },
  );

  test(
    'AC4 seam: a queued follow-up spills at the loop boundary drain',
    () async {
      final stream = _RecordingStream();
      final env = MemoryExecutionEnv(cwd: '/work');
      final agent = _agent(stream, env: env);

      agent.followUp(UserMessage.text(_bigText));
      await agent.prompt('the real turn');

      expect(stream.calls, 2);
      final followUp = _allUserText(stream.contexts[1]);
      expect(followUp.contains(_bigText), isFalse);
      expect(followUp, contains('.fah/spills/sess-1/user-1.md'));
    },
  );

  test(
    'AC3 seam: without a guard nothing changes (legacy pass-through)',
    () async {
      final stream = _RecordingStream();
      final agent = Agent(
        model: _model,
        streamFunction: stream.call,
        toolExecutor: (call, token, onUpdate) async =>
            ToolExecutionResult.text(''),
      );

      await agent.prompt(_bigText);

      final transcript = agent.state.messages.whereType<UserMessage>().single;
      expect(transcript.content, _bigText);
    },
  );

  test(
    'regression (CI 39678698410): abort() on the line after prompt() '
    'still cancels the run — the guard must not delay run registration',
    () async {
      // Both with and without a guard installed, _activeRun/_isStreaming
      // register synchronously inside prompt(); a token cancelled before the
      // loop streams becomes the aborted terminal instead of a hang.
      for (final withGuard in [false, true]) {
        final stream = _RecordingStream(gateIndex: 1);
        final env = MemoryExecutionEnv(cwd: '/work');
        final agent = withGuard
            ? _agent(stream, env: env)
            : Agent(
                model: _model,
                streamFunction: stream.call,
                toolExecutor: (call, token, onUpdate) async =>
                    ToolExecutionResult.text(''),
              );

        final run = agent.prompt('hi');
        agent.abort();
        await run;

        // The run ended aborted — not hung, not errored.
        final last = agent.state.messages.last;
        expect(
          last,
          isA<AssistantMessage>().having(
            (m) => m.stopReason,
            'stopReason',
            StopReason.aborted,
          ),
          reason: 'withGuard=$withGuard',
        );
      }
    },
  );
}
