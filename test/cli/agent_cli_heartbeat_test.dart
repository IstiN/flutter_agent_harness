import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Snapshot of the context a stream call received (the live transcript
/// mutates as the run continues, so capture at call time).
Context _snapshot(Context context) => Context(
  systemPrompt: context.systemPrompt,
  messages: List.of(context.messages),
  tools: context.tools,
);

void _emit(
  AssistantMessageEventStream stream,
  List<AssistantMessageEvent> events,
) {
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
}

List<AssistantMessageEvent> _abortedTurn() {
  final partial = testAssistant(
    content: const [TextContent(text: '')],
    stopReason: StopReason.aborted,
  );
  return [
    StartEvent(partial: testAssistant()),
    DoneEvent(reason: StopReason.aborted, message: partial),
  ];
}

/// Test stream function whose first call stays open on [gate] — the
/// deterministic way to hold the parent busy while the test fires a
/// heartbeat tick mid-run.
class _GatedStream {
  _GatedStream(this.gate);

  final Completer<void> gate;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(_snapshot(context));
    final stream = AssistantMessageEventStream();
    unawaited(
      gate.future.then((_) {
        _emit(stream, textTurn('parent done'));
      }),
    );
    return stream;
  }
}

/// A stream function that records every context it is handed and answers
/// instantly — the idle-wake and kill-switch probes.
class _RecordingStream {
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(_snapshot(context));
    final stream = AssistantMessageEventStream();
    _emit(stream, textTurn('acknowledged'));
    return stream;
  }
}

/// Scripted stream for the real-spawn loop test: parent calls draw from
/// [parentTurns] in order; every CHILD call (a context without any parent
/// marker) hangs on [childGate] — the deterministic way to keep a
/// background child RUNNING while the heartbeat fires. A cancelled child
/// surfaces as an aborted completion (the provider contract), without
/// waiting for the gate.
class _SpawnScriptStream {
  _SpawnScriptStream(this.parentTurns, this.childGate);

  static const _parentMarkers = ['delegate it', 'Subagent heartbeat'];

  final List<List<AssistantMessageEvent>> parentTurns;
  final Completer<void> childGate;
  final contexts = <Context>[];

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(_snapshot(context));
    final stream = AssistantMessageEventStream();
    if (_isParent(context)) {
      _emit(stream, parentTurns.removeAt(0));
    } else {
      final settle = _Once();
      unawaited(
        childGate.future.then((_) {
          settle(
            stream,
            (cancelToken?.isCancelled ?? false)
                ? _abortedTurn()
                : textTurn('scout done'),
          );
        }),
      );
      unawaited(
        (cancelToken?.onCancel ?? Future<void>.value()).then((_) {
          settle(stream, _abortedTurn());
        }),
      );
    }
    return stream;
  }

  bool _isParent(Context context) {
    final text = [
      for (final message in context.messages)
        if (message is UserMessage) _textContent(message),
    ].join('\n');
    return _parentMarkers.any(text.contains);
  }

  static String _textContent(UserMessage message) {
    final content = message.content;
    if (content is String) return content;
    return [
      for (final block in content as List<ContentBlock>)
        if (block is TextContent) block.text,
    ].join();
  }
}

/// Emits a turn's events exactly once (the gate and the cancel race).
class _Once {
  bool _done = false;

  void call(
    AssistantMessageEventStream stream,
    List<AssistantMessageEvent> events,
  ) {
    if (_done) return;
    _done = true;
    _emit(stream, events);
  }
}

/// AC4/AC6 delivery semantics for the background-subagent heartbeat
/// (issue #383) at the CLI wiring level: the digest rides the SAME
/// steer/wake channel as task-job completions, `heartbeatMinutes: 0`
/// kills the whole mechanism, and a really spawned child (AC5/AC7) gets
/// its digest end-to-end — the parent acts on it.
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

  AgentCli buildCli(
    _GatedStream? gated,
    _RecordingStream? recording, {
    SubagentsConfig subagents = const SubagentsConfig(),
    AssistantMessageEventStream Function(
      Model,
      Context, {
      CancelToken? cancelToken,
    })?
    rawStream,
  }) {
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
        subagents: subagents,
      ),
      io: io,
      streamFunction: gated?.call ?? recording?.call ?? rawStream!,
    );
  }

  /// Waits for the CLI to persist its session (boot complete).
  Future<void> waitForSessions(MemoryExecutionEnv scope) async {
    final repo = JsonlSessionRepo(fs: scope, sessionsRoot: '/sessions');
    for (var i = 0; i < 5000; i++) {
      if ((await repo.list(cwd: '/work')).isNotEmpty) return;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('timed out waiting: session persisted');
  }

  /// Plants a RUNNING zombie child (no provider requests, no activity
  /// since spawn) in the live registry — the fix355 dead-on-arrival shape.
  Future<void> plantZombie(AgentCli cli) async {
    await cli.subagentManagerForTest.register(
      id: 'z1',
      name: 'zombie',
      agentType: 'task',
      task: 'fix the provider',
    );
    await cli.subagentManagerForTest.update(
      'z1',
      status: SubagentStatus.running,
    );
  }

  String lastUserText(Context context) {
    final message = context.messages.last;
    if (message is! UserMessage) return '';
    final content = message.content;
    if (content is String) return content;
    return [
      for (final block in content as List<ContentBlock>)
        if (block is TextContent) block.text,
    ].join();
  }

  test(
    'a digest for a stalled child steers into the busy parent and lands '
    'at the next step boundary',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final gate = Completer<void>();
      final stream = _GatedStream(gate);
      final cli = buildCli(stream, null);
      final run = cli.run();
      await waitForSessions(env);

      await plantZombie(cli);
      io.sendLine('start');
      await waitForIt(() => cli.isBusy);
      cli.heartbeatTickForTest();

      // Busy parent: nothing is woken mid-turn; the digest waits in the
      // steering queue until the gated turn ends.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(cli.isBusy, isTrue);
      gate.complete();
      await waitForIt(() => !cli.isBusy, reason: 'gated turn settles');

      // The steered digest became the follow-up turn's user message —
      // the same step-boundary delivery user steering gets.
      await waitForIt(() => stream.contexts.length >= 2);
      final digestText = lastUserText(stream.contexts[1]);
      expect(digestText, contains('Subagent heartbeat'));
      expect(digestText, contains('z1 (task)'));
      expect(digestText, contains('[WARN] STALLED'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'an idle parent is woken by the digest, which arrives as a fresh run',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _RecordingStream();
      final cli = buildCli(null, stream);
      final run = cli.run();
      await waitForSessions(env);
      await plantZombie(cli);

      cli.heartbeatTickForTest();
      await waitForIt(
        () => stream.contexts.isNotEmpty,
        reason: 'digest wakes parent',
      );

      final digestText = lastUserText(stream.contexts.first);
      expect(digestText, contains('Subagent heartbeat'));
      expect(digestText, contains('z1 (task)'));
      expect(digestText, contains('[WARN] STALLED'));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'heartbeatMinutes: 0 is a hard kill switch — no digest, no wake',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final stream = _RecordingStream();
      final cli = buildCli(
        null,
        stream,
        subagents: const SubagentsConfig(heartbeatMinutes: 0),
      );
      final run = cli.run();
      await waitForSessions(env);
      await plantZombie(cli);

      cli.heartbeatTickForTest();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(stream.contexts, isEmpty, reason: 'no digest run may start');
      expect(io.out.toString(), isNot(contains('Subagent heartbeat')));

      io.sendLine('/exit');
      await run;
    },
  );

  test(
    'AC5/AC7: a really spawned background child gets a digest; the parent '
    'acts on it by cancelling the zombie',
    timeout: const Timeout(Duration(seconds: 120)),
    () async {
      final childGate = Completer<void>();
      final stream = _SpawnScriptStream([
        // 1. The parent delegates a background agent.
        toolTurn([
          ToolCall(
            id: 't1',
            name: 'task',
            arguments: const {
              'context': 'repo state',
              'background': true,
              'tasks': [
                {'name': 'Scout', 'task': 'survey the repo'},
              ],
            },
          ),
        ]),
        // 2. The parent wraps up its own turn (idle while the child runs).
        textTurn('delegate it'),
        // 3. Acting on the digest: cancel the stalled zombie.
        toolTurn([
          ToolCall(
            id: 'c1',
            name: 'task_cancel',
            arguments: const {'id': 'Scout'},
          ),
        ]),
        // 4. The parent confirms the cancel in words.
        textTurn('cancelled the zombie'),
        // 5. Anything after the cancel settles.
        textTurn('integrated'),
      ], childGate);
      final cli = buildCli(null, null, rawStream: stream.call);
      final run = cli.run();
      await waitForSessions(env);

      io.sendLine('delegate it');
      // The child spawned and hangs on the gate — genuinely running.
      await waitForIt(() => !cli.isBusy, reason: 'parent settles');
      await waitForIt(() {
        final scout = cli.subagentManagerForTest['Scout'];
        return scout != null && scout.status == SubagentStatus.running;
      });

      // The heartbeat fires while the child is still running: the idle
      // parent must wake with the digest as its prompt.
      cli.heartbeatTickForTest();
      await waitForIt(
        () => stream.contexts.any(
          (context) => lastUserText(context).contains('Subagent heartbeat'),
        ),
        reason: 'digest wake run started',
      );
      final wakeContext = stream.contexts.lastWhere(
        (context) => lastUserText(context).contains('Subagent heartbeat'),
      );
      final digestText = lastUserText(wakeContext);
      expect(digestText, contains('[WARN] STALLED'));
      expect(digestText, contains('Scout (task)'));

      // Parent acts: the scripted cancel lands; the child aborts.
      await waitForIt(
        () => io.out.toString().contains('[task] Scout (task) aborted'),
        reason: 'task_cancel aborted the child',
      );
      expect(io.out.toString(), contains('cancelled the zombie'));

      childGate.complete();
      io.sendLine('/exit');
      await run;
    },
  );
}
