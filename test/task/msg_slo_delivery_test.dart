@TestOn('vm')
library;

/// Issue #647 — the ≤2s messaging delivery SLO (TDD, fake clock harness, no
/// real network):
///
/// - AC2: `task_send` → completed child: the resumed run CONSUMES the message
///   as its first action (warm wake, never gated on session boot) and the
///   send unblocks ≤2s with stage timestamps in the log; a stage past the
///   SLO emits a breach diagnostic naming the stalled stage (AC6 core side).
/// - AC3: `task_send` → running child mid foreground wait: the wait yields
///   to background (the job is NOT killed), the message is consumed at the
///   boundary ≤2s, the wait's work continues detached (exit captured).
/// - AC4: the owner experiment stretched: `sleep 120` backgrounded by the
///   yield; `task_send` "stop the job, echo hello" stops the job mid-flight
///   via bash_job stop and the round trip lands ≤30s.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:flutter_agent_harness/src/task/delivery_slo.dart';
import 'package:test/test.dart';


const _model = Model(
  id: 'parent-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

AssistantMessage _assistant({
  List<ContentBlock> content = const [],
  StopReason stopReason = StopReason.stop,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    timestamp: DateTime.utc(2026),
  );
}

List<AssistantMessageEvent> _textTurn(String text) {
  final empty = _assistant();
  final partial = _assistant(content: [TextContent(text: text)]);
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A scripted turn ending in tool calls: the calls ride the partial's
/// content (the loop finalizes tool calls from the done message).
List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(
    content: List<ContentBlock>.of(calls),
    stopReason: StopReason.toolUse,
  );
  return [
    StartEvent(partial: empty),
    for (final (i, call) in calls.indexed) ...[
      ToolCallStartEvent(contentIndex: i, partial: empty),
      ToolCallEndEvent(contentIndex: i, toolCall: call, partial: partial),
    ],
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

/// A controllable fake shell job: never settles on its own; tests complete
/// or stop it by hand (the sleep that never ends).
final class _FakeShellJob implements ShellJob {
  _FakeShellJob(this.id, this.command, this.logPath);

  final _output = StreamController<String>.broadcast();
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;

  @override
  final String id;
  @override
  final String command;
  @override
  final String logPath;
  @override
  int? get pid => null;
  @override
  bool get isRunning => _exitCode == null;
  @override
  int? get exitCode => _exitCode;
  @override
  String? get stopReason => _stopReason;
  @override
  Future<void> get settled => _settled.future;

  @override
  Stream<String> get output => _output.stream;
  @override
  bool writeStdin(String data) => true;

  void complete(int code, {String? reason}) {
    if (_exitCode != null) return;
    _stopReason = reason;
    _exitCode = code;
    _settled.complete();
  }

  @override
  Future<void> stop() async {
    _stopReason = 'stopped';
    complete(143);
  }
}

/// MemoryExecutionEnv wrapper with the [BackgroundShell] capability: the
/// child's `bash` can yield into registry jobs, and `echo hello` answers
/// inline so the AC4 round trip is fully observable without a real process.
final class _SleepShellEnv implements ExecutionEnv, BackgroundShell {
  _SleepShellEnv(this._delegate);

  final MemoryExecutionEnv _delegate;
  final jobs = <_FakeShellJob>[];

  _FakeShellJob? get singleJob => jobs.isEmpty ? null : jobs.last;

  @override
  bool get backgroundJobsSupported => true;
  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    final job = _FakeShellJob(id, command, logPath);
    jobs.add(job);
    return Ok(job);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    if (command.trim().startsWith('echo ')) {
      return Ok(
        ShellExecResult(
          stdout: '${command.trim().substring(5)}\n',
          stderr: '',
          exitCode: 0,
        ),
      );
    }
    return _delegate.exec(command, options: options);
  }

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  Future<Result<void, FileError>> createDir(String path, {bool recursive = true}) =>
      _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The marker every wake script routes on (rides the steered message text).
const wakeMarker = '@@wake@@';

/// Scripted child provider keyed by the last user text, with a hook that
/// stamps the wall clock whenever a request context first carries
/// [wakeMarker] — the consumption timestamp of the steered message.
/// Wake-handling state of a scripted child: the stop+echo tools fire once,
/// then the run settles with a final text.
enum _HandledWake { no, stopping }

final class _ChildStream {
  _ChildStream({required this.taskMarker, this.spawnSleepTool = true, this.resumeDelay = Duration.zero});

  final String taskMarker;

  /// Whether the task turn issues the foreground `sleep 120` bash call
  /// (AC3/AC4). AC2's child just answers and completes.
  final bool spawnSleepTool;

  final contexts = <Context>[];
  DateTime? wakeSeenAt;
  var _handledWake = _HandledWake.no;
  final _seen = <String>{};

  /// Wall-clock stall injected into the resumed run's first model call —
  /// a stalled stage on the wake path (the provider hangs) so the breach
  /// diagnostic has a real trigger.
  final Duration resumeDelay;

  static String lastUserText(Context context) {
    for (final message in context.messages.reversed) {
      if (message is UserMessage) {
        final content = message.content;
        if (content is String) return content;
        if (content is List<ContentBlock>) {
          return content.whereType<TextContent>().map((b) => b.text).join('\n');
        }
      }
    }
    return '';
  }

  /// Every tool-result text currently in the context (the yielded bash
  /// result names the background job id).
  Iterable<String> _toolResults(Context context) sync* {
    for (final result in context.messages.whereType<ToolResultMessage>()) {
      for (final block in result.content.whereType<TextContent>()) {
        yield block.text;
      }
    }
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final text = lastUserText(context);
    if (text.contains(wakeMarker) && _seen.add(wakeMarker)) {
      wakeSeenAt = DateTime.now();
    }
    List<AssistantMessageEvent> events;
    if (text.contains(taskMarker)) {
      events = spawnSleepTool
          ? _toolTurn([
              const ToolCall(
                id: 'c1',
                name: 'bash',
                arguments: {'command': 'sleep 120'},
              ),
            ])
          : _textTurn('done');
    } else if (text.contains(wakeMarker)) {
      if (_handledWake != _HandledWake.no) {
        events = _textTurn('job stopped, hello echoed');
      } else {
        _handledWake = _HandledWake.stopping;
        final jobId = _toolResults(context)
            .map((t) => RegExp(r'background job (sh-\S+)').firstMatch(t))
            .whereType<RegExpMatch>()
            .map((m) => m.group(1)!)
            .firstOrNull;
        events = _toolTurn([
          ToolCall(
            id: 'c2',
            name: 'bash_job',
            arguments: {'action': 'stop', 'id': ?jobId},
          ),
          const ToolCall(
            id: 'c3',
            name: 'bash',
            arguments: {'command': 'echo hello'},
          ),
        ]);
      }
    } else {
      events = _textTurn('done');
    }
    final stream = AssistantMessageEventStream();
    void flush() {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }

    if (resumeDelay > Duration.zero && text.contains(wakeMarker)) {
      // The wake turn's model call stalls (a stalled provider stage); the
      // events land only after the delay.
      unawaited(
        Future<void>.delayed(resumeDelay).then((_) => flush()),
      );
    } else {
      flush();
    }
    return stream;
  }
}

/// The executor + manager + real JSONL child sessions, mirroring the CLI
final class _Wiring {
  _Wiring(this.child, {StreamFunction? streamFn}) {
    _streamFn = streamFn ?? child.call;
    manager = SubagentManager(parentSessionId: 'parent-session')
      ..mailboxPrefix = 'parent-session';
    executor = TaskExecutor(
      childTools: builtinTools(env, shellJobs: ShellJobRegistry(env: env)),
      streamFunction: () => _streamFn,
      model: () => _model,
      registry: TaskAgentRegistry(const []),
      semaphore: Semaphore(4),
      store: AgentOutputStore(),
      subagentManager: manager,
      childSessionFactory: (parentId, childId) => repo.create(
        JsonlSessionCreateOptions(
          cwd: '/work',
          metadata: {
            'agent': 'subagent',
            'id': childId,
            'parent': parentId,
            'model': _model.id,
          },
        ),
      ),
      childSessionOpener: _slowOpener,
    );
  }

  final _SleepShellEnv env = _SleepShellEnv(MemoryExecutionEnv(cwd: '/work'));
  late final repo = JsonlSessionRepo(fs: env._delegate, sessionsRoot: '/sessions');
  final _ChildStream child;
  late final StreamFunction _streamFn;
  late final SubagentManager manager;
  late final TaskExecutor executor;

  Future<Session> _slowOpener(String path) =>
      jsonlChildSessionOpener(env)(path);

  Future<TaskSingleResult> spawn(String name, String task) {
    return executor.runSpawn(
      item: TaskItem(name: name, task: task),
      index: 0,
      context: '',
    );
  }

  List<AgentTool> monitoringTools() => subagentMonitoringTools(
    manager: manager,
    resumeChild: executor.resumeChild,
  );

  Future<String> send(String toolName, Map<String, dynamic> args) async {
    final tool = monitoringTools().firstWhere((t) => t.name == toolName);
    final result = await tool.execute(args, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }

  /// Waits until [condition] holds or [timeout] elapses; used so a RED run
  /// fails fast instead of hanging on the full sleep.
  Future<bool> waitFor(bool Function() condition, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (condition()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return condition();
  }
}

void main() {
  final sloLines = <String>[];
  setUp(() => sloLines.clear());
  tearDown(() => deliverySloSink = null);

  test(
    'AC2: task_send to a completed child unblocks ≤2s with the message '
    'consumed FIRST and a stalled wake stage named by the breach diagnostic',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      deliverySloSink = sloLines.add;
      final child = _ChildStream(
        taskMarker: 'batch-work',
        spawnSleepTool: false,
        // The wake turn's model call stalls 2.5s > the SLO: the send must
        // not wait it (consumption stays instant) and the breach must name
        // the stage.
        resumeDelay: const Duration(milliseconds: 2500),
      );
      final wiring = _Wiring(child);
      await wiring.spawn('c1', 'batch-work');
      await wiring.waitFor(
        () => wiring.manager['c1']?.status == SubagentStatus.completed,
        const Duration(seconds: 15),
      );
      // The child completed; its transcript is on disk.

      final sendAt = DateTime.now();
      final receipt = await wiring.send('task_send', {
        'id': 'c1',
        'message': 'status? also wakeRule @@wake@@',
      });
      final receiptAt = DateTime.now();
      final receiptLag = receiptAt.difference(sendAt);

      expect(
        receiptLag,
        lessThan(const Duration(seconds: 2)),
        reason: 'the send unblocks inside the SLO even with a slow boot '
            '(today it waits out the whole resumed run)',
      );
      expect(receipt, contains('consumed'));
      // Consumption (the inbox drain that seeds the resumed run's first
      // prompt) is stamped ≤2s after the send — decoupled from the 2.5s
      // session boot that follows. The child's model sees the message as
      // the resumed run's first action, right after the boot.
      expect(
        sloLines.join('\n'),
        contains('stage=consumed'),
        reason: 'delivery stage lines land in the host sink',
      );
      final consumedLine = sloLines
        .firstWhere((l) => l.contains('stage=consumed'));
      final consumedMs = RegExp(r'elapsed=(\d+)ms')
        .firstMatch(consumedLine)
        ?.group(1);
      expect(consumedMs, isNotNull, reason: 'the consumed stamp carries '
          'its elapsed time');
      expect(
        int.parse(consumedMs!),
        lessThan(2000),
        reason: 'the message is consumed ≤2s after send, not after the '
            '2.5s session boot',
      );
      // AC6 (core side): the boot past the SLO names its stage.
      final drained = await wiring.waitFor(
        () => sloLines.any((l) => l.contains('BREACH') && l.contains('stage=')),
        const Duration(seconds: 10),
      );
      expect(drained, isTrue, reason: 'a stage past the SLO emits a breach '
          'diagnostic naming the stalled stage; got:\n${sloLines.join('\n')}');
      // The resumed run processes the message as its first action: the
      // scripted wake turn's echo lands in the child's context. The run
      // may linger open afterwards (steering-extension semantics), so
      // run termination is not the contract; the row and transcript tell
      // the truth.
      final echoVisible = await wiring.waitFor(
        () => child.contexts.any(
          (context) => context.messages.whereType<ToolResultMessage>().any(
            (result) => result.content
                .whereType<TextContent>()
                .any((b) => b.text.contains('hello')),
          ),
        ),
        const Duration(seconds: 15),
      );
      expect(echoVisible, isTrue, reason: 'the resumed run processed the '
          'message as its first action');
    },
  );

  test(
    'AC3: task_send to a running child mid foreground sleep yields the wait '
    'to background, consumes ≤2s at the boundary, job keeps running',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      deliverySloSink = sloLines.add;
      final child = _ChildStream(taskMarker: 'sleeper-work');
      final wiring = _Wiring(child);
      final spawnDone = wiring.spawn('s1', 'sleeper-work');
      // The child entered its foreground bash (a never-settling job).
      final jobUp = await wiring.waitFor(
        () => wiring.env.jobs.isNotEmpty,
        const Duration(seconds: 15),
      );
      expect(jobUp, isTrue, reason: 'the child runs its sleep in a job-backed '
          'foreground bash');

      final sendAt = DateTime.now();
      await wiring.send('task_send', {
        'id': 's1',
        'message': 'how goes? @@wake@@',
      });
      // The yield: the sleep moved to a background job, NOT killed.
      final consumedFast = await wiring.waitFor(
        () => child.wakeSeenAt != null &&
            child.wakeSeenAt!.difference(sendAt) < const Duration(seconds: 2),
        const Duration(seconds: 10),
      );
      expect(consumedFast, isTrue, reason: 'the message is consumed ≤2s after '
          'send — today the child sleeps the full 120s ignoring the inbox');
      expect(wiring.env.singleJob, isNotNull);
      expect(
        wiring.env.singleJob!.isRunning,
        isTrue,
        reason: 'the yielded wait keeps running detached',
      );
      expect(
        sloLines.join('\n'),
        contains('stage=consumed'),
      );
      // Post-fix the resumed run continues detached (steering-extension
      // semantics keep it open for late followers) — the SLO contract is
      // consumption + detached work, not run termination. Give it a fair
      // window; its row and transcript tell the truth afterwards.
      await wiring.waitFor(
        () => child.contexts.length >= 3,
        const Duration(seconds: 10),
      );
      expect(
        wiring.manager['s1']?.status == SubagentStatus.completed ||
            wiring.manager['s1']?.status == SubagentStatus.running,
        isTrue,
        reason: 'the child is alive and processing after the yield',
      );
      unawaited(spawnDone.catchError((Object _) => throw StateError('gone')));
      await wiring.env.singleJob!.stop();
    },
  );

  test(
    'AC4: sleep 120 backgrounded by the yield; task_send "stop the job, '
    'echo hello" stops it mid-flight; round trip ≤30s',
    timeout: const Timeout(Duration(seconds: 90)),
    () async {
      deliverySloSink = sloLines.add;
      final child = _ChildStream(taskMarker: 'sleeper-work');
      final wiring = _Wiring(child);
      final spawnDone = wiring.spawn('s2', 'sleeper-work');
      await wiring.waitFor(
        () => wiring.env.jobs.isNotEmpty,
        const Duration(seconds: 15),
      );

      final sendAt = DateTime.now();
      await wiring.send('task_send', {
        'id': 's2',
        'message': 'stop the job, echo hello @@wake@@',
      });
      // The wake turn stops the job and echoes; assert the observable
      // round trip: the job dies mid-flight and the hello lands in the
      // child's context — all ≤30s. The run itself lingers open for late
      // followers (steering-extension semantics), so run termination is
      // not the contract; the stop exit and the echo result are.
      final helloVisible = await wiring.waitFor(
        () => child.contexts.any(
          (context) => context.messages.whereType<ToolResultMessage>().any(
            (result) => result.content
                .whereType<TextContent>()
                .any((b) => b.text.contains('hello')),
          ),
        ),
        const Duration(seconds: 30),
      );
      final roundTrip = DateTime.now().difference(sendAt);
      expect(helloVisible, isTrue, reason: 'echo hello executed after the '
          'stop; slo=${sloLines.join(' | ')} ctx=${child.contexts.length} '
          'wake=${child.wakeSeenAt} st=${wiring.manager['s2']?.status} '
          'err=${wiring.manager['s2']?.error}');
      expect(
        roundTrip,
        lessThan(const Duration(seconds: 30)),
        reason: 'the owner round trip: jobs die mid-flight, hello echoed, '
            'all ≤30s (today the child never wakes until the sleep ends)',
      );
      final job = wiring.env.singleJob!;
      expect(job.isRunning, isFalse, reason: 'bash_job stop killed the sleep '
          'mid-flight');
      expect(job.exitCode, 143, reason: 'the stop exit is captured');
      expect(
        sloLines.join('\n'),
        contains('stage=consumed'),
      );
      unawaited(spawnDone.catchError((Object _) => throw StateError('gone')));
    },
  );
}
