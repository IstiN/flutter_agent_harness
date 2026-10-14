// gh-1602 REG, end to end: a scripted 429-then-200 provider through the
// headless run — the ladder retries (the run completes with exit 0, the
// `[net] rate limited` notice is on the log face) and the session JSONL
// carries the hidden `429_retry` record for bench post-mortems.
//
// The bench contract this protects: run 7 recorded `ApiRateLimitError` ×
// 5 with `n_retries: 0` — trials mid-progress died on one transient
// quota blip and scored 0.
@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

StreamFunction rateLimitedOnceThenCompletes() {
  var calls = 0;
  return (model, context, {cancelToken}) {
    final n = ++calls;
    final stream = AssistantMessageEventStream();
    scheduleMicrotask(() {
      if (n == 1) {
        stream
          ..push(StartEvent(partial: testAssistant()))
          ..push(
            ErrorEvent(
              reason: StopReason.error,
              // The exact run-7 shape: the structured 429 decode renders
              // this line and the pre-fix run exited 1 with it.
              error: testAssistant(
                stopReason: StopReason.error,
                errorMessage: '429: Rate limit reached. Try again later.',
              ),
            ),
          )
          ..end();
        return;
      }
      final tail = testAssistant(
        content: [const TextContent(text: 'the answer after the blip')],
      );
      stream
        ..push(StartEvent(partial: testAssistant()))
        ..push(TextStartEvent(contentIndex: 0, partial: testAssistant()))
        ..push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'the answer after the blip',
            partial: tail,
          ),
        )
        ..push(
          TextEndEvent(
            contentIndex: 0,
            content: 'the answer after the blip',
            partial: tail,
          ),
        )
        ..push(DoneEvent(reason: StopReason.stop, message: tail))
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
Duration? Function()? savedDeadlineLeft;

void main() {
  setUp(() {
    savedSleeper = transientRetrySleeper;
    savedNotice = transientRetryNotice;
    savedDeadlineLeft = transientRetryDeadlineLeft;
    transientRetrySleeper = (delay, token) async => true;
    transientRetryDeadlineLeft = null;
  });
  tearDown(() {
    transientRetrySleeper = savedSleeper!;
    transientRetryNotice = savedNotice;
    transientRetryDeadlineLeft = savedDeadlineLeft;
  });

  test('headless: a scripted 429-then-200 run retries, completes with '
      'exit 0 — no exit 1 (AC1)', () async {
    final io = FakeCliIO();

    final exitCode = await cli(
      rateLimitedOnceThenCompletes(),
      io,
    ).runHeadless('say hi');

    expect(exitCode, 0, reason: 'the quota blip must not kill the run');
    expect(io.out.toString(), contains('the answer after the blip'));
    expect(io.out.toString(), isNot(contains('error:')));
  });

  test('headless: the rate-limit retry is visible as a `[net] rate '
      'limited` notice and the session keeps a `429_retry` record', () async {
    final io = FakeCliIO();

    final cli0 = cli(rateLimitedOnceThenCompletes(), io);
    final exitCode = await cli0.runHeadless('say hi');
    expect(exitCode, 0);

    // The notice names the class — a multi-second pause is never silent
    // and never reads as a connection problem.
    expect(io.out.toString(), contains('[net] rate limited'));
    expect(io.out.toString(), contains('429: Rate limit reached'));

    // The session JSONL carries the post-mortem record.
    final env = cli0.config.env;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    expect(sessions, isNotEmpty);
    final session = await repo.open(sessions.first);
    final retries = [
      for (final record in await session.getEntries())
        if (record is CustomRecord &&
            record.customType == rateLimitRetryRecordType)
          record,
    ];
    expect(retries, hasLength(1));
    final data = retries.single.data as Map;
    // The record keeps the notice contract value: the 1-based attempt
    // that JUST FAILED (here the first one). The faces render
    // attempt + 1 — the retry about to run, "attempt 2/4" — so the
    // transcript, fa.log and this record tell one story.
    expect(data['attempt'], 1);
    expect(data['max_attempts'], 1 + maxRateLimitRetries);
    expect(data['reason'], contains('429'));
  });

  test('headless: rate-limit wording past the 120-char display cap still '
      'faces `[net] rate limited` and records (gh-1602 review)', () async {
    final io = FakeCliIO();
    var calls = 0;
    final stream = (model, context, {cancelToken}) {
      final n = ++calls;
      final stream = AssistantMessageEventStream();
      scheduleMicrotask(() {
        if (n == 1) {
          // The rate-limit wording sits past the display truncation
          // point (a structured JSON-ish error render does this).
          stream
            ..push(StartEvent(partial: testAssistant()))
            ..push(
              ErrorEvent(
                reason: StopReason.error,
                error: testAssistant(
                  stopReason: StopReason.error,
                  errorMessage:
                      '${'structured error payload detail; ' * 10}'
                      '429 rate limit exceeded, back off and retry',
                ),
              ),
            )
            ..end();
          return;
        }
        final tail = testAssistant(
          content: [const TextContent(text: 'recovered')],
        );
        stream
          ..push(StartEvent(partial: testAssistant()))
          ..push(TextStartEvent(contentIndex: 0, partial: testAssistant()))
          ..push(
            TextDeltaEvent(contentIndex: 0, delta: 'recovered', partial: tail),
          )
          ..push(
            TextEndEvent(contentIndex: 0, content: 'recovered', partial: tail),
          )
          ..push(DoneEvent(reason: StopReason.stop, message: tail))
          ..end();
      });
      return stream;
    };

    final cli0 = cli(stream, io);
    final exitCode = await cli0.runHeadless('say hi');

    // The ladder retried under the rate-limit policy — the face and the
    // record must say the same, else run-7 forensics lose the blip.
    expect(exitCode, 0);
    expect(io.out.toString(), contains('[net] rate limited'));
    expect(io.out.toString(), isNot(contains('connection lost')));
    // The transcript line keeps the bounded first line — truncation is
    // display-only.
    expect(io.out.toString(), contains('(structured error payload detail; '));

    final env = cli0.config.env;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    final session = await repo.open(sessions.first);
    final retries = [
      for (final record in await session.getEntries())
        if (record is CustomRecord &&
            record.customType == rateLimitRetryRecordType)
          record,
    ];
    expect(retries, hasLength(1));
  });
}
