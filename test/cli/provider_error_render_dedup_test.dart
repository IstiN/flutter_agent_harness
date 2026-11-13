import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Issue #2119 AC1/AC4/AC5: provider failures render ONE classified,
/// deduplicated console line while the raw payload stays reachable at the
/// diagnostic surface.
///
/// AC1 dedup root, named per the acceptance: the two renderers that can
/// print one failure twice are (a) `_onAssistantMessageEnd`
/// (lib/src/cli/approval_commands.dart) — the error AssistantMessage's
/// message-record line — and (b) `_handleRunError`
/// (lib/src/cli/agent_cli_run.dart) + the headless catch
/// (lib/src/cli/agent_cli.dart) — the thrown run-error line. Both route
/// through the shared `_renderProviderError` choke point, whose episode
/// key (category + compacted message) collapses their overlap. The loop
/// itself emits one error message per failed leg (verified against the
/// real openai-completions adapter: a content_filter stream pushes exactly
/// one ErrorEvent), so a stall-then-retry sequence — the retry arriving as
/// a queued continuation the loop runs after a failed leg — re-dies with
/// the same text and MUST NOT print a second raw dump (asserted below
/// through the real AgentCli + scripted-stream harness).
void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() async {
    await io.close();
  });

  AssistantMessage errorAssistant(String message) => AssistantMessage(
    content: const [],
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: StopReason.error,
    errorMessage: message,
    timestamp: DateTime.utc(2026),
  );

  List<AssistantMessageEvent> errorTurn(String message) => [
    StartEvent(partial: testAssistant()),
    DoneEvent(reason: StopReason.error, message: errorAssistant(message)),
  ];

  /// A scripted provider: every call fails with the NEXT text of
  /// [failuresByCall] (the last repeats). [holdFirstFor] keeps the FIRST
  /// leg's stream open that long, so a message sent while it runs lands as
  /// mid-run steering and rides the loop's continuation leg — the
  /// stall-then-retry shape.
  ({AgentCli cli, int Function() calls}) buildCli(
    List<String> failuresByCall, {
    String? homeDir,
    Duration holdFirstFor = Duration.zero,
  }) {
    final callBox = <int>[0];
    final cli = AgentCli(
      config: AgentCliConfig(
        model: const Model(
          id: 'test-model',
          api: 'test-api',
          provider: 'test-provider',
          baseUrl: 'https://example.test',
          contextWindow: 128000,
          maxTokens: 4096,
        ),
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        homeDir: homeDir,
      ),
      io: io,
      streamFunction: (model, context, {cancelToken}) {
        final s = AssistantMessageEventStream();
        final call = callBox[0]++;
        final failure = call < failuresByCall.length
            ? failuresByCall[call]
            : failuresByCall.last;
        void emit() {
          for (final event in errorTurn(failure)) {
            s.push(event);
          }
          s.end();
        }

        if (call == 0 && holdFirstFor > Duration.zero) {
          unawaited(Future<void>.delayed(holdFirstFor).then((_) => emit()));
        } else {
          emit();
        }
        return s;
      },
    );
    return (cli: cli, calls: () => callBox[0]);
  }

  Future<void> waitForSessions(MemoryExecutionEnv env) async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    for (var i = 0; i < 5000; i++) {
      if ((await repo.list(cwd: '/work')).isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting: session persisted');
  }

  /// Race-free pacing against the provider-call count (never `isBusy`:
  /// an instant fake settles between polls). The run has STARTED at
  /// `calls >= n`; wait the settle after it.
  Future<void> sendRunSettle(
    AgentCli cli,
    int Function() calls,
    String line,
    int expectedCallAfter,
    String label,
  ) async {
    io.sendLine(line);
    await waitForIt(() => calls() >= expectedCallAfter, reason: '$label runs');
    await waitForIt(() => !cli.isBusy, reason: '$label settles');
  }

  test('AC2/AC5: a content_filter failure renders ONE classified line — '
      'category, endpoint, one recovery, `error:` grammar — and the raw '
      'dump stays out of the console', () async {
    final built = buildCli(['Provider finish_reason: content_filter']);
    final cli = built.cli;
    final run = cli.run();
    await waitForSessions(env);

    await sendRunSettle(cli, built.calls, 'hello', 1, 'run');
    io.sendLine('/exit');
    await run;

    final lines = io.out
        .toString()
        .split('\n')
        .where(
          (l) => l.contains('content filter') || l.contains('finish_reason'),
        )
        .toList();
    expect(lines, hasLength(1), reason: 'exactly ONE console error line');
    // The idle prompt may echo on the same line (`fa> `); the line GRAMMAR
    // (AC5) is the `error: ` prefix + single line.
    expect(lines.single, contains('error: content filter:'));
    expect(lines.single, contains('(test-provider/test-model)'));
    expect(lines.single, contains('rephrase the request or switch models'));
    expect(
      io.out.toString(),
      isNot(contains('Provider finish_reason')),
      reason: 'the raw dump is demoted off the console',
    );
  });

  test('AC1 stall-then-retry: a continuation leg re-dying with the SAME '
      'failure renders ONE notice, not a second raw dump', () async {
    const filter = 'Provider finish_reason: content_filter';
    final built = buildCli([
      filter,
      filter,
    ], holdFirstFor: const Duration(milliseconds: 300));
    final cli = built.cli;
    final run = cli.run();
    await waitForSessions(env);

    // Leg 1 is held open; the message lands as mid-run steering and the
    // loop runs it as a continuation leg — which dies the SAME way.
    io.sendLine('first');
    await waitForIt(() => built.calls() >= 1, reason: 'leg 1 runs');
    io.sendLine('second');
    await waitForIt(() => !cli.isBusy, reason: 'the whole run settles');
    io.sendLine('/exit');
    await run;

    final lines = io.out
        .toString()
        .split('\n')
        .where((l) => l.contains('content filter'))
        .toList();
    expect(lines, hasLength(1), reason: 'ONE classified notice for both legs');
  });

  test('AC1: a user re-invoked prompt renders honestly again; a DISTINCT '
      'failure always renders (no blind merging)', () async {
    const filter = 'Provider finish_reason: content_filter';
    final built = buildCli([
      filter,
      filter, // new episode: the user re-invoked the same request
      '429: rate limit exceeded', // distinct failure
      filter, // after a different failure, the filter line renders again
    ]);
    final cli = built.cli;
    final calls = built.calls;
    final run = cli.run();
    await waitForSessions(env);

    await sendRunSettle(cli, calls, 'first', 1, 'run 1');
    await sendRunSettle(cli, calls, 'second', 2, 'run 2');
    await sendRunSettle(cli, calls, 'third', 3, 'run 3');
    await sendRunSettle(cli, calls, 'fourth', 4, 'run 4');

    io.sendLine('/exit');
    await run;

    final out = io.out.toString();
    final filterLines = out
        .split('\n')
        .where((l) => l.contains('content filter'));
    final rateLines = out.split('\n').where((l) => l.contains('rate limit'));
    expect(filterLines, hasLength(3), reason: 'episodes 1, 2 and 4');
    expect(rateLines, hasLength(1), reason: 'the distinct failure renders');
  });

  test('AC4: the raw provider payload is reachable at the diagnostic '
      'surface (fa.log), default level, no content lost', () async {
    final built = buildCli([
      'Provider finish_reason: content_filter',
    ], homeDir: '/home');
    final cli = built.cli;
    final run = cli.run();
    await waitForSessions(env);

    await sendRunSettle(cli, built.calls, 'hello', 1, 'run');
    io.sendLine('/exit');
    await run;
    await cli.flushDiagnosticLog();

    final log = await env.readTextFile('/home/.fah/logs/fa.log');
    expect(log.valueOrNull, contains('provider error raw'));
    expect(log.valueOrNull, contains('Provider finish_reason: content_filter'));
  });

  test('the unclassified passthrough keeps today\'s raw text (border '
      'case)', () async {
    final built = buildCli(['Provider finish_reason: vendor_gibberish']);
    final cli = built.cli;
    final run = cli.run();
    await waitForSessions(env);

    await sendRunSettle(cli, built.calls, 'hello', 1, 'run');
    io.sendLine('/exit');
    await run;

    expect(
      io.out.toString(),
      contains('error: Provider finish_reason: vendor_gibberish'),
    );
  });
}
