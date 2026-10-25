/// gh-1835: auto-backgrounding of long foreground bash calls.
///
/// At the liveness threshold (`waiting.autoBackgroundSeconds`, default 60s,
/// 0 = kill switch) a still-running foreground bash call is CONVERTED —
/// never restarted — to a background shell job: the same process keeps
/// running, the pending tool call resolves exactly once with the
/// backgrounded result (job id, elapsed, log path, inline guidance), and
/// the model decides what happens next (wait for the settle, poll
/// `bash_job output`, or stop the job and retry differently).
///
/// The conversion notice rides the TOOL RESULT only (AC2): no separate
/// steering record, no extra model turn. The settle notification stays
/// armed for converted jobs, so the later completion still wakes the model
/// through the existing settle → reaction mechanism.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/waiting_heartbeat.dart';
import 'package:test/test.dart';

const _model = Model(
  id: 'test-model',
  api: 'test-api',
  provider: 'test-provider',
  baseUrl: 'https://example.test',
  contextWindow: 100000,
  maxTokens: 4096,
);

/// A controllable fake background job over the in-memory fs (the
/// shell_jobs_test pattern): tests write log lines and settle/stop it by
/// hand.
final class _FakeShellJob implements ShellJob {
  _FakeShellJob(this.id, this.command, this.logPath, this._env, {this.options});

  final MemoryExecutionEnv _env;
  final _output = StreamController<String>.broadcast();
  final _settled = Completer<void>();
  int? _exitCode;
  String? _stopReason;

  /// The exec options the job was started with (the timeout-carry check).
  final ShellExecOptions? options;

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

  Future<void> writeLog(String text) {
    _output.add(text);
    return _env.appendFile(logPath, text);
  }

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
    complete(143, reason: 'stopped');
  }
}

/// MemoryExecutionEnv wrapper with the [BackgroundShell] capability.
final class _FakeBackgroundEnv implements ExecutionEnv, BackgroundShell {
  _FakeBackgroundEnv(this._delegate, {Shell? execShell})
    : _execShell = execShell ?? const UnavailableShell();

  final MemoryExecutionEnv _delegate;

  /// The shell the CLASSIC foreground exec path resolves through — an
  /// Ok('exec-ran') answer by default, so a test can tell the classic path
  /// (this text, no registry job) from the job path (a registry job).
  final Shell _execShell;
  final jobs = <_FakeShellJob>[];

  /// The options of the most recent `startShellJob` call.
  ShellExecOptions? lastJobOptions;

  @override
  Future<Result<List<FileInfo>, FileError>> listDir(String path) =>
      _delegate.listDir(path);

  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellJob, ExecutionError>> startShellJob(
    String command, {
    required String id,
    required String logPath,
    ShellExecOptions? options,
  }) async {
    lastJobOptions = options;
    final job = _FakeShellJob(
      id,
      command,
      logPath,
      _delegate,
      options: options,
    );
    jobs.add(job);
    return Ok(job);
  }

  @override
  String get cwd => _delegate.cwd;

  @override
  Future<Result<void, FileError>> createDir(
    String path, {
    bool recursive = true,
  }) => _delegate.createDir(path, recursive: recursive);

  @override
  Future<Result<String, FileError>> readTextFile(String path) =>
      _delegate.readTextFile(path);

  @override
  Future<Result<void, FileError>> appendFile(String path, String content) =>
      _delegate.appendFile(path, content);

  @override
  Future<Result<bool, FileError>> exists(String path) => _delegate.exists(path);

  @override
  Future<Result<void, FileError>> remove(
    String path, {
    bool recursive = false,
    bool force = false,
  }) => _delegate.remove(path, recursive: recursive, force: force);

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) => _execShell.exec(command, options: options);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// An exec shell that answers every command with a fixed success.
final class _EchoShell implements Shell {
  const _EchoShell();

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    return const Ok(
      ShellExecResult(stdout: 'exec-ran', stderr: '', exitCode: 0),
    );
  }
}

Future<_FakeShellJob> _waitForJob(_FakeBackgroundEnv env) async {
  for (var i = 0; i < 200 && env.jobs.isEmpty; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  return env.jobs.single;
}

Future<void> _pumpSettles() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

const _conversionThreshold = Duration(milliseconds: 80);

void main() {
  group('autoBackgroundHandbackText', () {
    test('carries job id, elapsed, log path and both guidance branches', () {
      final text = autoBackgroundHandbackText(
        jobId: 'sh-9-abc',
        logPath: '/work/.fah/bash_jobs/sh-9-abc.log',
        elapsed: const Duration(seconds: 60),
      );
      // Anchored on the hand-back sentence the loop recognizes — the stuck
      // supervisor and the budget ladder must classify this as a real
      // background conversion.
      expect(text, startsWith(stuckBackgroundHandbackSentence));
      expect(text, contains('sh-9-abc'));
      expect(text, contains('60s'));
      expect(text, contains('/work/.fah/bash_jobs/sh-9-abc.log'));
      // Conversion, never restart.
      expect(text, contains('NOT restarted'));
      // Branch 1: unexpected duration → stop + retry differently.
      expect(text, contains('bash_job'));
      expect(text, contains('action: stop'));
      expect(text, contains('retry with a different approach'));
      // Branch 2: expected duration → continue + settle wake / poll.
      expect(text, contains('you will be notified'));
      expect(text, contains('action: output'));
    });

    test('names the carried timeout only when the call had one', () {
      final withCap = autoBackgroundHandbackText(
        jobId: 'sh-1-a',
        logPath: '/l.log',
        elapsed: const Duration(seconds: 60),
        carriedTimeout: const Duration(seconds: 120),
      );
      expect(withCap, contains('120s timeout'));
      final withoutCap = autoBackgroundHandbackText(
        jobId: 'sh-1-a',
        logPath: '/l.log',
        elapsed: const Duration(seconds: 60),
      );
      expect(withoutCap, isNot(contains('Timeout cap:')));
    });
  });

  group('bash auto-background (gh-1835)', () {
    late _FakeBackgroundEnv env;
    late List<String> settleNotifications;
    late ShellJobRegistry registry;
    late AgentTool tool;

    setUp(() {
      env = _FakeBackgroundEnv(
        MemoryExecutionEnv(cwd: '/work'),
        execShell: const _EchoShell(),
      );
      settleNotifications = [];
      registry = ShellJobRegistry(
        env: env,
        onSettled: (job) => settleNotifications.add(job.id),
      );
      tool = shellTool(
        env,
        jobs: registry,
        autoBackgroundAfter: _conversionThreshold,
      );
    });

    test('AC1: at the threshold the call resolves with the backgrounded '
        'result and the same job keeps running', () async {
      final resultFuture = tool.execute({'command': 'make'}, null, null);
      final job = await _waitForJob(env);
      final result = await resultFuture;
      final text = _text(result);

      // Exactly-once resolution carrying the backgrounded facts.
      expect(text, contains('moved to background job ${job.id}'));
      expect(text, contains('Log: ${job.logPath}'));
      expect(text, contains('action: stop'));
      // Conversion, never restart: the SAME job instance keeps running.
      expect(env.jobs, hasLength(1));
      expect(job.isRunning, isTrue);

      // AC2/AC4: the settle notification stays armed — the model is woken
      // when the job finishes (and the headless drain waits for it).
      expect(registry.jobs.single.notifyOnSettle, isTrue);
      job.complete(0);
      await _pumpSettles();
      expect(settleNotifications, [job.id]);
    });

    test('AC4: a command that settles before the threshold is unchanged '
        '(inline result, settle notice suppressed)', () async {
      final resultFuture = tool.execute({'command': 'make'}, null, null);
      final job = await _waitForJob(env);
      await job.writeLog('built\n');
      job.complete(0);
      final result = await resultFuture;
      expect(_text(result), 'built');
      await _pumpSettles();
      expect(settleNotifications, [job.id]);
      expect(registry.jobs.single.notifyOnSettle, isFalse);
    });

    test(
      'AC4: threshold 0 is the kill switch — the classic path runs',
      () async {
        final killSwitch = shellTool(
          env,
          jobs: registry,
          autoBackgroundAfter: Duration.zero,
        );
        final result = await killSwitch.execute(
          {'command': 'make'},
          null,
          null,
        );
        expect(_text(result), 'exec-ran');
        expect(env.jobs, isEmpty);
      },
    );

    test('AC4: an explicit timeout at or below the threshold keeps the '
        'classic foreground path (no job)', () async {
      final result = await tool.execute(
        {'command': 'make', 'timeout': 0.05},
        null,
        null,
      );
      // The classic path resolves through env.exec (_EchoShell answers
      // 'exec-ran'); no job was registered, so no conversion can happen.
      expect(_text(result), 'exec-ran');
      expect(env.jobs, isEmpty);
    });

    test('AC1: an explicit timeout above the threshold carries over as the '
        'job cap and is named in the result', () async {
      final resultFuture = tool.execute(
        {'command': 'make', 'timeout': 2},
        null,
        null,
      );
      final job = await _waitForJob(env);
      final text = _text(await resultFuture);
      expect(text, contains('moved to background job ${job.id}'));
      expect(text, contains('2s timeout'));
      // The cap really rides the job's exec options.
      expect(job.options?.timeout, const Duration(seconds: 2));
      env.jobs.single.complete(0);
    });

    test('AC4: a steering yield before the threshold still produces the '
        'steering hand-back, not the conversion', () async {
      final yieldSource = CancelTokenSource();
      final resultFuture = runZoned(
        () => tool.execute({'command': 'make'}, null, null),
        zoneValues: {yieldTokenZoneKey: yieldSource.token},
      );
      final job = await _waitForJob(env);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      yieldSource.cancel();
      final text = _text(await resultFuture);
      expect(text, contains('a steering message arrived'));
      expect(text, isNot(contains('NOT restarted')));
      expect(job.isRunning, isTrue);
      env.jobs.single.complete(0);
    });

    test('AC4: without the BackgroundShell capability the legacy foreground '
        'behavior is kept', () async {
      final plainEnv = MemoryExecutionEnv(cwd: '/work');
      final plainRegistry = ShellJobRegistry(env: plainEnv);
      final plainTool = shellTool(
        plainEnv,
        jobs: plainRegistry,
        autoBackgroundAfter: _conversionThreshold,
      );
      // UnavailableShell: the classic path surfaces the shell error.
      await expectLater(
        plainTool.execute({'command': 'make'}, null, null),
        throwsA(isA<StateError>()),
      );
      expect(plainRegistry.jobs, isEmpty);
    });

    test('the command-rewrite notice rides the conversion result', () async {
      final rewriteTool = shellTool(
        env,
        jobs: registry,
        autoBackgroundAfter: _conversionThreshold,
        redactionConfig: const RedactionConfig(),
      );
      final resultFuture = rewriteTool.execute(
        {'command': 'export GH_TOKEN=ghp_${'A' * 36}'},
        null,
        null,
      );
      final job = await _waitForJob(env);
      final text = _text(await resultFuture);
      // The rewrite notice leads, the conversion facts follow.
      expect(text, startsWith('[bash interceptor rewrote 1 secret-shaped'));
      expect(text, contains('moved to background job ${job.id}'));
      env.jobs.single.complete(0);
    });

    test('the command-rewrite notice rides the background: true start '
        'result', () async {
      final rewriteTool = shellTool(
        env,
        jobs: registry,
        redactionConfig: const RedactionConfig(),
      );
      final text = _text(
        await rewriteTool.execute(
          {'command': 'export GH_TOKEN=ghp_${'A' * 36}', 'background': true},
          null,
          null,
        ),
      );
      // The rewrite notice leads, the job facts follow — issue #1408 AC3
      // through the background fast path (the CRAP-ratchet decomposition
      // moved this branch into _startBackgroundBash; the notice contract
      // is unchanged).
      expect(text, startsWith('[bash interceptor rewrote 1 secret-shaped'));
      expect(text, contains('Started background job'));
      expect(env.jobs.single.command, contains('[REDACTED:GitHub Token]'));
      env.jobs.single.complete(0);
    });
  });

  group('bash tool description (gh-1835 review)', () {
    late _FakeBackgroundEnv env;
    late ShellJobRegistry registry;

    setUp(() {
      env = _FakeBackgroundEnv(
        MemoryExecutionEnv(cwd: '/work'),
        execShell: const _EchoShell(),
      );
      registry = ShellJobRegistry(env: env);
    });

    test('teaches the conversion only when armed', () {
      final armed = shellTool(
        env,
        jobs: registry,
        autoBackgroundAfter: _conversionThreshold,
      );
      // The gh-1835 conversion sentence's unique phrase ("also moved …
      // automatically") — the plain "moved to a background job" also
      // appears in the pre-existing soft-yield sentence, which stays
      // regardless of the threshold.
      expect(
        armed.description,
        contains('moved to a background job automatically'),
      );
      final killed = shellTool(
        env,
        jobs: registry,
        autoBackgroundAfter: Duration.zero,
      );
      // The kill switch must not teach the model the conversion it will
      // never get.
      expect(
        killed.description,
        isNot(contains('moved to a background job automatically')),
      );
    });

    test('a converted carried timeout is NOT auto-retried', () {
      final armed = shellTool(
        env,
        jobs: registry,
        autoBackgroundAfter: _conversionThreshold,
      );
      // The conversion sentence states the cap's no-retry contract: once
      // converted, the carried timeout is enforced by the job itself and
      // the harness retry loop is gone — the model must retry itself when
      // the completion notice reports a timeout.
      expect(armed.description, contains('NOT auto-retried'));
      expect(
        armed.description,
        contains('completion notice reports a timeout'),
      );
      // The classic-path retry promise stays (the foreground path still
      // retries); the conversion sentence scopes its exception.
      expect(armed.description, contains('retried automatically'));
    });
  });

  group('bash auto-background through the agent loop (AC1/AC2/AC3)', () {
    AssistantMessage makeAssistant({
      List<ContentBlock> content = const [],
      StopReason stopReason = StopReason.stop,
    }) => AssistantMessage(
      content: content,
      api: 'test-api',
      provider: 'test-provider',
      model: 'test-model',
      usage: Usage.zero,
      stopReason: stopReason,
      timestamp: DateTime.utc(2026),
    );

    List<AssistantMessageEvent> makeToolTurn(List<ToolCall> calls) {
      final empty = makeAssistant();
      final partial = makeAssistant(
        content: calls,
        stopReason: StopReason.toolUse,
      );
      final events = <AssistantMessageEvent>[StartEvent(partial: empty)];
      for (var i = 0; i < calls.length; i++) {
        events
          ..add(ToolCallStartEvent(contentIndex: i, partial: empty))
          ..add(
            ToolCallEndEvent(
              contentIndex: i,
              toolCall: calls[i],
              partial: partial,
            ),
          );
      }
      events.add(DoneEvent(reason: StopReason.toolUse, message: partial));
      return events;
    }

    List<AssistantMessageEvent> makeTextTurn(String text) {
      final empty = makeAssistant();
      final partial = makeAssistant(content: [TextContent(text: text)]);
      return [
        StartEvent(partial: empty),
        TextStartEvent(contentIndex: 0, partial: empty),
        TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
        DoneEvent(reason: StopReason.stop, message: partial),
      ];
    }

    test('the conversion notice IS the tool result: exactly-once resolution, '
        'pairing intact, the turn continues, no extra record', () async {
      final env = _FakeBackgroundEnv(MemoryExecutionEnv(cwd: '/work'));
      final registry = ShellJobRegistry(env: env);
      final tool = shellTool(
        env,
        jobs: registry,
        autoBackgroundAfter: _conversionThreshold,
      );

      final turn2Context = Completer<Context>();
      AssistantMessageEventStream streamFunction(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        if (turn2Context.isCompleted) {
          // Third call: finish quietly (should never happen — two turns
          // only).
          for (final event in makeTextTurn('unexpected extra turn')) {
            stream.push(event);
          }
        } else if (context.messages.whereType<ToolResultMessage>().isEmpty) {
          for (final event in makeToolTurn([
            ToolCall(id: 'c1', name: 'bash', arguments: {'command': 'make'}),
          ])) {
            stream.push(event);
          }
        } else {
          turn2Context.complete(context);
          for (final event in makeTextTurn('continued after the conversion')) {
            stream.push(event);
          }
        }
        stream.end();
        return stream;
      }

      final agent = Agent(
        model: _model,
        streamFunction: streamFunction,
        toolExecutor: (toolCall, cancelToken, onUpdate) =>
            tool.execute(toolCall.arguments, cancelToken, onUpdate),
      );
      agent.state.tools = [tool];

      await agent.prompt('run the long thing');

      // AC1: the turn continued — the second provider round answered after
      // the conversion.
      final answers = agent.state.messages
          .whereType<AssistantMessage>()
          .where((m) => m.stopReason == StopReason.stop)
          .length;
      expect(answers, greaterThanOrEqualTo(1));

      // AC2: the conversion notice IS the tool result — the message list
      // carries it, and it rides the OUTBOUND context of the next request
      // (no separate steering record, no extra turn).
      final toolResults = agent.state.messages
          .whereType<ToolResultMessage>()
          .where((m) => m.toolCallId == 'c1')
          .toList();
      expect(toolResults, hasLength(1));
      final resultText = toolResults.single.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join('\n');
      expect(resultText, contains('moved to background job'));
      final context = await turn2Context.future;
      final outbound = context.messages
          .whereType<ToolResultMessage>()
          .where((m) => m.toolCallId == 'c1')
          .toList();
      expect(outbound, hasLength(1));
      expect(
        outbound.single.content.whereType<TextContent>().map((b) => b.text),
        contains(resultText),
      );

      // AC3: the pairing validator has nothing to fix.
      expect(validateToolPairing(context.messages), isEmpty);

      // The job is still running for the model to manage.
      expect(env.jobs.single.isRunning, isTrue);
      env.jobs.single.complete(0);
    });
  });

  group('WaitingConfig.autoBackgroundSeconds', () {
    test('defaults to the 60s liveness threshold', () {
      expect(const WaitingConfig().autoBackgroundSeconds, 60);
    });

    test('parses the yaml leaf; 0 is the kill switch', () {
      final parsed = WaitingConfig.fromYaml({'autoBackgroundSeconds': 0});
      expect(parsed.autoBackgroundSeconds, 0);
      final tuned = WaitingConfig.fromYaml({'autoBackgroundSeconds': 120});
      expect(tuned.autoBackgroundSeconds, 120);
    });

    test('rejects negative and non-integer values', () {
      expect(
        () => WaitingConfig.fromYaml({'autoBackgroundSeconds': -1}),
        throwsA(isA<ConfigException>()),
      );
      expect(
        () => WaitingConfig.fromYaml({'autoBackgroundSeconds': 'x'}),
        throwsA(isA<ConfigException>()),
      );
    });

    test('rejects unknown keys and round-trips through toYaml', () {
      expect(
        () => WaitingConfig.fromYaml({'autoBackground': 30}),
        throwsA(isA<ConfigException>()),
      );
      final parsed = WaitingConfig.fromYaml({'autoBackgroundSeconds': 90});
      expect(parsed.toYaml(), contains('autoBackgroundSeconds: 90'));
    });
  });
}
