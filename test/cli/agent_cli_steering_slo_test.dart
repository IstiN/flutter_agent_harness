@TestOn('vm')
library;

/// Issue #647 AC1 — the explicit Ctrl+S CLI cases: steering the MAIN agent
/// is consumed ≤2s during each of {streaming, tool phase,
/// waiting-on-children, N=5 active subagents} and is visible in the
/// session (the `steering_consumed` marker). The owner repro: Ctrl+S sat
/// in the queue undelivered while children were active — these pin the
/// delivery inside the SLO on every phase, scripted-timing (no real
/// 120s waits, no network).

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// The text carried by a transcript message.
String _messageText(Object message) {
  final content = switch (message) {
    UserMessage() => message.content,
    AssistantMessage() => message.content,
    ToolResultMessage() => message.content,
    _ => '',
  };
  return content is String
      ? content
      : content is List<ContentBlock>
      ? [
          for (final block in content)
            if (block is TextContent) block.text,
        ].join('\n')
      : '';
}

/// A [StreamFunction] routing every run by its last user text:
/// - a CHILD run (the assignment carries [childMarker]) hangs until its
///   cancel token fires — subagents alive in the background;
/// - parent runs replay the next scripted turn ('noted.' when dry).
/// Every call is recorded with its arrival time — the first context
/// carrying the steered text IS the consumption timestamp.
final class _SloStream {
  _SloStream({
    required List<List<AssistantMessageEvent>> turns,
    this.childMarker = '',
    this.firstCallDelay,
  }) : _turns = List.of(turns);

  final String childMarker;

  /// How long the FIRST provider call stays open before its events land —
  /// the scripted streaming window the steer must be consumed across.
  final Duration? firstCallDelay;

  final List<List<AssistantMessageEvent>> _turns;
  final contexts = <Context>[];
  final arrivals = <DateTime>[];

  String _lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) return _messageText(message);
    }
    return '';
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    arrivals.add(DateTime.now());
    final stream = AssistantMessageEventStream();
    if (childMarker.isNotEmpty &&
        _lastUserText(context).contains(childMarker)) {
      // The child: alive until cancelled, then aborted.
      stream.push(StartEvent(partial: testAssistant()));
      cancelToken?.onCancel.then((_) {
        stream
          ..push(
            ErrorEvent(
              reason: StopReason.aborted,
              error: testAssistant(
                stopReason: StopReason.aborted,
                errorMessage: 'Operation aborted',
              ),
            ),
          )
          ..end();
      });
      return stream;
    }
    final events = _turns.isNotEmpty ? _turns.removeAt(0) : textTurn('noted.');
    final delay = contexts.length == 1 ? firstCallDelay : null;
    void emit() {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (delay == null) {
      emit();
    } else {
      Timer(delay, () {
        if (cancelToken?.isCancelled ?? false) {
          stream.end();
        } else {
          emit();
        }
      });
    }
    return stream;
  }
}

/// A [Shell] + [BackgroundShell] whose detached jobs never settle until
/// stopped — the tool-phase wedge (`flutter test` that never returns).
final class _HangShell implements Shell, BackgroundShell {
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
    return Ok(_HangJob(id: id, command: command, logPath: logPath));
  }
}

final class _HangJob implements ShellJob {
  _HangJob({required this.id, required this.command, required this.logPath});

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;

  var _stopped = false;
  final _settled = Completer<void>();

  @override
  bool get isRunning => !_stopped;
  @override
  int? get exitCode => _stopped ? 9 : null;
  @override
  Future<void> get settled => _settled.future;
  @override
  String? get stopReason => _stopped ? 'cancelled' : null;
  @override
  Stream<String> get output => const Stream.empty();
  @override
  bool writeStdin(String data) => false;

  @override
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _settled.complete();
  }
}

Future<void> _waitForIt(
  bool Function() condition, {
  String? reason,
  int seconds = 20,
}) async {
  for (var i = 0; i < seconds * 200; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

/// The steering-consumed markers across all sessions.
Future<List<CustomRecord>> _consumedMarkers(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  final markers = <CustomRecord>[];
  for (final id in await repo.list(cwd: '/work')) {
    markers.addAll([
      for (final record in await (await repo.open(id)).getEntries())
        if (record is CustomRecord && record.customType == 'steering_consumed')
          record,
    ]);
  }
  return markers;
}

/// Polls until the FIRST consumed marker exists and returns how long the
/// steer took from [steeredAt] — the mid-run SLO measurement.
Future<Duration> _timeToConsumed(
  MemoryExecutionEnv env,
  DateTime steeredAt,
) async {
  final deadline = steeredAt.add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    if ((await _consumedMarkers(env)).isNotEmpty) {
      return DateTime.now().difference(steeredAt);
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: the steering_consumed marker');
}

/// Whether any persisted session carries a message whose text contains
/// [text] — session visibility for a plain (non-steering) turn.
Future<bool> _sessionTextVisible(MemoryExecutionEnv env, String text) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (final id in await repo.list(cwd: '/work')) {
    for (final record in await (await repo.open(id)).getEntries()) {
      if (record is MessageRecord &&
          _messageText(record.message).contains(text)) {
        return true;
      }
    }
  }
  return false;
}

/// Polls until [text] reaches a model context and returns how long it
/// took from [since] — the idle-submit SLO measurement.
Future<Duration> _timeToContextText(
  _SloStream stream,
  String text,
  DateTime since,
) async {
  final deadline = since.add(const Duration(seconds: 20));
  bool seen() => stream.contexts.any(
    (context) =>
        context.messages.any((message) => _messageText(message).contains(text)),
  );
  while (DateTime.now().isBefore(deadline)) {
    if (seen()) return DateTime.now().difference(since);
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: the submitted text in a model context');
}

void main() {
  late FakeCliIO io;
  late MemoryExecutionEnv env;

  setUp(() => io = FakeCliIO());
  tearDown(() => io.close());

  Future<(AgentCli, Future<void>)> bootedCli(
    StreamFunction stream, {
    Shell? shell,
  }) async {
    // The one env the assertions read sessions from.
    env = MemoryExecutionEnv(
      cwd: '/work',
      shell: shell ?? const UnavailableShell(),
    );
    final cli = AgentCli(
      config: AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        approvalMode: ApprovalMode.yolo,
      ),
      io: io,
      streamFunction: stream,
    );
    final run = cli.run();
    io.sendLine('/help');
    await _waitForIt(
      () => io.out.toString().contains('/tasks'),
      reason: 'REPL is up',
    );
    return (cli, run);
  }

  test(
    'AC1 streaming: Ctrl+S while the provider call is in flight is '
    'consumed ≤2s at the stream-end boundary',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _SloStream(
        firstCallDelay: const Duration(milliseconds: 300),
        turns: [
          textTurn('first answer'),
          textTurn('steered ack'),
          textTurn('settled'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call);

      io.sendLine('start');
      await _waitForIt(() => stream.contexts.length == 1 && cli.isBusy);
      // Mid-stream keystroke: the provider call is still open.
      final steeredAt = DateTime.now();
      io.sendLine('hold on, check the logs first');
      final consumed = await _timeToConsumed(env, steeredAt);
      expect(
        consumed,
        lessThan(const Duration(seconds: 2)),
        reason:
            'the steer is consumed ≤2s after the keystroke — today it '
            'can sit queued past the whole turn',
      );
      await _waitForIt(
        () => stream.contexts.length >= 2,
        reason: 'the boundary turn started',
      );
      await _waitForIt(
        () => stream.contexts[1].messages.any(
          (message) =>
              _messageText(message).contains('hold on, check the logs'),
        ),
        reason: 'the steered text reached the model at the boundary',
      );
      await _waitForIt(() => !cli.isBusy, reason: 'the run settles');
      expect(
        await _consumedMarkers(env),
        hasLength(1),
        reason: 'the delivery is visible in the session',
      );
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC1 tool phase: Ctrl+S mid never-returning bash soft-yields it to '
    'background and is consumed ≤2s at the boundary',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _SloStream(
        turns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'bash',
              arguments: const {'command': 'flutter test --tag never-returns'},
            ),
          ]),
          textTurn('moved it to background; I will report'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call, shell: _HangShell());

      io.sendLine('run the wedged test suite');
      await _waitForIt(() => stream.contexts.length == 1 && cli.isBusy);
      // The tool is executing (the hang job is up) — steer mid-tool.
      final steeredAt = DateTime.now();
      io.sendLine('how is it going?');
      final consumed = await _timeToConsumed(env, steeredAt);
      expect(
        consumed,
        lessThan(const Duration(seconds: 2)),
        reason:
            'the steer is consumed ≤2s after the keystroke, not after '
            'the tool settles (it never does)',
      );
      await _waitForIt(
        () =>
            stream.contexts.length >= 2 &&
            stream.contexts[1].messages.any(
              (message) => _messageText(message).contains('how is it going?'),
            ),
        reason: 'the steered text reached the model at the boundary',
      );
      await _waitForIt(() => !cli.isBusy, reason: 'the turn continued');
      // The yield, not a kill: the wedged command still runs as a job.
      final snap = await cli.waitersSnapshotForTest();
      expect(
        snap.jobs.where((j) => j.contains('flutter test')),
        isNotEmpty,
        reason: 'the yielded command keeps running in the background',
      );
      expect(
        await _consumedMarkers(env),
        hasLength(1),
        reason: 'the delivery is visible in the session',
      );
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC1 waiting-on-children: Ctrl+S while a background child runs is '
    'consumed ≤2s (the steer starts the wake turn itself)',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const childTask = 'child-task: nightly report';
      final stream = _SloStream(
        childMarker: childTask,
        turns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'task',
              arguments: const {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {'name': 'c1', 'agent': 'task', 'task': childTask},
                ],
              },
            ),
          ]),
          textTurn('spawned the nightly report in the background'),
          textTurn('the child is still working on it'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call);

      io.sendLine('spawn the nightly report');
      await _waitForIt(
        () => cli.taskConfig.jobManager.job('c1') != null,
        reason: 'the background child registers',
      );
      await _waitForIt(
        () => !cli.isBusy,
        reason:
            'the parent turn ends — waiting on children is an idle, '
            'inbox-open state',
      );
      // Ctrl+S over the idle, inbox-open wait submits the line — the
      // wake turn starts at once, never queued behind the child.
      final steeredAt = DateTime.now();
      io.sendLine('ping the child for status');
      final consumed = await _timeToContextText(
        stream,
        'ping the child for status',
        steeredAt,
      );
      expect(
        consumed,
        lessThan(const Duration(seconds: 2)),
        reason: 'the wake turn starts ≤2s after the keystroke',
      );
      expect(
        cli.taskConfig.jobManager.job('c1')!.status,
        TaskJobStatus.running,
        reason: 'the child is untouched by the steer',
      );
      expect(
        await _sessionTextVisible(env, 'ping the child for status'),
        isTrue,
        reason: 'the turn is visible in the session',
      );
      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC1 N=5: Ctrl+S with five active subagents is consumed ≤2s and '
    'leaves all five running',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      const childTask = 'child-task: fan-out probe';
      final stream = _SloStream(
        childMarker: childTask,
        turns: [
          toolTurn([
            ToolCall(
              id: 't1',
              name: 'task',
              arguments: const {
                'context': 'ctx',
                'background': true,
                'tasks': [
                  {'name': 'c1', 'agent': 'task', 'task': childTask},
                  {'name': 'c2', 'agent': 'task', 'task': childTask},
                  {'name': 'c3', 'agent': 'task', 'task': childTask},
                  {'name': 'c4', 'agent': 'task', 'task': childTask},
                  {'name': 'c5', 'agent': 'task', 'task': childTask},
                ],
              },
            ),
          ]),
          textTurn('five probes running in the background'),
          textTurn('all five still going'),
        ],
      );
      final (cli, run) = await bootedCli(stream.call);

      io.sendLine('fan out five probes');
      await _waitForIt(
        () => [
          for (var i = 1; i <= 5; i++) cli.taskConfig.jobManager.job('c$i'),
        ].every((job) => job != null),
        reason: 'all five children register',
      );
      await _waitForIt(() => !cli.isBusy, reason: 'the parent turn ends');
      final steeredAt = DateTime.now();
      io.sendLine('collect interim results now');
      final consumed = await _timeToContextText(
        stream,
        'collect interim results now',
        steeredAt,
      );
      expect(
        consumed,
        lessThan(const Duration(seconds: 2)),
        reason:
            'the owner repro: the prompt must never sit queued while '
            'subagents are in flight',
      );
      expect(
        await _sessionTextVisible(env, 'collect interim results now'),
        isTrue,
        reason: 'the turn is visible in the session',
      );
      expect(
        [
          for (var i = 1; i <= 5; i++)
            cli.taskConfig.jobManager.job('c$i')!.status,
        ],
        everyElement(TaskJobStatus.running),
        reason: 'all five children are untouched by the steer',
      );
      io.sendLine('/exit');
      await run;
    },
  );
}
