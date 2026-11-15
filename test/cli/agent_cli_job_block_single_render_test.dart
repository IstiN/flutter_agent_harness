/// Issue #2118 — one background bash job = ONE stable settle block in the
/// TUI, no duplicate command echo, two sequential jobs render two disjoint
/// blocks.
///
/// The duplicate source (named, pinned by AC1): `AgentCliShellJobSettle
/// ._onShellJobSettled` (agent_cli_waiting.dart) echoed the settle notice
/// into the TUI transcript via `_tuiController?.sendOutput` right after the
/// job-board drain had painted the settle card — the card already carries
/// id, exit code, command and log path, so the echo painted the same
/// command a SECOND time one row below it (`> ⚙ Command: …`), the issue's
/// "same command line printed repeatedly with changing state markers".
///
/// Pinned here:
/// - AC1: the TUI settle material is the card + the `[bash] … exited` line
///   — no notice quote, one command echo — while the model-facing notice
///   still steers (byte-identical text, unchanged path).
/// - AC2: two sequential jobs → exactly two disjoint settle blocks at the
///   write-sequence level (line mode captures the exact byte stream the
///   arbiter consumes), ordered, no cross-job bleed, no duplicate card.
/// - AC5: the settle writer mix (card + exited line + live-region push +
///   steering notice) through the arbiter paints single-source rows — no
///   glued rows (the #2094 proof shape).
/// - AC4 guards live in the untouched headless suites: the settle-notice
///   text (shell_jobs_test.dart), the headless drain lines
///   (agent_cli_headless_shell_job_drain_test.dart) and the `[bash]` line
///   (agent_cli_single_render_test.dart E2) — the removed echo was
///   TUI-only (`_tuiController` is null headless), so those bytes cannot
///   move; the suites still run as the regression fence.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [Shell] + [BackgroundShell] whose jobs are born already-settled: the
/// deterministic fake clock — the registry's `onSettled` fires one event-
/// loop tick after start, so the settle card, the `[bash]` line and the
/// steered notice land in a fixed order without real processes.
class _FakeBgShell implements Shell, BackgroundShell {
  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Err(
      ExecutionError(
        ExecutionErrorCode.shellUnavailable,
        'No shell is available in this environment',
      ),
    );
  }

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    return Ok(_FakeJob(id: id, command: command, logPath: logPath));
  }
}

final class _FakeJob implements ShellJob {
  _FakeJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;
  @override
  bool get isRunning => false;
  @override
  int? get exitCode => 0;
  @override
  Future<void> get settled => Future.value();
  @override
  String? get stopReason => null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;
  @override
  Future<void> stop() async {}
}

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

/// SGR + cursor/control sequences out, then runs of spaces collapsed: the
/// alt-screen renderer may emit a row as diff spans, so the visible-cells
/// comparison rides normalized text.
String _normalize(String s) => s
    .replaceAll(RegExp('\x1b\\[[0-9;?]*[a-zA-Z]'), '')
    .replaceAll(RegExp(' +'), ' ');

AgentCli _tuiCli(
  CliIO io,
  MemoryExecutionEnv env,
  TuiProgramHooks hooks,
  FakeStreamFunction stream,
) => AgentCli(
  config: AgentCliConfig(
    model: testModel,
    apiKey: '[REDACTED:Sensitive-Value]',
    env: env,
    sessionRoot: '/sessions',
    approvalMode: ApprovalMode.yolo,
    skillsAccess: SkillsAccess.granted,
    tuiProgramHooks: hooks,
  ),
  io: io,
  useTui: true,
  streamFunction: stream.call,
);

void main() {
  test(
    'AC1: one TUI job lifecycle renders the settle card once and never '
    'echoes the settle notice — one command echo total (the duplicate '
    'source: the notice echo in AgentCliShellJobSettle._onShellJobSettled)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      addTearDown(keys.close);
      final io = FakeCliIO();
      final env = MemoryExecutionEnv(cwd: '/work', shell: _FakeBgShell());
      final stream = FakeStreamFunction([
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'bash',
            arguments: {'command': 'sleep 9', 'background': true},
          ),
        ]),
        textTurn('job started'),
        // The settle notice steers a reaction run; keep a turn ready.
        textTurn('acknowledged'),
        textTurn('idle'),
      ]);
      final cli = _tuiCli(
        io,
        env,
        TuiProgramHooks(
          input: keys.stream,
          output: frames,
          width: 80,
          height: 24,
        ),
        stream,
      );
      final run = cli.run();
      try {
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'the TUI boot reached the frame renderer',
        );
        keys.add(utf8.encode('start a background job'));
        keys.add([0x0d]);

        // The completion block paints exactly once: the settle card with
        // the truthful headline…
        await waitForIt(
          () => _normalize(
            frames.text,
          ).contains('bash task completed in background'),
          reason: 'the settle card painted',
        );
        // …and the headless-pinned settle line stays TUI-visible (AC4: the
        // line is byte-identical on the headless stderr and still the live
        // notice carrier in the TUI).
        expect(
          _normalize(frames.text).contains('[bash] sh-1-'),
          isTrue,
          reason: 'the [bash] exited line is the settle notice carrier',
        );

        // AC1 — the echo is GONE: no notice quote rows below the card. The
        // `Command:` line exists only in the echoed notice (the card body
        // carries the bare command), and the guidance line only in the
        // notice body. Pre-fix both painted via
        // `AgentCliShellJobSettle._onShellJobSettled`'s sendOutput — the
        // duplicate emitter this test pins.
        final glass = _normalize(frames.text);
        expect(
          glass.contains('Command: sleep 9'),
          isFalse,
          reason:
              'the settle-notice echo painted the command a second time '
              '(duplicate source: AgentCliShellJobSettle._onShellJobSettled) '
              '--- frames ---\n$glass',
        );
        expect(
          glass.contains('Check the result with bash_job'),
          isFalse,
          reason: 'the notice body must not paint into the transcript',
        );
        expect(
          glass.contains('Background shell job sh-1-'),
          isFalse,
          reason: 'the notice header must not paint into the transcript',
        );

        // AC4 (model-facing): the notice still reaches the model with its
        // exact shape — steered as the reaction-run prompt.
        await waitForIt(
          () => stream.contexts.any(
            (context) => context.messages.any(
              (message) =>
                  message is UserMessage &&
                  messageText(message).contains('Background shell job sh-1-') &&
                  messageText(message).contains('Command: sleep 9'),
            ),
          ),
          reason: 'the settle notice still steers the model',
        );

        keys.add([0x03]);
        keys.add([0x03]);
        await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      } finally {
        await io.close();
        await keys.close();
      }
    },
  );

  test(
    'AC2: two sequential jobs render two disjoint settle blocks at the '
    'write-sequence level — ordered, one card each, no cross-job bleed',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final io = FakeCliIO();
      final env = MemoryExecutionEnv(cwd: '/work', shell: _FakeBgShell());
      final cli = AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: '[REDACTED:Sensitive-Value]',
          env: env,
          sessionRoot: '/sessions',
          approvalMode: ApprovalMode.yolo,
        ),
        io: io,
        streamFunction: FakeStreamFunction([
          toolTurn([
            const ToolCall(
              id: 'a1',
              name: 'bash',
              arguments: {'command': 'sleep 21', 'background': true},
            ),
          ]),
          textTurn('first job started'),
          toolTurn([
            const ToolCall(
              id: 'b1',
              name: 'bash',
              arguments: {'command': 'sleep 22', 'background': true},
            ),
          ]),
          textTurn('second job started'),
          textTurn('acknowledged both'),
          textTurn('idle'),
        ]).call,
      );
      final run = cli.run();
      try {
        io.sendLine('start two background jobs in sequence');
        await waitForIt(
          () =>
              'bash task completed in background'
                  .allMatches(io.out.toString())
                  .length >=
              2,
          reason: 'both settle cards painted',
        );
        await waitForIt(() => !cli.isBusy, reason: 'all runs settled');

        final out = io.out.toString();
        // Exactly two completion blocks — one per job, never a duplicate
        // card for the same lifecycle (the board drains emit-once).
        expect(
          'bash task completed in background'.allMatches(out).length,
          2,
          reason: '--- console output ---\n$out',
        );

        // Block A strictly precedes block B, and the exited line of each
        // job sits BETWEEN its own card and the next card's headline — the
        // write sequence is [cardA … └─][bash A][cardB … └─][bash B].
        final cardA = out.indexOf('bash task completed in background');
        final bodyA = out.indexOf('sleep 21', cardA);
        final exitedA = out.indexOf('[bash] sh-1-');
        final cardB = out.indexOf(
          'bash task completed in background',
          cardA + 1,
        );
        final bodyB = out.indexOf('sleep 22', cardB);
        final exitedB = out.indexOf('[bash] sh-2-');
        expect(cardA, greaterThan(-1));
        expect(bodyA, greaterThan(cardA));
        expect(exitedA, greaterThan(bodyA));
        expect(cardB, greaterThan(exitedA));
        expect(bodyB, greaterThan(cardB));
        expect(exitedB, greaterThan(bodyB));
        // No cross-job bleed: job A's material never carries job B's
        // command, and each command echoes exactly once in the settle
        // material (inside its own card body only).
        final blockA = out.substring(cardA, exitedA);
        final blockB = out.substring(cardB, exitedB);
        expect(blockA.contains('sleep 22'), isFalse);
        expect(blockB.contains('sleep 21'), isFalse);
        // One command echo per lifecycle: the card body only — the notice
        // echo would add a `> ⚙ Command: …` row (TUI-only, asserted in the
        // frame tests above/below).
        expect(
          'Command:'.allMatches(out).length,
          0,
          reason: 'the notice echo never fires without a TUI',
        );

        io.sendLine('/exit');
        await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      } finally {
        await io.close();
      }
    },
  );

  test(
    'AC2b: two sequential jobs in the TUI paint two settle cards and no '
    'notice echo (redraw stays disjoint — captured frames pass)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      addTearDown(keys.close);
      final io = FakeCliIO();
      final env = MemoryExecutionEnv(cwd: '/work', shell: _FakeBgShell());
      final cli = _tuiCli(
        io,
        env,
        TuiProgramHooks(
          input: keys.stream,
          output: frames,
          width: 80,
          height: 24,
        ),
        FakeStreamFunction([
          toolTurn([
            const ToolCall(
              id: 'a1',
              name: 'bash',
              arguments: {'command': 'sleep 21', 'background': true},
            ),
          ]),
          textTurn('first job started'),
          toolTurn([
            const ToolCall(
              id: 'b1',
              name: 'bash',
              arguments: {'command': 'sleep 22', 'background': true},
            ),
          ]),
          textTurn('second job started'),
          textTurn('acknowledged both'),
          textTurn('idle'),
        ]),
      );
      final run = cli.run();
      try {
        await waitForIt(
          () => frames.text.contains('\x1b[?1049h'),
          reason: 'the TUI boot reached the frame renderer',
        );
        keys.add(utf8.encode('run job one'));
        keys.add([0x0d]);
        await waitForIt(
          () => _normalize(
            frames.text,
          ).contains('bash task completed in background'),
          reason: 'the first settle card painted',
        );
        keys.add(utf8.encode('run job two'));
        keys.add([0x0d]);
        await waitForIt(
          () => _normalize(frames.text).contains('sleep 22'),
          reason: 'the second job started',
        );
        await waitForIt(
          () => _normalize(frames.text).contains('[bash] sh-2-'),
          reason: 'the second settle line painted',
        );

        final glass = _normalize(frames.text);
        // Both blocks landed; the echo died for both lifecycles.
        expect(glass.contains('bash task completed in background'), isTrue);
        expect(glass.contains('sleep 21'), isTrue);
        expect(glass.contains('sleep 22'), isTrue);
        expect(glass.contains('Command:'), isFalse);
        expect(glass.contains('Background shell job sh-'), isFalse);

        keys.add([0x03]);
        keys.add([0x03]);
        await run.timeout(const Duration(seconds: 10), onTimeout: () {});
      } finally {
        await io.close();
        await keys.close();
      }
    },
  );

  // ── AC5 (arbiter parity): the settle writer mix — job settle card,
  // exited line, live-region push, steering notice, busy-phase tick —
  // rides the ONE output arbiter (#2069), so no painted row carries
  // glyphs from two writers (the #2094 proof shape, model level).
  test('AC5: the settle writer mix keeps every glass row single-source', () {
    FaTuiModel model = FaTuiModel(
      callbacks: FaTuiCallbacks(
        onSubmit: (line, {images = const []}) async {},
        onSteer: (messages) async {},
        onModelSelected: (_) async {},
        buildSlashMenu: (_) => const [],
        buildModelMenu: (_, _) => const [],
        statusLine: () => 'test',
        prompt: 'fa> ',
      ),
      isExited: () => false,
    );
    model = model.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    // An unterminated streamed delta — the open tail the arbiter guards.
    model =
        model.update(OutputMsg('streamed answer tail mid-word')).$1
            as FaTuiModel;
    // The settle writer mix (the exact write shape of one job settle):
    // card lines, the exited line, the live-region push, a steering
    // notice, and a busy-phase footer tick — all newline-terminated units.
    model =
        model
                .update(
                  OutputMsg('\n┌─ bash task completed in background (0s)\n'),
                )
                .$1
            as FaTuiModel;
    model = model.update(OutputMsg('│ sleep 9\n')).$1 as FaTuiModel;
    model = model.update(OutputMsg('└──\n')).$1 as FaTuiModel;
    model =
        model
                .update(
                  OutputMsg(
                    '\n[bash] sh-1-x exited(0) — .fah/bash_jobs/sh-1-x.log\n',
                  ),
                )
                .$1
            as FaTuiModel;
    model =
        model.update(const JobBoardMsg(['↳ sh-2-y · other job'])).$1
            as FaTuiModel;
    model =
        model
                .update(
                  OutputMsg(
                    '\nsteering — settle notice delivered into rebuilt request\n',
                  ),
                )
                .$1
            as FaTuiModel;
    model =
        model
                .update(
                  BusyMsg(true, source: 'run', phase: 'Compacting context…'),
                )
                .$1
            as FaTuiModel;

    final rows = model.view().content.split('\n');
    for (final row in rows) {
      final sources = [
        if (row.contains('streamed answer tail')) 'delta',
        if (row.contains('bash task completed')) 'card',
        if (row.contains('sleep 9')) 'card',
        if (row.contains('[bash] sh-1-x')) 'exited',
        if (row.contains('other job')) 'job-board',
        if (row.contains('steering —')) 'notice',
        if (row.contains('Compacting context…')) 'busy-label',
      ];
      expect(
        sources.toSet().length,
        lessThanOrEqualTo(1),
        reason:
            'a glass row merged two writers: '
            '"${row.length > 90 ? row.substring(0, 90) : row}"',
      );
    }
    // Every settle writer survived the storm intact.
    final glass = rows.join('\n');
    expect(glass, contains('bash task completed in background (0s)'));
    expect(glass, contains('[bash] sh-1-x exited(0)'));
    expect(glass, contains('steering — settle notice delivered'));
    // The plain delta still merged (streaming shape unchanged).
    expect(glass, contains('streamed answer tail mid-word'));
  });
}
