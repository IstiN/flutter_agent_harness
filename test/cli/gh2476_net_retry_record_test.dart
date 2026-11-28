// gh-2476: every replayed provider attempt leaves a per-attempt session
// record — the always-on post-mortem surface, independent of
// `FA_CONN_DEBUG`. A transport-class replay (connection reset, then
// recover) through a headless run must keep a `net_retry` record carrying
// the attempt facts (attempt/max/delay) and the provider's own detail —
// the `429_retry` record stays rate-limit-only (gh-1602 shape unchanged).
@TestOn('vm')
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

TransientRetryNotice? savedNotice2476;
Future<bool> Function(Duration, CancelToken?)? savedSleeper2476;
Duration? Function()? savedDeadline2476;

const String netRetryRecordType = 'net_retry';

StreamFunction resetOnceWithProviderDetailThenCompletes() {
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
              error: testAssistant(
                stopReason: StopReason.error,
                errorMessage:
                    '502: upstream exploded (org acme, '
                    'trace 9f2) — provider said: '
                    '{"error":{"message":"bad gateway at edge-eu1"}}',
              ),
            ),
          )
          ..end();
        return;
      }
      final tail = testAssistant(
        content: [const TextContent(text: 'the answer after the reset')],
      );
      stream
        ..push(StartEvent(partial: testAssistant()))
        ..push(TextStartEvent(contentIndex: 0, partial: testAssistant()))
        ..push(
          TextDeltaEvent(
            contentIndex: 0,
            delta: 'the answer after the reset',
            partial: tail,
          ),
        )
        ..push(
          TextEndEvent(
            contentIndex: 0,
            content: 'the answer after the reset',
            partial: tail,
          ),
        )
        ..push(DoneEvent(reason: StopReason.stop, message: tail))
        ..end();
    });
    return stream;
  };
}

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

void main() {
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
      apiKey: 'k',
      env: MemoryExecutionEnv(cwd: '/work'),
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: transientRetryStreamFunction(stream),
  );

  setUp(() {
    savedSleeper2476 = transientRetrySleeper;
    savedNotice2476 = transientRetryNotice;
    savedDeadline2476 = transientRetryDeadlineLeft;
    transientRetrySleeper = (delay, token) async => true;
    transientRetryDeadlineLeft = null;
  });
  tearDown(() {
    transientRetrySleeper = savedSleeper2476!;
    transientRetryNotice = savedNotice2476;
    transientRetryDeadlineLeft = savedDeadline2476;
  });

  test('headless: a transport replay keeps an always-on net_retry record '
      'with the provider detail and the HTTP status', () async {
    final io = FakeCliIO();
    final cli0 = cli(resetOnceWithProviderDetailThenCompletes(), io);

    final exitCode = await cli0.runHeadless('say hi');
    expect(exitCode, 0, reason: 'the blip must not kill the run');

    final env = cli0.config.env;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    expect(sessions, isNotEmpty);
    final session = await repo.open(sessions.first);
    final retries = [
      for (final record in await session.getEntries())
        if (record is CustomRecord && record.customType == netRetryRecordType)
          record,
    ];
    expect(retries, hasLength(1), reason: 'one transport replay, one record');
    final data = retries.single.data as Map;
    expect(data['attempt'], 1);
    expect(data['status'], 502);
    // The provider's own detail rides the record, not just the literal.
    expect((data['reason'] as String), contains('bad gateway at edge-eu1'));
    expect(data['ts'], isNotNull);
  });

  test('headless: a rate-limit replay still records `429_retry`, not '
      '`net_retry` (the gh-1602 shape stays)', () async {
    final io = FakeCliIO();
    final cli0 = cli(rateLimitedOnceThenCompletes(), io);

    final exitCode = await cli0.runHeadless('say hi');
    expect(exitCode, 0);

    final env = cli0.config.env;
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final sessions = await repo.list(cwd: '/work');
    final session = await repo.open(sessions.first);
    final byType = <String, int>{};
    for (final record in await session.getEntries()) {
      if (record is CustomRecord) {
        byType[record.customType] = (byType[record.customType] ?? 0) + 1;
      }
    }
    expect(byType[rateLimitRetryRecordType], 1);
    expect(byType[netRetryRecordType], isNull);
  });
}
