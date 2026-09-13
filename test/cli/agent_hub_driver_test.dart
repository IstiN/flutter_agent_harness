import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// A [Shell] + [BackgroundShell] whose jobs are born already-settled: the
/// deterministic way to drive the task-block lifecycle (start block, close
/// block, settle steering) without real processes.
class _FakeBgShell implements Shell, BackgroundShell {
  @override
  bool get backgroundJobsSupported => true;

  @override
  Future<Result<ShellExecResult, ExecutionError>> exec(
    String command, {
    ShellExecOptions? options,
  }) async {
    // Foreground exec behaves like an unavailable shell (boot probes fail
    // cleanly, as with the default test env); only detached jobs work.
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
  bool get isRunning => false;
  @override
  int? get exitCode => 0;
  @override
  Future<void> get settled => Future.value();
  @override
  String? get stopReason => null;
  @override
  Future<void> stop() async {}
}

/// The text of a user message (string or content-block content).
String _messageText(UserMessage message) {
  final content = message.content;
  if (content is String) return content;
  return [
    for (final block in content as List<ContentBlock>)
      if (block is TextContent) block.text,
  ].join();
}

/// Waits for the CLI to persist its session (boot complete).
Future<void> waitForSessions(MemoryExecutionEnv env) async {
  final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  for (var i = 0; i < 5000; i++) {
    if ((await repo.list(cwd: '/work')).isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
  fail('timed out waiting: session persisted');
}

/// The hub drivers against a real [AgentCli] (issue #277): background shell
/// jobs render as task blocks, drained fabric mail renders as deferred
/// panels, and /mail + /reply resolve them.
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

  AgentCli buildCli(StreamFunction stream, {Shell? shell}) {
    env = MemoryExecutionEnv(
      cwd: '/work',
      shell: shell ?? const UnavailableShell(),
    );
    return AgentCli(
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
      ),
      io: io,
      streamFunction: stream,
    );
  }

  test(
    'a background bash job renders a start block and a settled block',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final turns = <List<AssistantMessageEvent>>[
        toolTurn([
          const ToolCall(
            id: 't1',
            name: 'bash',
            arguments: {'command': 'sleep 2', 'background': true},
          ),
        ]),
        textTurn('job started'),
        // The settle notice may arrive as a leftover steer and start a
        // follow-up run; keep a turn ready for it.
        textTurn('acknowledged'),
      ];
      final contexts = <Context>[];
      final cli = buildCli((model, context, {cancelToken}) {
        contexts.add(
          Context(
            systemPrompt: context.systemPrompt,
            messages: List.of(context.messages),
            tools: context.tools,
          ),
        );
        final stream = AssistantMessageEventStream();
        for (final event in turns.removeAt(0)) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }, shell: _FakeBgShell());
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('start');
      await waitForIt(
        () => contexts.length >= 2 && !cli.isBusy,
        reason: 'the tool run starts and settles',
      );
      // The born-settled job's notice steers the model (registry onSettled
      // → isBusy → steer) at the step boundary before the second call.
      await waitForIt(
        () => contexts.any(
          (context) => context.messages.any(
            (message) =>
                message is UserMessage &&
                _messageText(message).contains('Background shell job sh-1-'),
          ),
        ),
        reason: 'the settle notice steers the model',
      );

      final out = io.out.toString();
      expect(
        RegExp('bash sh-1-\\S+ · running').hasMatch(out),
        isTrue,
        reason: 'the start block names the job and its state',
      );
      expect(out, contains('sleep 2'));
      expect(
        RegExp('bash sh-1-\\S+ · done').hasMatch(out),
        isTrue,
        reason: 'the block closes with the exit code',
      );
      expect(out, contains('exit 0'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'drained fabric mail renders a panel, steers the run, and /reply '
    'answers the sender',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final turns = <List<AssistantMessageEvent>>[
        textTurn('one'),
        // The tail-boundary steering (mail arrives mid-run) may start a
        // follow-up run; keep a turn ready for it.
        textTurn('two'),
        textTurn('three'),
      ];
      final contexts = <Context>[];
      final cli = buildCli((model, context, {cancelToken}) {
        contexts.add(
          Context(
            systemPrompt: context.systemPrompt,
            messages: List.of(context.messages),
            tools: context.tools,
          ),
        );
        final stream = AssistantMessageEventStream();
        for (final event in turns.removeAt(0)) {
          stream.push(event);
        }
        stream.end();
        return stream;
      });
      final run = cli.run();
      await waitForSessions(env);

      // Pre-write fabric mail to this session's main mailbox: the run's
      // steering poll drains it mid-run (issue #277 E1). The file name is
      // the message id — that is what the drain moves to read/.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final sessionId = (await repo.list(cwd: '/work')).first.id;
      final messagesRoot = '/sessions/${encodeSessionCwd('/work')}/messages';
      final mailbox = FileMessagingRepository.sanitizeAgentId(
        '$sessionId/main',
      );
      await env.writeFile(
        '$messagesRoot/$mailbox/inbox/m1.json',
        jsonEncode({
          'id': 'm1',
          'fromId': 'explore#1',
          'toId': '$sessionId/main',
          'text': 'what about the retry path?',
          'sentAt': '2026-09-13T00:00:00Z',
          'hops': 0,
        }),
      );

      io.sendLine('start');
      // The mail steers a run (same-run boundary or a follow-up run) and
      // the panel block renders at delivery time.
      await waitForIt(
        () => contexts.any(
          (context) => context.messages.any(
            (message) =>
                message is UserMessage &&
                _messageText(message).contains('from explore#1'),
          ),
        ),
        reason: 'the mail steers a run',
      );
      await waitForIt(
        () => io.out.toString().contains('btw · mail from explore#1'),
        reason: 'the panel block renders',
      );
      await waitForIt(() => !cli.isBusy, reason: 'all runs settle');

      expect(io.out.toString(), contains('what about the retry path?'));
      expect(io.out.toString(), contains('reply: /reply explore#1'));
      expect(
        io.out.toString(),
        contains('[btw] mail from explore#1 → complete'),
        reason: 'the panel completes when the run settles',
      );

      io.sendLine('/mail');
      await waitForIt(
        () => io.out.toString().contains('btw-1'),
        reason: '/mail lists the panel',
      );
      expect(io.out.toString(), contains('mail from explore#1 · complete'));

      io.sendLine('/mail btw-1');
      await waitForIt(
        () => io.out.toString().contains('reply: /reply explore#1'),
      );

      io.sendLine('/reply btw-1 use retries with backoff');
      await waitForIt(
        () => io.out.toString().contains('reply queued to explore#1'),
        reason: '/reply resolves the panel to its reply address',
      );
      final fileFabric = FileMessagingRepository(env: env, root: messagesRoot);
      final pending = await fileFabric.peek('explore#1');
      expect(
        pending.map((message) => message.text),
        contains('use retries with backoff'),
        reason: 'the reply actually landed in the sender mailbox',
      );

      io.sendLine('/exit');
      await run;
    },
  );
}
