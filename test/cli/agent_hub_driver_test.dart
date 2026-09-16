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
      // Line mode has no live region: the running wall never exists, the
      // terminal card carries the truth at settle (issue #429 S1).
      expect(out, isNot(contains('running')));
      expect(out, contains('sleep 2'));
      expect(
        out.contains('bash task completed in background'),
        isTrue,
        reason: 'the settled card carries the truthful terminal headline',
      );
      expect(
        RegExp('sh-1-\\S+ · .*exit 0').hasMatch(out),
        isTrue,
        reason: 'the id lives in the dim detail with the exit code',
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'more than 3 background jobs in a turn collapse into ONE summary card',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final turns = <List<AssistantMessageEvent>>[
        toolTurn([
          for (var i = 0; i < 5; i++)
            ToolCall(
              id: 't$i',
              name: 'bash',
              arguments: {'command': 'sleep $i', 'background': true},
            ),
        ]),
        textTurn('jobs started'),
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
        reason: 'the collapsed turn starts and settles',
      );
      await waitForIt(
        () => contexts.any(
          (context) => context.messages.any(
            (message) =>
                message is UserMessage &&
                _messageText(message).contains('Background shell job sh-'),
          ),
        ),
        reason: 'the settle notices steer the model',
      );

      final out = io.out.toString();
      // One summary card, no wall of individual start/settled cards.
      expect(
        'Background jobs (5)'.allMatches(out),
        hasLength(1),
        reason: 'exactly one summary card for the collapsed turn',
      );
      expect(out, contains('5 done'));
      expect(out, isNot(contains('bash task started in background')));
      expect(out, isNot(contains('bash task completed in background')));

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

  test(
    'steering left after settle runs a follow-up turn',
    timeout: const Timeout(Duration(seconds: 60)),
    () async {
      final contexts = <Context>[];
      final turns = <List<AssistantMessageEvent>>[
        textTurn('one'),
        textTurn('two'),
      ];
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

      io.sendLine('start');
      await waitForIt(
        () => contexts.length == 1 && !cli.isBusy,
        reason: 'the first run settles',
      );
      // Queue a steer AFTER the run settled — the exact "typed while the
      // model streamed its last bytes" race (the message missed every
      // drain point and sits in the agent queue) — then settle it by
      // hand (the same resolution the CLI runs on every settle; racing
      // the real window from a test would be flaky). An IDLE steer goes
      // through the wake path instead (issue #437 AC4), so the race is
      // injected at the queue level.
      cli.agent.steer(UserMessage.text('late steer'));
      cli.settleLeftoverSteeringForTest();
      await waitForIt(
        () => contexts.length == 2 && !cli.isBusy,
        reason: 'the leftover steering runs a follow-up turn',
      );
      expect(
        io.out.toString(),
        contains('steering arrived after the last checkpoint'),
      );
      expect(
        contexts[1].messages.any(
          (message) =>
              message is UserMessage &&
              _messageText(message).contains('late steer'),
        ),
        isTrue,
      );

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'hub driver seams expose the tree, transcript and action paths',
    () async {
      final cli = buildCli((model, context, {cancelToken}) {
        final stream = AssistantMessageEventStream();
        stream.end();
        return stream;
      });
      // Seed a child session the handle points at, mirroring what the
      // executor's attachSession does at completion.
      final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
      final session = await repo.create(
        const JsonlSessionCreateOptions(cwd: '/work'),
      );
      await session.appendMessage(UserMessage.text('child transcript line'));
      final path = (await session.getMetadata()).path;
      await cli.subagentManager.register(
        id: 'drill#1',
        name: 'drill#1',
        agentType: 'explore',
        task: 'scout',
      );
      await cli.subagentManager.attachSession('drill#1', path);
      await cli.subagentManager.update(
        'drill#1',
        status: SubagentStatus.running,
        tokens: 512,
      );

      // The tree assembly mirrors what `/agents` bare pushes: the main
      // agent row plus the live child with its metrics.
      final (rows, footer) = cli.hubTreeForTest();
      expect(rows.first.agent.id, 'main');
      // The idle main (no run in flight) plus the live child.
      expect(footer.running, 1);

      // The transcript push renders the child's session ledger.
      final (lines, running) = await cli.hubTranscriptForTest('drill#1');
      expect(lines.join('\n'), contains('child transcript line'));
      expect(running, isTrue, reason: 'a running child keeps the follow armed');

      // The action router: enter drills into the transcript, back returns
      // to the tree, close hides the overlay (no TUI attached: pushes no-op).
      await cli.hubActionForTest('enter', 'drill#1');
      await cli.hubActionForTest('back', null);
      await cli.hubActionForTest('close', null);
    },
  );
}
