import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
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

List<AssistantMessageEvent> _toolTurn(List<ToolCall> calls) {
  final empty = _assistant();
  final partial = _assistant(content: calls, stopReason: StopReason.toolUse);
  final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
  for (var i = 0; i < calls.length; i++) {
    events
      ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
      ..add(
        ToolCallEndEvent(contentIndex: i, toolCall: calls[i], partial: partial),
      );
  }
  events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
  return events;
}

/// Scripted [StreamFunction] replaying pre-recorded turns.
class _FakeStreamFunction {
  _FakeStreamFunction(this.turns);

  final List<List<AssistantMessageEvent>> turns;

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    final stream = AssistantMessageEventStream();
    for (final event in turns.removeAt(0)) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// In-memory [CliIO]: scripted input lines, captured output, settable
/// interactivity.
class _FakeCliIO implements CliIO {
  final _lines = StreamController<String>();
  final _interrupts = StreamController<void>.broadcast();
  final _keys = StreamController<KeyEvent>.broadcast();
  final out = StringBuffer();

  @override
  bool isInteractive = true;
  @override
  Stream<KeyEvent> get keys => _keys.stream;

  @override
  bool get supportsRawMode => false;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Stream<void> get interrupts => _interrupts.stream;

  @override
  void write(String text) => out.write(text);

  @override
  void writeln(String text) => out.write('$text\n');

  void sendLine(String line) => _lines.add(line);

  Future<void> close() async {
    unawaited(_lines.close());
    await _interrupts.close();
  }
}

/// A [Shell] that succeeds immediately, echoing the command back.
class _FakeShell implements Shell {
  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return Ok(
      ShellExecResult(stdout: 'ran: $command', stderr: '', exitCode: 0),
    );
  }
}

Future<void> _waitFor(bool Function() condition, {String? reason}) async {
  for (var i = 0; i < 400; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: ${reason ?? 'condition'}');
}

void main() {
  late MemoryExecutionEnv env;
  late _FakeCliIO io;

  setUp(() {
    env = MemoryExecutionEnv(cwd: '/work', shell: _FakeShell());
    io = _FakeCliIO();
  });

  tearDown(() => io.close());

  AgentCli cliFor(
    List<List<AssistantMessageEvent>> turns, {
    ApprovalMode approvalMode = ApprovalMode.yolo,
    Set<String> alwaysAllowTools = const {},
    void Function()? onApprovalChanged,
  }) {
    return AgentCli(
      config: AgentCliConfig(
        model: _model,
        apiKey: 'test-key',
        env: env,
        sessionRoot: '/sessions',
        approvalMode: approvalMode,
        alwaysAllowTools: alwaysAllowTools,
        onApprovalChanged: onApprovalChanged,
      ),
      io: io,
      streamFunction: _FakeStreamFunction(turns).call,
    );
  }

  ToolCall bashCall(String command, {String id = 'tc-1'}) {
    return ToolCall(id: id, name: 'bash', arguments: {'command': command});
  }

  group('non-interactive input', () {
    test('prompt-policy calls are denied with a reason', () async {
      io.isInteractive = false;
      final cli = cliFor([
        _toolTurn([bashCall('echo hi')]),
        _textTurn('adapted'),
      ], approvalMode: ApprovalMode.write);
      final run = cli.run();
      io.sendLine('run it');
      await _waitFor(
        () => io.out.toString().contains('adapted'),
        reason: 'model adapts after the denial',
      );
      final out = io.out.toString();
      expect(out, contains('[bash] error:'));
      expect(out, contains('no approval UI'));
      io.sendLine('/exit');
      await run;
    });

    test('critical bash commands are denied even under yolo', () async {
      io.isInteractive = false;
      final cli = cliFor([
        _toolTurn([bashCall('rm -rf /')]),
        _textTurn('refused'),
      ]);
      final run = cli.run();
      io.sendLine('destroy');
      await _waitFor(() => io.out.toString().contains('refused'));
      final out = io.out.toString();
      expect(out, contains('[bash] error:'));
      expect(out, contains('Critical pattern detected'));
      io.sendLine('/exit');
      await run;
    });
  });

  group('interactive prompt', () {
    test('"y" approves once: the command executes', () async {
      final cli = cliFor([
        _toolTurn([bashCall('echo approved')]),
        _textTurn('turn-finished'),
      ], approvalMode: ApprovalMode.write);
      final run = cli.run();
      io.sendLine('echo');
      await _waitFor(
        () => io.out.toString().contains('[approval] allow?'),
        reason: 'approval prompt',
      );
      io.sendLine('y');
      // Wait for the run to fully settle before sending /exit (an early
      // /exit would be steered into the busy agent instead of quitting).
      await _waitFor(() => io.out.toString().contains('turn-finished'));
      expect(io.out.toString(), contains('[bash] done'));
      expect(cli.approval.isAlwaysAllowed('bash'), isFalse);
      io.sendLine('/exit');
      await run;
    });

    test('"n" denies: the model receives an error result', () async {
      final cli = cliFor([
        _toolTurn([bashCall('echo nope')]),
        _textTurn('denied-then'),
      ], approvalMode: ApprovalMode.write);
      final run = cli.run();
      io.sendLine('echo');
      await _waitFor(() => io.out.toString().contains('[approval] allow?'));
      io.sendLine('n');
      await _waitFor(() => io.out.toString().contains('denied-then'));
      expect(io.out.toString(), contains('The user denied'));
      io.sendLine('/exit');
      await run;
    });

    test('"a" approves always: later calls skip the prompt', () async {
      var approvalChanges = 0;
      final cli = cliFor(
        [
          _toolTurn([bashCall('echo one')]),
          _toolTurn([bashCall('echo two', id: 'tc-2')]),
          _textTurn('both-done'),
        ],
        approvalMode: ApprovalMode.write,
        onApprovalChanged: () => approvalChanges++,
      );
      final run = cli.run();
      io.sendLine('echo twice');
      await _waitFor(() => io.out.toString().contains('[approval] allow?'));
      io.sendLine('a');
      // The second bash call must NOT prompt again.
      await _waitFor(() => io.out.toString().contains('both-done'));
      final out = io.out.toString();
      expect('[approval] allow?'.allMatches(out), hasLength(1));
      expect(cli.approval.isAlwaysAllowed('bash'), isTrue);
      expect(approvalChanges, 1);
      io.sendLine('/exit');
      await run;
    });

    test('critical commands still prompt after "approve always"', () async {
      final cli = cliFor([
        _toolTurn([bashCall('echo benign')]),
        _toolTurn([bashCall('rm -rf /', id: 'tc-2')]),
        _textTurn('seq-done'),
      ], approvalMode: ApprovalMode.write);
      final run = cli.run();
      io.sendLine('two commands');
      await _waitFor(() => io.out.toString().contains('[approval] allow?'));
      io.sendLine('a');
      await _waitFor(
        () => io.out.toString().contains('Critical pattern detected'),
        reason: 'critical pattern re-prompts',
      );
      io.sendLine('n');
      await _waitFor(() => io.out.toString().contains('seq-done'));
      expect(io.out.toString(), contains('[bash] error:'));
      io.sendLine('/exit');
      await run;
    });
  });

  group('slash commands', () {
    test('/approval shows and switches the mode', () async {
      final cli = cliFor([], approvalMode: ApprovalMode.write);
      final run = cli.run();
      io.sendLine('/approval');
      await _waitFor(() => io.out.toString().contains('approval mode: write'));
      io.sendLine('/approval yolo');
      await _waitFor(
        () => io.out.toString().contains('approval mode set to yolo'),
      );
      expect(cli.approval.mode, ApprovalMode.yolo);
      io.sendLine('/approval bogus');
      await _waitFor(
        () => io.out.toString().contains('unknown approval mode: bogus'),
      );
      expect(cli.approval.mode, ApprovalMode.yolo);
      io.sendLine('/exit');
      await run;
    });

    test('/approval persists via onApprovalChanged', () async {
      var changes = 0;
      final cli = cliFor([], onApprovalChanged: () => changes++);
      final run = cli.run();
      io.sendLine('/approval always-ask');
      await _waitFor(
        () => io.out.toString().contains('approval mode set to always-ask'),
      );
      expect(cli.approval.mode, ApprovalMode.alwaysAsk);
      expect(changes, 1);
      io.sendLine('/exit');
      await run;
    });

    test('/allow adds a known tool and lists the set', () async {
      var changes = 0;
      final cli = cliFor([], onApprovalChanged: () => changes++);
      final run = cli.run();
      io.sendLine('/allow bash');
      await _waitFor(() => io.out.toString().contains('"bash" always allowed'));
      expect(cli.approval.alwaysAllowedTools, ['bash']);
      expect(changes, 1);
      io.sendLine('/allow nosuchtool');
      await _waitFor(
        () => io.out.toString().contains('unknown tool: nosuchtool'),
      );
      expect(changes, 1);
      io.sendLine('/allow');
      await _waitFor(
        () => io.out.toString().contains('always-allowed tools: bash'),
      );
      io.sendLine('/exit');
      await run;
    });

    test('config alwaysAllowTools seeds the manager', () {
      final cli = cliFor([], alwaysAllowTools: const {'bash', 'write'});
      expect(cli.approval.alwaysAllowedTools, ['bash', 'write']);
    });

    test('/help mentions the approval commands', () async {
      final cli = cliFor([]);
      final run = cli.run();
      io.sendLine('/help');
      await _waitFor(() => io.out.toString().contains('/approval'));
      expect(io.out.toString(), contains('/allow'));
      io.sendLine('/exit');
      await run;
    });
  });
}
