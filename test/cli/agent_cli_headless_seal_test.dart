@TestOn('vm')
library;

/// gh-1589 (UT-2/UT-3/IT-2): the headless seal — the settle→reaction path
/// is sealed with the file (I2). After the final answer's drain completes,
/// a background-shell settle does bookkeeping ONLY: board terminal state,
/// waiting-row leave, the `[bash]` diagnostic — no `_startRun`, no model
/// request, no session-JSONL append. The seal closes the file in the
/// `runHeadless` finally AFTER the usage fold and the job-board flush
/// (REG-2 close order: drain → usage fold → seal → exit), so every record
/// on disk precedes process exit (AC3) while records written during an
/// honest drain (E7) stay legal.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/headless_config.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [Shell] + [BackgroundShell] whose detached jobs stay RUNNING until
/// the test finishes them with an explicit exit code.
class _SealShell implements Shell, BackgroundShell {
  final jobs = <_SealJob>[];

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async => Err(
    ExecutionError(
      ExecutionErrorCode.shellUnavailable,
      'No shell is available in this environment',
    ),
  );

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _SealJob(id: id, command: command, logPath: logPath);
    jobs.add(job);
    return Ok(job);
  }
}

final class _SealJob implements ShellJob {
  _SealJob({
    required this.id,
    required this.command,
    required this.logPath,
  });

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

  int? _exitCode;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_settled.isCompleted;
  @override
  int? get exitCode => _exitCode;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  void finish(int code) {
    if (_settled.isCompleted) return;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Future<void> stop() async => finish(9);
}

/// Routes every run by its last user message: the settle reaction (and any
/// ILLEGAL post-seal reaction) replays [settleScript] then falls back to
/// 'noted.' so a broken fence shows up as an extra context, not a hang.
class _SealStream {
  _SealStream(this._leadScripts);

  final List<List<AssistantMessageEvent>> _leadScripts;
  final contexts = <Context>[];
  final lastUserTexts = <String>[];
  final continuations = <bool>[];

  String _lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) return messageText(message);
    }
    return '';
  }

  bool _isToolContinuation(Context context) {
    for (final message in context.messages.reversed) {
      if (message is ToolResultMessage) return true;
      if (message is UserMessage) return false;
    }
    return false;
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final last = _lastUserText(context);
    final continuation = _isToolContinuation(context);
    lastUserTexts.add(last);
    continuations.add(continuation);
    final List<AssistantMessageEvent> script;
    if (!continuation && _leadScripts.isNotEmpty) {
      script = _leadScripts.removeAt(0);
    } else {
      script = textTurn('noted.');
    }
    final stream = AssistantMessageEventStream();
    for (final event in script) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

Future<List<SessionRecord>> _recordsOnDisk(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final sessions = await repo.list(cwd: '/work');
  final opened = await repo.open(sessions.single);
  return opened.getEntries();
}

/// Lets the deferred settle listener, the persist chain, and the seal
/// rejection path all run to completion.
Future<void> _pump() async {
  for (var i = 0; i < 6; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

AgentCli _cli({
  required FakeCliIO io,
  required MemoryExecutionEnv env,
  required _SealStream stream,
  required int drainMs,
  required DateTime Function() ledgerClockValue,
}) => AgentCli(
  config: AgentCliConfig(
    model: testModel,
    apiKey: 'key',
    env: env,
    sessionRoot: '/sessions',
    approvalMode: ApprovalMode.yolo,
    headless: HeadlessConfig(shellJobDrainMs: drainMs),
  ),
  io: io,
  streamFunction: stream.call,
  ledgerClock: ledgerClockValue,
);

/// The lead run: start one background job, end the turn.
final _leadScripts = [
  toolTurn([
    const ToolCall(
      id: 't1',
      name: 'bash',
      arguments: {'command': 'sleep 60', 'background': true},
    ),
  ]),
  textTurn('Started the job in the background.'),
];

/// The call-time user text of the settle notice (the reaction payload the
/// fence must never let start a run post-exit).
const _settleMarker = 'finished with exit code';

void main() {
  for (final drainMs in const [50, 0]) {
    group('post-completion settle (shellJobDrainMs: $drainMs)', () {
      late FakeCliIO io;
      late _SealShell shell;
      late _SealStream stream;
      late MemoryExecutionEnv env;
      late AgentCli cli;
      // Controllable ledger clock: advancing it past the 30s persist
      // window guarantees the post-exit settle's board persist REACHES
      // the session writer (throttle open) — the seal itself must be the
      // thing that stops it, not the coalescing window.
      var clock = DateTime.now();

      setUp(() {
        io = FakeCliIO();
        shell = _SealShell();
        stream = _SealStream(List.of(_leadScripts));
        env = MemoryExecutionEnv(cwd: '/work', shell: shell);
        cli = _cli(
          io: io,
          env: env,
          stream: stream,
          drainMs: drainMs,
          ledgerClockValue: () => clock,
        );
      });

      test(
        'a settle after runHeadless completes: bookkeeping only — '
        'no reaction run, no post-exit append, one warning per class',
        () async {
          final exitCode = await cli.runHeadless('start a job');
          expect(exitCode, 0);
          final exitAt = DateTime.now();
          final before = await _recordsOnDisk(env);

          // Open the persist window so the settle's board persist reaches
          // the writer; only the seal can stop it now.
          clock = clock.add(const Duration(seconds: 31));
          shell.jobs.single.finish(0);
          await _pump();

          // I2: no reaction run — the settle never reaches the model.
          // (The lead run's own tool continuation is a fresh run whose
          // payload is NOT the settle notice.)
          final settleRuns = [
            for (var i = 0; i < stream.contexts.length; i++)
              if (!stream.continuations[i] &&
                  stream.lastUserTexts[i].contains(_settleMarker))
                i,
          ];
          expect(
            settleRuns,
            isEmpty,
            reason: 'the settle must do bookkeeping only, never _startRun',
          );

          // I1: the file gained nothing after the seal.
          final after = await _recordsOnDisk(env);
          expect(
            after.length,
            before.length,
            reason: 'no session-JSONL append after the seal',
          );
          for (final record in after) {
            expect(
              record.timestamp.isBefore(exitAt),
              isTrue,
              reason: 'AC3: every record precedes process exit',
            );
          }

          // UT-3: board bookkeeping still ran — the registry row is
          // terminal, never stuck "running".
          expect(cli.shellJobsRegistryForTest.jobs.single.isRunning, isFalse);
        },
      );

      test(
        'the post-exit settle drops the registry snapshot with exactly one '
        'warning, and the persist chain never poisons',
        () async {
          final exitCode = await cli.runHeadless('start a job');
          expect(exitCode, 0);

          clock = clock.add(const Duration(seconds: 31));
          shell.jobs.single.finish(0);
          await _pump();
          await _pump();

          final warnings = io.out
              .toString()
              .split('\n')
              .where((line) => line.contains('dropped late write'))
              .toList();
          expect(warnings, hasLength(1));
          expect(warnings.single, contains('custom:shell_job_registry'));
        },
      );
    });
  }

  test(
    'an honest drain (E7): settle lands mid-drain, the reaction run\'s '
    'records are legal inside the boundary, and the file is byte-stable '
    'after exit',
    () async {      final io = FakeCliIO();
      final shell = _SealShell();
      final stream = _SealStream([
        ...List.of(_leadScripts),
        textTurn('Reaction handled.'),
      ]);
      final env = MemoryExecutionEnv(cwd: '/work', shell: shell);
      final cli = _cli(
        io: io,
        env: env,
        stream: stream,
        drainMs: 2 * 60 * 1000,
        ledgerClockValue: () => DateTime.now(),
      );

      final runFuture = cli.runHeadless('start a job');
      await waitForIt(
        () => shell.jobs.isNotEmpty,
        reason: 'the background job registers',
      );
      // Settle while the drain waits: the settle notice steers a reaction
      // run the drain awaits (E3 — inside the boundary).
      shell.jobs.single.finish(0);
      final exitCode = await runFuture;
      expect(exitCode, 0);

      // The reaction run happened — exactly one settle reaction (the
      // lead run's tool continuation does not count).
      final settleRuns = [
        for (var i = 0; i < stream.contexts.length; i++)
          if (!stream.continuations[i] &&
              stream.lastUserTexts[i].contains(_settleMarker))
            i,
      ];
      expect(settleRuns, hasLength(1));

      final exitAt = DateTime.now();
      final records = await _recordsOnDisk(env);
      expect(records, isNotEmpty);
      for (final record in records) {
        expect(
          record.timestamp.isBefore(exitAt),
          isTrue,
          reason: 'AC3: last record precedes process exit',
        );
      }
      // REG-1-flavored watchdog: the file is byte-stable after exit.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final path = (await repo.list(cwd: '/work')).single.path;
      final snapshotA = (await env.readTextFile(path)).valueOrNull;
      await _pump();
      final snapshotB = (await env.readTextFile(path)).valueOrNull;
      expect(snapshotB, snapshotA, reason: 'no write lands after exit');
      io.close();
    },
  );

  test(
    'REG-2: the REPL quit seals the session with the SAME implementation '
    'and close order as headless',
    () async {
      final io = FakeCliIO();
      final env = MemoryExecutionEnv(cwd: '/work');
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'key',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: FakeStreamFunction([textTurn('repl answer.')]).call,
      );
      final run = cli.run();
      await waitForIt(
        () => !cli.isBusy && io.out.toString().contains('fa>'),
        reason: 'the REPL idles at the prompt',
      );
      // One driven turn: the session exists and has content (a sealed
      // EMPTY session is deleted before the seal, not exercised here).
      io.sendLine('hello');
      await waitForIt(
        () => io.out.toString().contains('repl answer.'),
        reason: 'the turn completes',
      );
      io.sendLine('/exit');
      await run;

      final session = cli.sessionForTest;
      expect(session, isNotNull);
      expect(session!.isSealed, isTrue);
      // The seal is live in the REPL path too: a late append is dropped.
      await session.appendMessage(UserMessage.text('late'));
      expect(
        io.out.toString().split('\n').where(
          (line) => line.contains('dropped late write (message)'),
        ),
        hasLength(1),
      );
      io.close();
    },
  );
}
