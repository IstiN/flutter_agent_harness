import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Focused coverage for the `obligation_mark_done` close path
/// (issue #1380): [AgentCliPersist.closeObligation] lives in the persist
/// extension, and its CRAP score is coverage-bound — the CI quality gate
/// measured 72.00 @ 0% coverage (CC 8, threshold 12.0). Every reachable
/// branch is driven here against a REAL booted session (the writer
/// rehydrates through the raw snapshot scan), mid-run via a scripted
/// stream that probes while the session is open.

/// The user messages the lifecycle test ingests — the listing assertions
/// quote exactly what the rule classifier captures as verbatim spans.
const String _askOne = 'please file the incident report';
const String _askTwo = 'and please also update the dashboard';

final class _ProbedStream {
  _ProbedStream(this.turns);

  /// One turn per model call. The probe list runs, in order, BEFORE the
  /// turn's events are emitted — probes issued in turn N see every
  /// ledger mutation earlier turns' user messages ingested.
  final List<
    (List<Future<String> Function(AgentCli)>, List<AssistantMessageEvent>)
  >
  turns;

  /// Set by the test right after [AgentCli] construction, before `run()`.
  AgentCli? cli;

  int get calls => _calls;
  int _calls = 0;

  final results = <String>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final (probes, events) = turns.removeAt(0);
    _calls++;
    final stream = AssistantMessageEventStream();
    unawaited(() async {
      for (final probe in probes) {
        results.add(await probe(cli!));
      }
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }());
    return stream;
  }
}

AgentCli _bootCli({
  required MemoryExecutionEnv env,
  required FakeCliIO io,
  required _ProbedStream stream,
}) {
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: 'test-key',
      env: env,
      sessionRoot: '/sessions',
      providerKind: 'openai-completions',
    ),
    io: io,
    streamFunction: stream.call,
  );
  stream.cli = cli;
  return cli;
}

/// Runs one scripted conversation: the first user line goes out once the
/// session has materialized (a line sent before the REPL listens is
/// buffered, but the session must exist before the first probes run),
/// each next line only after the previous model call settled, then the
/// session ends cleanly. Returns the probe results in issue order.
Future<List<String>> _runConversation(
  MemoryExecutionEnv env,
  FakeCliIO io,
  _ProbedStream stream, {
  required List<String> userLines,
}) async {
  final run = _bootCli(env: env, io: io, stream: stream).run();
  await waitForIt(() async {
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    return (await repo.list(cwd: '/work')).isNotEmpty;
  }, reason: 'the session to materialize');
  for (var i = 0; i < userLines.length; i++) {
    if (i > 0) {
      await waitForIt(
        () => stream.calls >= i,
        reason: 'turn $i to settle before the next user line',
      );
    }
    io.sendLine(userLines[i]);
  }
  await waitForIt(
    () => stream.calls >= userLines.length,
    reason: 'every scripted turn to run',
  );
  io.sendLine('/exit');
  await run;
  return stream.results;
}

void main() {
  late MemoryExecutionEnv env;
  late FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work');
    io = FakeCliIO();
  });

  tearDown(() => io.close());

  test(
    'close without a session reports the empty ledger, not an error',
    () async {
      // Never booted: _session is null — the first branch of the close path.
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: FakeCliIO(),
        streamFunction: FakeStreamFunction(const []).call,
      );
      expect(
        await cli.closeObligation('obl-x', 'done'),
        'no session is open — the ledger is empty',
      );
    },
  );

  test(
    'full lifecycle: discovery, unknown id/status, done + superseded',
    () async {
      // The discovery probe harvests the ingested ids at run time; later
      // probes in the SAME sequential list read them.
      final ids = <String>[];
      final stream = _ProbedStream([
        // Turn 1: cold writer rehydrates an EMPTY ledger — discovery with
        // nothing open.
        ([(cli) => cli.closeObligation('', 'done')], textTurn('ack one')),
        // Turns 2-3: two real user asks the rule classifier ingests.
        (const [], textTurn(_askOne)),
        (const [], textTurn(_askTwo)),
        // Turn 4: every remaining branch, in order.
        (
          [
            (cli) async {
              final listing = await cli.closeObligation('', 'done');
              ids.addAll(
                RegExp(
                  r'[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}',
                ).allMatches(listing).map((m) => m.group(0)!).toList(),
              );
              return listing;
            },
            (cli) => cli.closeObligation('obl-nope', 'done'),
            (cli) => cli.closeObligation(ids.first, 'emergency'),
            (cli) => cli.closeObligation(ids.first, 'done'),
            (cli) => cli.closeObligation(ids.last, 'superseded'),
          ],
          textTurn('ack four'),
        ),
      ]);

      final results = await _runConversation(
        env,
        io,
        stream,
        userLines: ['begin', _askOne, _askTwo, 'go'],
      );
      expect(results, hasLength(6));
      // Empty-ledger discovery.
      expect(results[0], 'no open obligations.');
      // Listing after two ingested asks: both ids, verbatim clipped quotes.
      final listing = results[1];
      expect(
        listing,
        startsWith('open obligations (close with {"id": "..."}):'),
      );
      expect(ids, hasLength(2));
      expect(listing, contains('[open-ask] $_askOne'));
      expect(listing, contains('[open-ask] $_askTwo'));
      // Unknown id — the ledger has entries, so the open-ids list is shown.
      expect(
        results[2],
        'no obligation carries id obl-nope. Open ids: ${ids.first}, '
        '${ids.last}',
      );
      // Unknown status.
      expect(results[3], 'unknown status "emergency" (use done or superseded)');
      // done + superseded both persist; the remaining-open count follows.
      expect(
        results[4],
        '${ids.first} marked done. 1 open obligation(s) remain.',
      );
      expect(
        results[5],
        '${ids.last} marked superseded. 0 open obligation(s) remain.',
      );
    },
  );

  test('unknown id on an empty ledger names the (none) open-id list', () async {
    final stream = _ProbedStream([
      // A plain reply: the rule classifier ingests nothing.
      (const [], textTurn('plain reply')),
      (const [], textTurn('ack')),
      ([(cli) => cli.closeObligation('obl-gone', 'done')], textTurn('ack two')),
    ]);
    final results = await _runConversation(
      env,
      io,
      stream,
      userLines: ['hello', 'again', 'go'],
    );
    expect(
      results.single,
      'no obligation carries id obl-gone. Open ids: (none)',
    );
  });
}
