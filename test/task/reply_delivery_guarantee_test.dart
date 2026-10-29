@TestOn('vm')
/// gh-1951 — subagent deliverables are guaranteed: an explicit `reply`
/// reaches the parent verbatim (or as a resolvable `agent://` envelope),
/// "delivered" is acknowledged only when the parent-visible record exists,
/// and a resumed child's final answer rides the completion notice.
///
/// Regression surface (the incident): a child `reply`ed a 7909-char report
/// under the 8000 budget; the ack said "reply delivered to the parent";
/// the parent task result + task_observe carried only the child's later
/// content-free completion text. BOTH parent-visible renders (the blocking
/// `_renderResults` text and the background `taskAsyncResultNotice`
/// envelope) dropped `result.reply` on the floor.
library;

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
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
  String? errorMessage,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
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

List<AssistantMessageEvent> _toolTurn(
  String toolName,
  Map<String, dynamic> args, {
  StopReason reason = StopReason.toolUse,
}) {
  final empty = _assistant();
  final call = ToolCall(id: 'call-1', name: toolName, arguments: args);
  final partial = _assistant(content: [call], stopReason: reason);
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: reason, message: partial),
  ];
}

/// A scripted fake [StreamFunction]: routes by last user message and
/// records every context.
final class _ScriptedStream {
  _ScriptedStream([List<({String match, List<List<AssistantMessageEvent>> turns})> rules = const []])
    : _rules = List.of(rules);

  final List<({String match, List<List<AssistantMessageEvent>> turns})> _rules;
  final contexts = <Context>[];

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

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final text = lastUserText(context);
    for (final rule in _rules) {
      if (text.contains(rule.match) && rule.turns.isNotEmpty) {
        return _streamOf(rule.turns.removeAt(0));
      }
    }
    return _streamOf(_textTurn('done'));
  }

  static AssistantMessageEventStream _streamOf(
    List<AssistantMessageEvent> events,
  ) {
    final stream = AssistantMessageEventStream();
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }
}

/// The task-tool rig: a manager (so children carry the reply tool), the
/// session job registry, and the real executor.
final class _Harness {
  _Harness(this.tool, this.config, this.stream) : streamFn = stream.call;

  final AgentTool tool;
  final TaskToolConfig config;
  final _ScriptedStream stream;
  final StreamFunction streamFn;

  SubagentManager get manager => config.subagentManager!;
  TaskJobManager get jobs => config.jobManager;
  AgentOutputStore get outputs => config.outputs;
}

Future<_Harness> _harness({
  List<({String match, List<List<AssistantMessageEvent>> turns})> rules =
  const [],
  int maxReplyChars = 800,
}) async {
  final s = _ScriptedStream(rules);
  final manager = SubagentManager(
    parentSessionId: 'p',
    maxReplyChars: maxReplyChars,
  )..mailboxPrefix = 'p';
  final config = TaskToolConfig(
    childTools: const [],
    streamFunction: () => s.call,
    model: () => _model,
    subagentManager: manager,
  );
  return _Harness(taskTool(config: config), config, s);
}

String _text(ToolExecutionResult result) =>
    result.content.whereType<TextContent>().map((b) => b.text).join('\n');

/// A reply body of exactly [n] chars with a canary prefix so byte-identity
/// is checkable.
String _payload(int n) => 'R' * n;

void main() {
  group('AC1: an explicit reply rides the parent-visible result', () {
    test(
      'blocking render carries the reply verbatim, not just the final text',
      () async {
        const reply = 'the full findings report, verbatim and complete';
        final h = await _harness(
          rules: [
            (
              match: 'report job',
              turns: [
                _toolTurn('reply', {'message': reply}),
                // The child then adds a CONTENT-FREE final text (the
                // incident's shape: the parent used to see ONLY this).
                _textTurn('Report delivered with the verified counts.'),
              ],
            ),
          ],
        );
        final result = await h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'name': 'Kid', 'task': 'report job'},
            ],
          },
          null,
          null,
        );
        final text = _text(result);
        // The reply message is in the parent-visible text byte-identical…
        expect(text, contains(reply));
        // …labeled as the explicit reply, distinct from the final text…
        expect(text, contains('[explicit reply]'));
        expect(text, contains('[explicit reply end]'));
        expect(text.indexOf(reply), lessThan(text.indexOf('Report delivered')));
        // …and the final-message output stays addressable.
        expect(text, contains('[Full output: agent://Kid]'));
        // No completed_without_reply marker when a reply exists.
        expect(text, isNot(contains('completed_without_reply')));
      },
    );

    test('near-cap boundary: 799 and 800 chars ride verbatim', () async {
      for (final n in const [799, 800]) {
        final payload = _payload(n);
        final marker = 'PAY-$n';
        final body = '$marker$payload'.substring(0, n);
        final h = await _harness(
          rules: [
            (
              match: 'job',
              turns: [
                _toolTurn('reply', {'message': body}),
                _textTurn('done'),
              ],
            ),
          ],
        );
        final result = await h.tool.execute(
          {
            'context': 'ctx',
            'tasks': [
              {'name': 'Kid$n', 'task': 'job $n'},
            ],
          },
          null,
          null,
        );
        final text = _text(result);
        expect(text, contains(body), reason: 'cap boundary $n must ride '
            'verbatim');
        expect(text, isNot(contains('[deliverable complete')), reason:
            'an in-budget reply never becomes an artifact (n=$n)');
      }
    });

    test('over-cap (801) keeps the #1829 envelope contract (AC4)', () async {
      final body = _payload(801);
      final h = await _harness(
        rules: [
          (
            match: 'job',
            turns: [
              _toolTurn('reply', {'message': body}),
              _textTurn('done'),
            ],
          ),
        ],
      );
      final result = await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'Kid', 'task': 'job'},
          ],
        },
        null,
        null,
      );
      final text = _text(result);
      // The envelope: pointer + explicit completeness. The full raw body
      // does NOT ride the result text (bounded excerpt instead).
      expect(text, contains('agent://'));
      expect(text, contains('deliverable complete'));
      expect(text, isNot(contains(body)));
      // The artifact resolves to the full body.
      final record = h.manager['Kid']!.deliverables.single;
      expect(h.outputs.get(record.outputId!), body);
    });

    test('no reply: the completed_without_reply notice names the final text',
        () async {
      final h = await _harness(
        rules: [
          (match: 'job', turns: [_textTurn('bare final message')]),
        ],
      );
      final result = await h.tool.execute(
        {
          'context': 'ctx',
          'tasks': [
            {'name': 'Kid', 'task': 'job'},
          ],
        },
        null,
        null,
      );
      final text = _text(result);
      expect(text, contains('completed_without_reply'));
      expect(text, contains('bare final message'));
    });

    test('background settle notice carries the reply verbatim', () async {
      const reply = 'background findings, delivered verbatim';
      final h = await _harness(
        rules: [
          (
            match: 'bg job',
            turns: [
              _toolTurn('reply', {'message': reply}),
              _textTurn('bg final stub'),
            ],
          ),
        ],
      );
      final result = await h.tool.execute(
        {
          'context': 'ctx',
          'background': true,
          'tasks': [
            {'name': 'Bg', 'task': 'bg job'},
          ],
        },
        null,
        null,
      );
      expect(_text(result), contains('agent://Bg'));
      await h.jobs.settled;
      final notice = taskAsyncResultNotice(h.jobs.job('Bg')!);
      expect(notice, contains(reply));
      expect(notice, contains('[explicit reply]'));
      expect(notice, contains('[Full output: agent://Bg]'));
    });
  });

  group('AC2: the reply ack is truthful', () {
    test(
      'a reply with no parent-visible record is an ERROR, never a false ack',
      () async {
        // The manager never registered the child the scope names: there is
        // NO parent-visible record to write to. The tool used to ack
        // "reply delivered to the parent" anyway (gh-1951 AC2 violation).
        final manager = SubagentManager(parentSessionId: 'p');
        final store = AgentOutputStore();
        final capture = DeliverableCapture(store: store, manager: manager);
        final tools = {
          for (final t in subagentMonitoringTools(
            manager: manager,
            currentSubagentId: () => 'ghost',
            capture: () => capture,
          ))
            t.name: t,
        };
        final result = await tools['reply']!.execute({
          'message': 'nobody is listening',
        }, null, null);
        expect(_text(result), startsWith('error:'));
        expect(_text(result), isNot(contains('reply delivered')));
      },
    );

    test('recordReply reports whether the parent-visible record landed', ()
        async {
      final manager = SubagentManager(parentSessionId: 'p')
        ..mailboxPrefix = 'p';
      await manager.register(id: 'kid', name: 'kid', agentType: 'task',
          task: 't');
      expect(await manager.recordReply('kid', 'first'), isTrue);
      expect(manager['kid']!.lastReply, 'first');
      // Unknown child: nothing recorded, caller must not ack.
      expect(await manager.recordReply('ghost', 'x'), isFalse);
    });

    test('double reply is idempotent: first wins, second noted', () async {
      final manager = SubagentManager(parentSessionId: 'p')
        ..mailboxPrefix = 'p';
      await manager.register(id: 'kid', name: 'kid', agentType: 'task',
          task: 't');
      final store = AgentOutputStore();
      final capture = DeliverableCapture(store: store, manager: manager);
      final tools = {
        for (final t in subagentMonitoringTools(
          manager: manager,
          currentSubagentId: () => 'kid',
          capture: () => capture,
        ))
          t.name: t,
      };
      await tools['reply']!.execute({'message': 'first reply'}, null, null);
      final second = await tools['reply']!.execute(
        {'message': 'second reply'},
        null,
        null,
      );
      // The FIRST reply is the deliverable.
      expect(manager['kid']!.lastReply, 'first reply');
      // The second call is NOT a false "delivered" ack — it is noted.
      expect(_text(second), contains('already recorded'));
      expect(_text(second), isNot(contains('reply delivered')));
      expect(manager['kid']!.duplicateReplies, 1);
    });

    test('empty reply message is rejected at the tool, not dropped', () async {
      final manager = SubagentManager(parentSessionId: 'p')
        ..mailboxPrefix = 'p';
      await manager.register(id: 'kid', name: 'kid', agentType: 'task',
          task: 't');
      final store = AgentOutputStore();
      final capture = DeliverableCapture(store: store, manager: manager);
      final tools = {
        for (final t in subagentMonitoringTools(
          manager: manager,
          currentSubagentId: () => 'kid',
          capture: () => capture,
        ))
          t.name: t,
      };
      final result = await tools['reply']!.execute({'message': '   '}, null,
          null);
      expect(_text(result), contains('error:'));
      expect(manager['kid']!.lastReply, isNull);
    });

    test('the ack rides only after the durable snapshot chain flushes',
        () async {
      final manager = SubagentManager(parentSessionId: 'p')
        ..mailboxPrefix = 'p';
      await manager.register(id: 'kid', name: 'kid', agentType: 'task',
          task: 't');
      final store = AgentOutputStore();
      final capture = DeliverableCapture(store: store, manager: manager);
      final tools = {
        for (final t in subagentMonitoringTools(
          manager: manager,
          currentSubagentId: () => 'kid',
          capture: () => capture,
        ))
          t.name: t,
      };
      final result = await tools['reply']!.execute({'message': 'acked'}, null,
          null);
      expect(_text(result), contains('reply delivered'));
      // The reply tool awaited persistNow() before acking: the chain has
      // fully drained.
      await manager.persistNow();
      expect(manager['kid']!.lastReply, 'acked');
    });
  });

  group('AC1 observe: the reply payload is visible from the parent side', () {
    test('childMessageText echoes the reply/agent_message payload', () {
      final call = ToolCall(id: 'c1', name: 'reply', arguments: {
        'message': 'the observed report payload',
      });
      final assistant = AssistantMessage(
        content: [call],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.utc(2026),
      );
      final text = childMessageText(assistant);
      expect(text, contains('[tool call: reply]'));
      expect(text, contains('the observed report payload'));
    });

    test('a non-deliverable tool call does not echo arguments', () {
      final call = ToolCall(id: 'c1', name: 'bash', arguments: {
        'command': 'echo secret-sauce',
      });
      final assistant = AssistantMessage(
        content: [call],
        api: 'test-api',
        provider: 'test-provider',
        model: 'test-model',
        usage: Usage.zero,
        stopReason: StopReason.toolUse,
        timestamp: DateTime.utc(2026),
      );
      final text = childMessageText(assistant);
      expect(text, contains('[tool call: bash]'));
      expect(text, isNot(contains('secret-sauce')));
    });
  });

  group('AC3: a resumed child\'s final answer rides the completion notice', () {
    test(
      'task_send on a completed child publishes the resumed final message '
      'through the job completions stream',
      () async {
        final wiring = await _ResumeWiring(
          resumeTurns: [_textTurn('RESUMED-FINAL-ANSWER')],
        );
        addTearDown(wiring.dispose);
        // First life: a bare completion (no explicit reply).
        await wiring.spawn('Watcher', 'batch-work');
        expect(wiring.manager['Watcher']!.lastReply, isNull);

        final notices = <TaskJob>[];
        final sub = wiring.jobs.completions.listen(notices.add);
        addTearDown(() => sub.cancel());

        await wiring.executor.resumeChild('Watcher', 'return the findings');
        await wiring.drainMicrotasks();

        expect(notices, hasLength(1), reason:
            'the resumed run must publish a completion through the SAME '
            'stream every host already consumes');
        final notice = taskAsyncResultNotice(notices.single);
        expect(notice, contains('RESUMED-FINAL-ANSWER'));
        expect(notices.single.status, TaskJobStatus.completed);
        // The latest final text is addressable under the child id.
        expect(wiring.outputs.get('Watcher'), 'RESUMED-FINAL-ANSWER');
      },
    );

    test('a resumed run\'s own reply rides the notice verbatim', () async {
      final wiring = await _ResumeWiring(
        resumeTurns: [
          _toolTurn('reply', {'message': 'fresh resumed reply'}),
          _textTurn('done'),
        ],
      );
      addTearDown(wiring.dispose);
      await wiring.spawn('Watcher', 'batch-work');

      final notices = <TaskJob>[];
      final sub = wiring.jobs.completions.listen(notices.add);
      addTearDown(() => sub.cancel());

      await wiring.executor.resumeChild('Watcher', 'again, with the reply');
      await wiring.drainMicrotasks();

      final notice = taskAsyncResultNotice(notices.single);
      expect(notice, contains('fresh resumed reply'));
      expect(notice, contains('[explicit reply]'));
    });

    test('a failed resume publishes its named error — never silence',
        () async {
      final wiring = await _ResumeWiring(resumeTurns: const [], failResume:
          'provider quota exhausted');
      addTearDown(wiring.dispose);
      await wiring.spawn('Watcher', 'batch-work');

      final notices = <TaskJob>[];
      final sub = wiring.jobs.completions.listen(notices.add);
      addTearDown(() => sub.cancel());

      await expectLater(
        wiring.executor.resumeChild('Watcher', 'try again'),
        throwsA(isA<StateError>()),
      );
      await wiring.drainMicrotasks();

      expect(notices, hasLength(1));
      expect(notices.single.status, TaskJobStatus.failed);
      expect(taskAsyncResultNotice(notices.single), contains('provider quota'));
    });
  });

  group('AC6: a reply acked before a kill survives the resume', () {
    test(
      'pending reply rides the resume completion as a resolvable artifact',
      () async {
        final wiring = await _ResumeWiring(
          resumeTurns: [_textTurn('resumed, nothing more to add')],
        );
        addTearDown(wiring.dispose);
        await wiring.spawn('Watcher', 'batch-work');
        // The kill-and-resume shape: a reply was acked (handle recorded) in
        // a previous life whose completion never surfaced it.
        await wiring.manager.recordReply('Watcher', 'THE-PENDING-REPORT');

        final notices = <TaskJob>[];
        final sub = wiring.jobs.completions.listen(notices.add);
        addTearDown(() => sub.cancel());

        await wiring.executor.resumeChild('Watcher', 'wrap up');
        await wiring.drainMicrotasks();

        final notice = taskAsyncResultNotice(notices.single);
        // The pending reply is discoverable: pointer line on the notice…
        expect(notice, contains('agent://'));
        expect(notice, contains('deliverable complete'));
        // …and the artifact resolves to the pending text.
        final record = wiring.manager['Watcher']!.deliverables.last;
        expect(wiring.outputs.get(record.outputId!), 'THE-PENDING-REPORT');
        expect(record.pointer, isNotNull);
        expect(notice, contains(record.pointer!));
        // The resumed run's own answer rides too.
        expect(notice, contains('resumed, nothing more to add'));
      },
    );

    test(
      'a resumed run WITHOUT any reply anywhere still names the gap',
      () async {
        final wiring = await _ResumeWiring(
          resumeTurns: [_textTurn('silent resume')],
        );
        addTearDown(wiring.dispose);
        await wiring.spawn('Watcher', 'batch-work');

        final notices = <TaskJob>[];
        final sub = wiring.jobs.completions.listen(notices.add);
        addTearDown(() => sub.cancel());

        await wiring.executor.resumeChild('Watcher', 'again');
        await wiring.drainMicrotasks();

        final notice = taskAsyncResultNotice(notices.single);
        expect(notice, contains('completed_without_reply'));
        expect(notice, contains('silent resume'));
      },
    );
  });
}

/// Resume-path wiring with REAL JSONL child sessions (mirrors the CLI
/// host wiring): MemoryExecutionEnv-backed repo, factory + opener wired.
final class _ResumeWiring {
  _ResumeWiring({
    List<List<AssistantMessageEvent>> resumeTurns = const [],
    this.failResume,
  }) : _resumeTurns = List.of(resumeTurns) {
    env = MemoryExecutionEnv(cwd: '/work');
    repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
    manager = SubagentManager(parentSessionId: 'parent-session')
      ..mailboxPrefix = 'parent-session';
    jobs = TaskJobManager();
    executor = TaskExecutor(
      childTools: const [],
      streamFunction: () => _stream,
      model: () => _model,
      registry: TaskAgentRegistry(const []),
      semaphore: Semaphore(4),
      store: outputs,
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
      childSessionOpener: (path) async =>
          Session(await JsonlSessionStorage.open(env, path)),
      resultPublisher: (result) => jobs.publishResumed(result),
    );
  }

  late final MemoryExecutionEnv env;
  late final JsonlSessionRepo repo;
  late final SubagentManager manager;
  late final TaskJobManager jobs;
  late final TaskExecutor executor;
  final outputs = AgentOutputStore();
  final List<List<AssistantMessageEvent>> _resumeTurns;
  final String? failResume;

  AssistantMessageEventStream _stream(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    if (failResume != null) {
      final empty = _assistant();
      return _streamOf([
        StartEvent(partial: empty),
        ErrorEvent(
          reason: StopReason.error,
          error: _assistant(
            stopReason: StopReason.error,
            errorMessage: failResume,
          ),
        ),
      ]);
    }
    if (_resumeTurns.isNotEmpty) {
      return _streamOf(_resumeTurns.removeAt(0));
    }
    return _streamOf(_textTurn('done'));
  }

  static AssistantMessageEventStream _streamOf(
    List<AssistantMessageEvent> events,
  ) {
    final stream = AssistantMessageEventStream();
    for (final event in events) {
      stream.push(event);
    }
    stream.end();
    return stream;
  }

  Future<TaskSingleResult> spawn(String name, String task) =>
      executor.runSpawn(item: TaskItem(name: name, task: task), index: 0,
          context: '');

  /// Lets broadcast-stream deliveries (async microtasks) land.
  Future<void> drainMicrotasks() async {
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
  }

  void dispose() {
    unawaited(jobs.close());
  }
}
