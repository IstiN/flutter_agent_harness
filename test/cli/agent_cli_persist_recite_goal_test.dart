import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Focused coverage for the `recite_goal` persist path (gh-210):
/// [AgentCliPersist.reciteGoal] / [AgentCliPersist.currentGoalRecitation]
/// live in the persist extension, and their CRAP score is coverage-bound
/// (the close-obligation precedent). Every reachable branch is driven
/// here against a REAL booted session, mid-run via a scripted stream.

final class _ProbedStream {
  _ProbedStream(this.turns);

  final List<
    (List<Future<String> Function(AgentCli)>, List<AssistantMessageEvent>)
  >
  turns;

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
  required ExecutionEnv env,
  required FakeCliIO io,
  required _ProbedStream stream,
}) {
  final cli = AgentCli(
    config: AgentCliConfig(
      model: testModel,
      apiKey: '[REDACTED:Sensitive-Value]',
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

Future<List<String>> _runConversation(
  ExecutionEnv env,
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
    'recite without a session reports the missing slot, not an error',
    () async {
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
        ),
        io: FakeCliIO(),
        streamFunction: FakeStreamFunction(const []).call,
      );
      final result = await cli.reciteGoal('ship it');
      expect(result, contains('no session is open'));
      expect(await cli.currentGoalRecitation(), isNull);
    },
  );

  test('recite lands the snapshot; discovery reads it back', () async {
    final stream = _ProbedStream([
      (
        [
          (cli) => cli.reciteGoal('fix the login crash, then the changelog'),
          (cli) => cli.reciteGoal(''),
        ],
        textTurn('ack one'),
      ),
      (
        [
          (cli) async {
            final slot = await cli.currentGoalRecitation();
            return slot?.goal ?? '(empty)';
          },
        ],
        textTurn('ack two'),
      ),
    ]);
    final results = await _runConversation(
      env,
      io,
      stream,
      userLines: ['please start', 'and continue'],
    );
    expect(results[0], contains('goal recited'));
    expect(results[1], contains('current goal: fix the login crash'));
    // The projection tail renders the slot.
    final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    final meta = (await repo.list(cwd: '/work')).first;
    final session = await repo.open(meta);
    final messages = await session.buildContextMessages();
    final last = messages.last as UserMessage;
    expect(last.content, contains('goal: fix the login crash'));
  });

  test('discovery before any recite points at how to set the goal', () async {
    final stream = _ProbedStream([
      ([(cli) => cli.reciteGoal('')], textTurn('ack one')),
    ]);
    final results = await _runConversation(
      env,
      io,
      stream,
      userLines: ['please start'],
    );
    expect(results[0], contains('no goal recited'));
  });

  test('an oversized goal re-bounds at the persist layer', () async {
    final stream = _ProbedStream([
      (
        [(cli) => cli.reciteGoal('g' * (goalRecitationBudgetChars + 500))],
        textTurn('ack one'),
      ),
      (
        [(cli) async => '${(await cli.currentGoalRecitation())!.goal.length}'],
        textTurn('ack two'),
      ),
    ]);
    final results = await _runConversation(
      env,
      io,
      stream,
      userLines: ['please start', 'and continue'],
    );
    expect(results[0], contains('goal recited'));
    expect(int.parse(results[1]), lessThanOrEqualTo(goalRecitationBudgetChars));
  });

  test('a failed append returns the failure to the agent', () async {
    final faultEnv = _FaultEnv(env);
    final stream = _ProbedStream([
      ([(cli) => cli.reciteGoal('lands fine')], textTurn('ack one')),
      (
        [
          (cli) async {
            // Arm the injected append fault: the persist path must
            // RETURN the failure — never throw it into the run.
            faultEnv.arm = true;
            final outcome = await cli.reciteGoal('must fail');
            faultEnv.arm = false;
            return outcome;
          },
        ],
        textTurn('ack two'),
      ),
    ]);
    final results = await _runConversation(
      faultEnv,
      io,
      stream,
      userLines: ['please start', 'and continue'],
    );
    expect(results[0], contains('goal recited'));
    expect(results[1], contains('reciting the goal failed'));
  });
}

/// An [ExecutionEnv] that can fail every append on demand — the injected
/// fault the append-failure branch of the persist path exercises.
final class _FaultEnv extends ForwardingFs {
  _FaultEnv(super.delegate);

  /// When true, every `appendFile` fails with a permission error.
  bool arm = false;

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) {
    if (arm) {
      return Future.value(
        Err(
          const FileError(
            FileErrorCode.permissionDenied,
            'injected append fault',
          ),
        ),
      );
    }
    return delegate.appendFile(path, content);
  }
}
