// Issue #1168 - the CLI surfaces a bad connection as a RETRY, not a dead
// turn: a provider stream that dies with a connection-class error after
// partial output (the owner's `Operation timed out` shape) resumes from
// the completed prefix and the headless run completes with exit 0. A
// fatal auth error keeps today's contract: no retry, the error line, exit 1.
import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

StreamFunction diesOnceThenCompletes() {
  var calls = 0;
  return (model, context, {cancelToken}) {
    final n = ++calls;
    final stream = AssistantMessageEventStream();
    scheduleMicrotask(() {
      if (n == 1) {
        final empty = testAssistant();
        final part = testAssistant(
          content: [const TextContent(text: 'partial answer')],
        );
        stream
          ..push(StartEvent(partial: empty))
          ..push(TextStartEvent(contentIndex: 0, partial: empty))
          ..push(
            TextDeltaEvent(
              contentIndex: 0,
              delta: 'partial answer',
              partial: part,
            ),
          )
          ..push(
            TextEndEvent(
              contentIndex: 0,
              content: 'partial answer',
              partial: part,
            ),
          )
          ..push(
            ErrorEvent(
              reason: StopReason.error,
              // Real adapters finalize the accumulated snapshot into the
              // error message (pushStreamErrorEvent -> state.snapshot).
              error: testAssistant(
                content: [const TextContent(text: 'partial answer')],
                stopReason: StopReason.error,
                errorMessage:
                    'SocketException: Connection failed (OS Error: Operation '
                    'timed out, errno = 60), address = api.example.com, '
                    'port = 443',
              ),
            ),
          );
      } else {
        final empty = testAssistant();
        final tail = testAssistant(
          content: [const TextContent(text: 'tail of the answer')],
        );
        stream
          ..push(StartEvent(partial: empty))
          ..push(TextStartEvent(contentIndex: 0, partial: empty))
          ..push(
            TextDeltaEvent(
              contentIndex: 0,
              delta: 'tail of the answer',
              partial: tail,
            ),
          )
          ..push(
            TextEndEvent(
              contentIndex: 0,
              content: 'tail of the answer',
              partial: tail,
            ),
          )
          ..push(DoneEvent(reason: StopReason.stop, message: tail));
      }
      stream.end();
    });
    return stream;
  };
}

/// A [StreamFunction] that always fails with an auth error.
StreamFunction alwaysAuthError() {
  return (model, context, {cancelToken}) {
    final stream = AssistantMessageEventStream();
    scheduleMicrotask(() {
      stream
        ..push(StartEvent(partial: testAssistant()))
        ..push(
          ErrorEvent(
            reason: StopReason.error,
            error: testAssistant(
              stopReason: StopReason.error,
              errorMessage: '401 unauthorized: invalid API key',
            ),
          ),
        )
        ..end();
    });
    return stream;
  };
}

AgentCli cli(StreamFunction stream, FakeCliIO io) => AgentCli(
  config: AgentCliConfig(
    model: const Model(
      id: 'test-model',
      api: 'test-api',
      provider: 'test-provider',
      baseUrl: 'https://api.example.test',
      contextWindow: 32000,
      maxTokens: 4096,
    ),
    apiKey: 'test-key',
    env: MemoryExecutionEnv(cwd: '/work'),
    sessionRoot: '/sessions',
    providerKind: 'openai-completions',
  ),
  io: io,
  streamFunction: transientRetryStreamFunction(stream),
);

Future<bool> Function(Duration, CancelToken?)? savedSleeper;
TransientRetryNotice? savedNotice;

void main() {
  Future<void> stubSleep() async {
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    transientRetrySleeper = (delay, token) async => true;
    addTearDown(() {
      transientRetrySleeper = savedSleeper!;
      transientRetryNotice = savedNotice;
    });
  }

  test('headless: a mid-turn Operation timed out retries and the run '
      'exits 0', () async {
    await stubSleep();
    final io = FakeCliIO();

    final exitCode = await cli(diesOnceThenCompletes(), io).runHeadless(
      'say hi',
    );

    expect(exitCode, 0, reason: 'the turn survived the dead connection');
    expect(io.out.toString(), contains('partial answer'));
    expect(io.out.toString(), contains('tail of the answer'));
    expect(io.out.toString(), isNot(contains('error:')));
  });

  test('headless: the retry is visible as a [net] notice, never silent',
      () async {
    // No global override: null the hook first, so the ONLY way the [net]
    // line can appear is runHeadless's own boot wiring (issue #1168
    // review - headless must voice the resume exactly like the REPL).
    await stubSleep();
    transientRetryNotice = null;
    final io = FakeCliIO();

    final exitCode = await cli(diesOnceThenCompletes(), io).runHeadless(
      'say hi',
    );

    expect(exitCode, 0);
    // The dim [net] line names the mid-stream resume with the completed
    // prefix - a multi-second pause is never silent in headless.
    expect(io.out.toString(), contains('[net] connection lost'));
    expect(io.out.toString(), contains('mid-stream connection failure'));
    expect(io.out.toString(), contains('resuming from 1 completed block(s)'));
  });

  test('headless: an auth error stays fatal — exit 1 and the error line',
      () async {
    await stubSleep();
    final io = FakeCliIO();

    final exitCode = await cli(alwaysAuthError(), io).runHeadless('say hi');

    expect(exitCode, 1);
    expect(io.out.toString(), contains('error:'));
    expect(io.out.toString(), contains('401 unauthorized'));
  });
}
