@TestOn('vm')
library;

/// Issue #222 — subagent lifecycle: `task_send` steering on every host,
/// `task_resume` of failed children in the SAME session (never a cloned
/// `name-2`), cross-session child addressing, and the supersedes chain in
/// `agent_directory`.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/task/child_session_io.dart';
import 'package:test/test.dart';

import '../cli/agent_cli_test_support.dart' show toolTurn;

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
  Usage usage = Usage.zero,
}) {
  return AssistantMessage(
    content: content,
    api: 'test-api',
    provider: 'test-provider',
    model: 'test-model',
    usage: usage,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: DateTime.utc(2026),
  );
}

/// A scripted turn: stream start, text delta, done.
List<AssistantMessageEvent> _textTurn(String text) => _usageTurn(text);

/// A scripted turn carrying token usage on the final message.
List<AssistantMessageEvent> _usageTurn(String text, [Usage? usage]) {
  final empty = _assistant();
  final partial = _assistant(
    content: [TextContent(text: text)],
    usage:
        usage ??
        Usage(
          input: 0,
          output: 0,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 0,
          cost: const UsageCost(),
        ),
  );
  return [
    StartEvent(partial: empty),
    TextStartEvent(contentIndex: 0, partial: empty),
    TextDeltaEvent(contentIndex: 0, delta: text, partial: partial),
    DoneEvent(reason: StopReason.stop, message: partial),
  ];
}

/// A fixed token usage for the accounting tests.
Usage _usageOf(int input, int output) => Usage(
  input: input,
  output: output,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: input + output,
  cost: const UsageCost(),
);

/// A scripted provider-error turn (e.g. a 5h-quota 403).
List<AssistantMessageEvent> _errorTurn(String errorMessage) {
  return [
    StartEvent(partial: _assistant()),
    ErrorEvent(
      reason: StopReason.error,
      error: _assistant(
        stopReason: StopReason.error,
        errorMessage: errorMessage,
      ),
    ),
  ];
}

typedef _Rule = ({String match, List<List<AssistantMessageEvent>> turns});

/// Scripted fake [StreamFunction], mirroring task_tool_test.dart's.
final class _ScriptedStream {
  _ScriptedStream([List<_Rule> rules = const []]) : rules = List.of(rules);

  final List<_Rule> rules;
  final contexts = <Context>[];

  int get calls => contexts.length;

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
    contexts.add(
      Context(
        systemPrompt: context.systemPrompt,
        messages: List.of(context.messages),
        tools: context.tools,
      ),
    );
    final text = lastUserText(context);
    for (final rule in rules) {
      if (text.contains(rule.match) && rule.turns.isNotEmpty) {
        final events = rule.turns.removeAt(0);
        return _streamOf(events);
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

AgentTool _fakeTool(String name, ApprovalTier tier) {
  return AgentTool(
    name: name,
    description: '$name tool',
    tier: tier,
    execute: (arguments, cancelToken, onUpdate) async =>
        ToolExecutionResult.text('$name result'),
  );
}

/// Test-only messaging fabric recording per-mailbox inboxes.
final class _FakeFabric implements MessagingRepository {
  final _inboxes = <String, List<AgentMessage>>{};

  @override
  Future<void> send(AgentMessage message) async {
    _inboxes.putIfAbsent(message.toId, () => []).add(message);
  }

  @override
  Future<void> register(
    String agentId, {
    String? sessionName,
    List<AgentCapability> capabilities = const [],
  }) async {}

  @override
  Future<void> touch(String agentId, {bool busy = false}) async {}

  @override
  Future<List<AgentMessage>> peek(String agentId) async =>
      List.unmodifiable(_inboxes[agentId] ?? const []);

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    final messages = _inboxes.remove(agentId) ?? const [];
    return List.unmodifiable(messages);
  }

  @override
  Future<List<MailboxEntry>> directory() async => const [];
}

/// The executor + manager + JSONL session wiring, mirroring how
/// `AgentCli` wires `TaskToolConfig` (child sessions in a real repo).
final class _Wiring {
  _Wiring([List<_Rule> rules = const [], StreamFunction? streamFn]) {
    stream = _ScriptedStream(rules);
    _streamFn = streamFn;
    manager = SubagentManager(parentSessionId: 'parent-session')
      ..mailboxPrefix = 'parent-session';
    executor = TaskExecutor(
      childTools: [_fakeTool('read', ApprovalTier.read)],
      streamFunction: () => _streamFn ?? stream.call,
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
      childSessionOpener: jsonlChildSessionOpener(env),
    );
  }

  final env = MemoryExecutionEnv(cwd: '/work');
  late final repo = JsonlSessionRepo(fs: env, sessionsRoot: '/sessions');
  late final _ScriptedStream stream;
  StreamFunction? _streamFn;
  late final SubagentManager manager;
  late final TaskExecutor executor;

  /// A NEW executor over the same manager/repo — the process-restart
  /// shape: no in-memory child sessions or flush counters.
  TaskExecutor freshExecutor() => TaskExecutor(
    childTools: [_fakeTool('read', ApprovalTier.read)],
    streamFunction: () => stream.call,
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
    childSessionOpener: jsonlChildSessionOpener(env),
  );

  /// Spawns one child named [name] whose task contains [taskMarker].
  Future<TaskSingleResult> spawn(
    String name,
    String taskMarker, {
    String context = '',
  }) {
    return executor.runSpawn(
      item: TaskItem(name: name, task: taskMarker),
      index: 0,
      context: context,
    );
  }

  /// Waits out the fire-and-forget transcript flush (the real session is
  /// attached to the handle when it lands).
  Future<void> settle(String id) async {
    final placeholder = '${manager.parentSessionId}/$id';
    for (var i = 0; i < 1000; i++) {
      if (manager[id]!.sessionId != placeholder) return;
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    fail('child session for "$id" never attached');
  }

  /// The number of records in the child's JSONL session file.
  Future<int> recordCount(String id) async {
    final path = manager[id]!.sessionId;
    final storage = await JsonlSessionStorage.open(env, path);
    return (await storage.getEntries()).length;
  }

  /// The CLI-equivalent monitoring tools (AC1 wiring parity).
  List<AgentTool> monitoringTools() => subagentMonitoringTools(
    manager: manager,
    readMessages: jsonlChildMessageReader(env),
    resumeChild: executor.resumeChild,
  );

  AgentTool tool(String name) =>
      monitoringTools().firstWhere((t) => t.name == name);

  Future<String> execute(String toolName, Map<String, dynamic> args) async {
    final result = await tool(toolName).execute(args, null, null);
    return result.content.whereType<TextContent>().map((b) => b.text).join();
  }
}

void main() {
  group('UT-1: resume of a failed child continues the SAME session', () {
    test(
      'failed child resumes in-place: records grow monotonically, mailbox '
      'id and task_status id unchanged, no name-2 session (AC2+AC3)',
      () async {
        final w = _Wiring([
          (match: 'explode', turns: [_errorTurn('provider 403: quota')]),
        ]);
        final result = await w.spawn('manif_i18n', 'explode now');
        expect(result.status, TaskSpawnStatus.failed);
        await w.settle('manif_i18n');
        final handle = w.manager['manif_i18n']!;
        expect(handle.status, SubagentStatus.failed);
        final sessionPath = handle.sessionId;
        final mailboxBefore = w.manager.mailboxOf(handle.id);
        final before = await w.recordCount('manif_i18n');
        expect(before, greaterThan(0));

        // Quota rotated: the resume stream answers normally.
        await w.executor.resumeChild('manif_i18n', 'continue now');

        expect(handle.status, SubagentStatus.completed);
        expect(handle.id, 'manif_i18n');
        expect(handle.sessionId, sessionPath, reason: 'same JSONL session');
        expect(
          w.manager.mailboxOf(handle.id),
          mailboxBefore,
          reason: 'mailbox id unchanged across resume',
        );
        final after = await w.recordCount('manif_i18n');
        expect(after, greaterThan(before), reason: 'append-only growth');

        // The resumed run SAW the prior transcript (context continuity).
        final resumeContext = w.stream.contexts.last;
        final seeded = _ScriptedStream.lastUserText(
          Context(
            systemPrompt: resumeContext.systemPrompt,
            messages: resumeContext.messages.sublist(
              0,
              resumeContext.messages.length - 1,
            ),
          ),
        );
        expect(seeded, contains('explode now'));

        // REG guard (AC3): exactly ONE subagent session, no manif_i18n-2.
        final sessions = await w.repo.list(cwd: '/work');
        expect(sessions, hasLength(1));
        expect(w.manager.handles, hasLength(1));
      },
    );

    test('resume while running is rejected (E4 duplicate guard)', () async {
      final w = _Wiring();
      await w.manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await w.manager.update('a1', status: SubagentStatus.running);
      await expectLater(w.executor.resumeChild('a1', 'go'), throwsStateError);
    });

    test('resume with an externally deleted session file errors with a named, '
        'actionable message and never mints a new session (E3)', () async {
      final w = _Wiring([
        (match: 'explode', turns: [_errorTurn('provider 403: quota')]),
      ]);
      await w.spawn('manif_i18n', 'explode now');
      await w.settle('manif_i18n');
      final path = w.manager['manif_i18n']!.sessionId;
      await w.env.remove(path);
      // A process-restart-shaped executor: no in-memory child session.
      await expectLater(
        w.freshExecutor().resumeChild('manif_i18n', 'continue'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(contains('manif_i18n'), contains(path)),
          ),
        ),
      );
      expect(w.manager['manif_i18n']!.status, SubagentStatus.failed);
      expect(await w.repo.list(cwd: '/work'), isEmpty);
    });

    test('resume hitting a STILL quota-limited provider fails fast and the '
        'child returns to failed-resumable, never to a clone (E2)', () async {
      final w = _Wiring([
        (match: 'explode', turns: [_errorTurn('provider 403: quota')]),
        (match: 'continue', turns: [_errorTurn('provider 403: still quota')]),
      ]);
      await w.spawn('manif_i18n', 'explode now');
      await w.settle('manif_i18n');
      final before = await w.recordCount('manif_i18n');
      await expectLater(
        w.executor.resumeChild('manif_i18n', 'continue now'),
        throwsStateError,
      );
      final handle = w.manager['manif_i18n']!;
      expect(handle.status, SubagentStatus.failed);
      expect(handle.error, contains('still quota'));
      // A later resume (quota rotated) still works on the same session.
      await w.executor.resumeChild('manif_i18n', 'continue now');
      expect(handle.status, SubagentStatus.completed);
      expect(await w.recordCount('manif_i18n'), greaterThan(before));
      expect(await w.repo.list(cwd: '/work'), hasLength(1));
    });
  });

  group('UT-2: capability advertisement (AC1 second half)', () {
    test('without a resume callback the descriptors advertise the missing '
        'steering capability and errors name it', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('a1', status: SubagentStatus.completed);
      final tools = subagentMonitoringTools(manager: manager);
      final send = tools.firstWhere((t) => t.name == 'task_send');
      final resume = tools.firstWhere((t) => t.name == 'task_resume');
      expect(send.description, contains('steering: unavailable'));
      expect(resume.description, contains('capability: child-resume'));

      final sendResult = await send.execute(
        {'id': 'a1', 'message': 'hi'},
        null,
        null,
      );
      final sendText = sendResult.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(sendText, contains('capability: child-resume'));

      await manager.update('a1', status: SubagentStatus.failed);
      final resumeResult = await resume.execute(
        {'id': 'a1', 'message': 'hi'},
        null,
        null,
      );
      final resumeText = resumeResult.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(resumeText, contains('capability: child-resume'));
    });

    test('with a resume callback the descriptor does not cry unavailable', () {
      final manager = SubagentManager(parentSessionId: 'p');
      final tools = subagentMonitoringTools(
        manager: manager,
        resumeChild: (_, _) async {},
      );
      final send = tools.firstWhere((t) => t.name == 'task_send');
      expect(send.description, isNot(contains('steering: unavailable')));
    });
  });

  group('task_send semantics (AC1)', () {
    test('a RUNNING child is steered through its inbox — no host callback '
        'needed', () async {
      final fabric = _FakeFabric();
      final manager = SubagentManager(parentSessionId: 'p', messaging: fabric)
        ..mailboxPrefix = 'p';
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('a1', status: SubagentStatus.running);
      final tools = subagentMonitoringTools(manager: manager);
      final send = tools.firstWhere((t) => t.name == 'task_send');
      final result = await send.execute(
        {'id': 'a1', 'message': 'steer left'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('queued'));
      final inbox = await fabric.peek('p/a1');
      expect(inbox, hasLength(1));
      expect(inbox.single.text, 'steer left');
    });

    test('a completed child is resumed via the resume callback', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('a1', status: SubagentStatus.completed);
      String? gotId;
      String? gotMessage;
      final tools = subagentMonitoringTools(
        manager: manager,
        resumeChild: (id, message) async {
          gotId = id;
          gotMessage = message;
        },
      );
      final send = tools.firstWhere((t) => t.name == 'task_send');
      final result = await send.execute(
        {'id': 'a1', 'message': 'look deeper'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect((gotId, gotMessage), ('a1', 'look deeper'));
      expect(text, contains('child resumed'));
    });

    test('a failed child is pointed at task_resume', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('a1', status: SubagentStatus.failed);
      final tools = subagentMonitoringTools(
        manager: manager,
        resumeChild: (_, _) async {},
      );
      final send = tools.firstWhere((t) => t.name == 'task_send');
      final result = await send.execute(
        {'id': 'a1', 'message': 'retry'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('task_resume'));
    });
  });

  group('task_resume tool', () {
    test('resumes a failed child through the callback', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('a1', status: SubagentStatus.failed, error: '403');
      var resumed = false;
      final tools = subagentMonitoringTools(
        manager: manager,
        resumeChild: (id, message) async {
          resumed = true;
          await manager.update(id, status: SubagentStatus.completed);
        },
      );
      final resume = tools.firstWhere((t) => t.name == 'task_resume');
      final result = await resume.execute({'id': 'a1'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(resumed, isTrue);
      expect(text, contains('resumed "a1"'));
    });

    test('a failing resume keeps the child failed and resumable', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('a1', status: SubagentStatus.failed, error: '403');
      final tools = subagentMonitoringTools(
        manager: manager,
        resumeChild: (_, _) async => throw StateError('provider 403 again'),
      );
      final resume = tools.firstWhere((t) => t.name == 'task_resume');
      final result = await resume.execute({'id': 'a1'}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('provider 403 again'));
      expect(text, contains('resumable'));
    });

    test(
      'running children are rejected (E4), completed steer to task_send',
      () async {
        final manager = SubagentManager(parentSessionId: 'p');
        await manager.register(
          id: 'a1',
          name: 'a1',
          agentType: 'task',
          task: 'x',
        );
        await manager.update('a1', status: SubagentStatus.running);
        final tools = subagentMonitoringTools(
          manager: manager,
          resumeChild: (_, _) async {},
        );
        final resume = tools.firstWhere((t) => t.name == 'task_resume');
        final running = await resume.execute({'id': 'a1'}, null, null);
        expect(
          running.content.whereType<TextContent>().map((b) => b.text).join(),
          contains('already running'),
        );
        await manager.update('a1', status: SubagentStatus.completed);
        final completed = await resume.execute({'id': 'a1'}, null, null);
        expect(
          completed.content.whereType<TextContent>().map((b) => b.text).join(),
          contains('task_send'),
        );
      },
    );
  });

  group('IT-1: full loop over the CLI-equivalent wiring (AC2/AC3)', () {
    test('403 mid-run → task_resume → completion; same session, same id, '
        'monotonic records, observable transcript', () async {
      final w = _Wiring([
        (match: 'explode', turns: [_errorTurn('provider 403: quota')]),
      ]);
      await w.spawn('manif_i18n', 'explode now');
      await w.settle('manif_i18n');
      expect(
        await w.execute('task_status', {'id': 'manif_i18n'}),
        contains('status: failed'),
      );
      final before = await w.recordCount('manif_i18n');

      final resumeText = await w.execute('task_resume', {
        'id': 'manif_i18n',
        'message': 'continue now',
      });
      expect(resumeText, contains('resumed "manif_i18n"'));

      expect(
        await w.execute('task_status', {'id': 'manif_i18n'}),
        contains('status: completed'),
      );
      expect(await w.recordCount('manif_i18n'), greaterThan(before));
      expect(await w.repo.list(cwd: '/work'), hasLength(1));

      // task_observe reads the SAME session's transcript.
      final observed = await w.execute('task_observe', {'id': 'manif_i18n'});
      expect(observed, contains('explode now'));

      // task_send to the now-completed child resumes it in place again.
      final mid = await w.recordCount('manif_i18n');
      final sendText = await w.execute('task_send', {
        'id': 'manif_i18n',
        'message': 'one more pass',
      });
      expect(sendText, contains('child resumed'));
      expect(await w.recordCount('manif_i18n'), greaterThan(mid));
      expect(await w.repo.list(cwd: '/work'), hasLength(1));
    });
  });

  group('AC4: cross-session child addressing', () {
    Future<(SubagentManager, _FakeFabric, AgentTool)> setup() async {
      final fabric = _FakeFabric();
      final manager = SubagentManager(parentSessionId: 'p', messaging: fabric)
        ..mailboxPrefix = 'sess1';
      await manager.register(
        id: 'a1',
        name: 'manif_i18n',
        agentType: 'task',
        task: 'x',
      );
      final tools = subagentMonitoringTools(manager: manager);
      return (
        manager,
        fabric,
        tools.firstWhere((t) => t.name == 'agent_message'),
      );
    }

    test('<parentSessionId>/<agentName> lands in the child inbox', () async {
      final (manager, fabric, agentMessage) = await setup();
      final result = await agentMessage.execute(
        {'to': 'sess1/manif_i18n', 'message': 'hello child'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, isNot(contains('error')));
      final inbox = await fabric.peek(manager.mailboxOf('a1'));
      expect(inbox, hasLength(1));
      expect(inbox.single.text, 'hello child');
    });

    test('a bare unique child name resolves session-locally', () async {
      final (manager, fabric, agentMessage) = await setup();
      final result = await agentMessage.execute(
        {'to': 'manif_i18n', 'message': 'hi'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, isNot(contains('error')));
      expect(await fabric.peek(manager.mailboxOf('a1')), hasLength(1));
    });

    test('a bare ambiguous name errors with candidates', () async {
      final (manager, fabric, agentMessage) = await setup();
      await manager.register(
        id: 'a2',
        name: 'manif_i18n',
        agentType: 'task',
        task: 'y',
      );
      final result = await agentMessage.execute(
        {'to': 'manif_i18n', 'message': 'hi'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(text, contains('ambiguous'));
      expect(text, contains('a1'));
      expect(text, contains('a2'));
      expect(await fabric.peek(manager.mailboxOf('a1')), isEmpty);
      expect(await fabric.peek(manager.mailboxOf('a2')), isEmpty);
    });
  });

  group('AC5: supersedes chain', () {
    test('a respawn links supersedes and the registry persists it', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'manif_i18n',
        name: 'manif_i18n',
        agentType: 'task',
        task: 'x',
      );
      // The link exists to collapse RESPAWNS of dead children — the first
      // generation must have settled before a fresh spawn takes its name.
      await manager.update('manif_i18n', status: SubagentStatus.failed);
      await manager.register(
        id: 'manif_i18n2',
        name: 'manif_i18n',
        agentType: 'task',
        task: 'x',
      );
      expect(manager['manif_i18n2']!.supersedes, 'manif_i18n');
      final roundTripped = SubagentHandle.fromJson(
        manager['manif_i18n2']!.toJson(),
      );
      expect(roundTripped.supersedes, 'manif_i18n');
    });

    test('LIVE same-named parallel children never link supersedes (the link '
        'means "fold this dead generation into its successor")', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      // Two same-named children alive at once — two parallel batches that
      // happen to share a display name. Neither supersedes the other.
      await manager.register(
        id: 'scout',
        name: 'scout',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('scout', status: SubagentStatus.running);
      await manager.register(
        id: 'scout-2',
        name: 'scout',
        agentType: 'task',
        task: 'y',
      );
      await manager.update('scout-2', status: SubagentStatus.running);
      expect(manager['scout-2']!.supersedes, isNull);
      // A later respawn AFTER the parallel run settled still links the
      // then-dead generation.
      await manager.update('scout', status: SubagentStatus.completed);
      await manager.update('scout-2', status: SubagentStatus.failed);
      await manager.register(
        id: 'scout-3',
        name: 'scout',
        agentType: 'task',
        task: 'z',
      );
      expect(manager['scout-3']!.supersedes, 'scout-2');
    });

    test('agent_directory renders the chain as ONE logical entry', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'manif_i18n',
        name: 'manif_i18n',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('manif_i18n', status: SubagentStatus.failed);
      await manager.register(
        id: 'manif_i18n2',
        name: 'manif_i18n',
        agentType: 'task',
        task: 'x',
      );
      await manager.update('manif_i18n2', status: SubagentStatus.running);
      final tools = subagentMonitoringTools(manager: manager);
      final directory = tools.firstWhere((t) => t.name == 'agent_directory');
      final result = await directory.execute(const {}, null, null);
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      final chainLines = text
          .split('\n')
          .where((line) => line.contains('manif_i18n'))
          .toList();
      expect(chainLines, hasLength(1), reason: text);
      expect(chainLines.single, contains('running'));
      expect(chainLines.single, contains('supersedes manif_i18n'));
    });
  });

  group('a2a children: no silent mail loss (steering rejection)', () {
    // A remote `a2a:<name>` child has NO local agent loop: nothing drains
    // its fabric inbox (the remote prompt is assembled once, at send time).
    // task_send used to answer "queued … delivered" for exactly those
    // children — mail that could never be delivered.
    test(
      'task_send to a RUNNING a2a child is rejected and nothing is queued',
      () async {
        final fabric = _FakeFabric();
        final manager = SubagentManager(parentSessionId: 'p', messaging: fabric)
          ..mailboxPrefix = 'p';
        await manager.register(
          id: 'remote_1',
          name: 'remote',
          agentType: 'a2a:peer',
          task: 'x',
        );
        await manager.update('remote_1', status: SubagentStatus.running);
        final tools = subagentMonitoringTools(
          manager: manager,
          resumeChild: (_, _) async {},
        );
        final send = tools.firstWhere((t) => t.name == 'task_send');
        final result = await send.execute(
          {'id': 'remote_1', 'message': 'steer left'},
          null,
          null,
        );
        final text = result.content
            .whereType<TextContent>()
            .map((b) => b.text)
            .join();
        expect(text, isNot(contains('queued')));
        expect(text, isNot(contains('delivered')));
        // The rejection names the actual delivery channel: a fresh task
        // item against the remote agent type.
        expect(text, contains('a2a:peer'));
        expect(text, contains('task'));
        // No mail silently parked in an inbox nobody drains.
        expect(await fabric.peek(manager.mailboxOf('remote_1')), isEmpty);
      },
    );

    test('task_send to an IDLE a2a child is rejected up front — no circular '
        'pointer back at task_send via the resume path', () async {
      final manager = SubagentManager(parentSessionId: 'p');
      await manager.register(
        id: 'remote_1',
        name: 'remote',
        agentType: 'a2a:peer',
        task: 'x',
      );
      await manager.update('remote_1', status: SubagentStatus.idle);
      var resumeCalled = false;
      final tools = subagentMonitoringTools(
        manager: manager,
        resumeChild: (_, _) async => resumeCalled = true,
      );
      final send = tools.firstWhere((t) => t.name == 'task_send');
      final result = await send.execute(
        {'id': 'remote_1', 'message': 'the answer is 42'},
        null,
        null,
      );
      final text = result.content
          .whereType<TextContent>()
          .map((b) => b.text)
          .join();
      expect(resumeCalled, isFalse, reason: text);
      expect(text, contains('a2a:peer'));
      expect(
        text,
        isNot(contains('task_send')),
        reason: 'must not point back at itself',
      );
      expect(text, contains('task'));
    });

    test('task_resume on a FAILED a2a child names the real channel instead of '
        '"steer it with task_send"', () async {
      final w = _Wiring();
      await w.manager.register(
        id: 'remote_1',
        name: 'remote',
        agentType: 'a2a:peer',
        task: 'x',
      );
      await w.manager.update(
        'remote_1',
        status: SubagentStatus.failed,
        error: 'remote task failed',
      );
      await expectLater(
        w.executor.resumeChild('remote_1', 'retry'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('a2a'),
              isNot(contains('task_send')),
              contains('task'),
            ),
          ),
        ),
      );
      // The tool layer rejects a2a handles before the callback is even
      // consulted (same message, no "stays failed and resumable" tease).
      final text = await w.execute('task_resume', {'id': 'remote_1'});
      expect(text, contains('a2a:peer'));
      expect(text, isNot(contains('resumable')));
    });
  });

  group('resume accounting', () {
    test('steering a completed child adds only the RESUME run\'s usage — no '
        'double-counting of the prior transcript', () async {
      final w = _Wiring([
        (
          match: 'count usage',
          turns: [_usageTurn('first pass', _usageOf(100, 20))],
        ),
        (
          match: 'follow up',
          turns: [_usageTurn('second pass', _usageOf(50, 10))],
        ),
      ]);
      await w.spawn('scout', 'count usage now');
      await w.settle('scout');
      final handle = w.manager['scout']!;
      expect(handle.status, SubagentStatus.completed);
      expect(handle.tokens, 120, reason: 'first run: 100 in + 20 out');
      expect(handle.requests, 1);

      final text = await w.execute('task_send', {
        'id': 'scout',
        'message': 'follow up please',
      });
      expect(text, contains('child resumed'));
      expect(handle.status, SubagentStatus.completed);
      // 120 (first run, already recorded) + 60 (resume run only).
      expect(handle.tokens, 180, reason: 'resume adds 50 in + 10 out');
      expect(handle.requests, 2);
    });

    test('resume keeps the original batch # CONTEXT in the child\'s system '
        'prompt (it is not recoverable from the transcript, so the handle '
        'persists it)', () async {
      final w = _Wiring([
        (match: 'explode', turns: [_errorTurn('provider 403: quota')]),
      ]);
      await w.executor.runSpawn(
        item: TaskItem(name: 'scout', task: 'explode now'),
        index: 0,
        context: 'KEY-CTX-42 shared constraints for the batch',
      );
      await w.settle('scout');
      expect(w.manager['scout']!.status, SubagentStatus.failed);
      // The ORIGINAL run rendered the batch context into its system
      // prompt; the resume must not silently drop it.
      expect(w.stream.contexts.first.systemPrompt, contains('KEY-CTX-42'));

      await w.executor.resumeChild('scout', 'continue now');

      final resumePrompt = w.stream.contexts.last.systemPrompt;
      expect(resumePrompt, contains('# CONTEXT'));
      expect(resumePrompt, contains('KEY-CTX-42'));
      // The context survives registry persistence (a restart-shape
      // resume through a fresh executor re-reads the handle).
      final roundTripped = SubagentHandle.fromJson(
        w.manager['scout']!.toJson(),
      );
      expect(roundTripped.context, contains('KEY-CTX-42'));
    });

    test('cancelling an IN-FLIGHT resume aborts it — no tombstone over the '
        'live child, and it stays resumable (issue #332)', () async {
      // A resume runs inline (no TaskJob): the shared cancel helper must
      // abort it through the executor's in-flight source instead of
      // tombstoning the registry row over the LIVE run.
      final gates = <int, Completer<void>>{};
      var call = 0;
      AssistantMessageEventStream gated(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final mine = ++call;
        final stream = AssistantMessageEventStream();
        if (mine == 1) {
          // The original run fails (resumable).
          for (final event in _errorTurn('provider 403: quota')) {
            stream.push(event);
          }
          stream.end();
          return stream;
        }
        if (mine == 2) {
          // The resume hangs until cancelled, then reports aborted.
          stream.push(StartEvent(partial: _assistant()));
          cancelToken?.onCancel.then((_) {
            stream.push(
              ErrorEvent(
                reason: StopReason.aborted,
                error: _assistant(
                  stopReason: StopReason.aborted,
                  errorMessage: 'Operation aborted',
                ),
              ),
            );
            stream.end();
          });
          gates[2] = Completer<void>()..complete(); // signal: resumed
          return stream;
        }
        // A later re-resume answers normally.
        for (final event in _usageTurn('recovered', _usageOf(10, 2))) {
          stream.push(event);
        }
        stream.end();
        return stream;
      }

      final w = _Wiring(const [], gated);
      final result = await w.spawn('scout', 'explode now');
      expect(result.status, TaskSpawnStatus.failed);
      await w.settle('scout');
      expect(w.manager['scout']!.status, SubagentStatus.failed);

      final resumeFuture = w.executor.resumeChild('scout', 'try again');
      while (!(gates[2]?.isCompleted ?? false)) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(w.executor.isInFlight('scout'), isTrue);

      final text = await cancelSubagentWithoutJob(
        id: 'scout',
        manager: w.manager,
        executor: w.executor,
        source: '/tasks cancel',
      );
      expect(text, contains('cancel requested'));
      expect(text, isNot(contains('tombstoned')));

      await expectLater(resumeFuture, throwsStateError);
      final handle = w.manager['scout']!;
      // Settled failed-RESUMABLE by the run path — never the tombstone's
      // 'no live runner' aborted, and a follow-up resume still works.
      expect(handle.status, SubagentStatus.failed);
      expect(handle.error, contains('resume cancelled'));
      expect(handle.error, isNot(contains('no live runner')));

      await w.executor.resumeChild('scout', 'once more');
      expect(w.manager['scout']!.status, SubagentStatus.completed);
    });

    test('usage is billed at TURN BOUNDARIES — a mid-run snapshot carries it, '
        'totals unchanged at completion (issue #332)', () async {
      // Two provider requests in ONE run: turn 1 carries a tool call
      // (the loop continues), turn 2 is the final text. The registry
      // snapshot written after turn 1 must already carry the turn's
      // usage — the persisted state rehydrate distinguishes now.
      final snapshots = <List<Map<String, dynamic>>>[];
      final manager = SubagentManager(
        parentSessionId: 'p',
        sink: (registry) async => snapshots.add(registry),
      );
      var call = 0;
      AssistantMessageEventStream twoTurn(
        Model model,
        Context context, {
        CancelToken? cancelToken,
      }) {
        final stream = AssistantMessageEventStream();
        if (++call == 1) {
          for (final event in toolTurn([
            const ToolCall(id: 'c1', name: 'read', arguments: {}),
          ])) {
            stream.push(event);
          }
        } else {
          for (final event in _usageTurn('all done', _usageOf(50, 5))) {
            stream.push(event);
          }
        }
        stream.end();
        return stream;
      }

      final executor = TaskExecutor(
        childTools: [_fakeTool('read', ApprovalTier.read)],
        streamFunction: () => twoTurn,
        model: () => _model,
        registry: TaskAgentRegistry(const []),
        semaphore: Semaphore(4),
        store: AgentOutputStore(),
        subagentManager: manager,
      );
      final result = await executor.runSpawn(
        item: const TaskItem(name: 'scout', task: 'survey'),
        index: 0,
        context: '',
      );
      expect(result.status, TaskSpawnStatus.completed);
      // Pump the fire-and-forget snapshot writes.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      // The MID-RUN snapshot (running, after turn 1, before completion)
      // carries the first request — this state is persisted for real.
      final midRun = snapshots.where(
        (snapshot) => snapshot.any(
          (row) =>
              row['id'] == 'scout' &&
              row['status'] == 'running' &&
              (row['requests'] as num? ?? 0) > 0,
        ),
      );
      expect(midRun, isNotEmpty, reason: 'turn 1 billed while running');

      // And no double-billing at completion: totals equal the run.
      final handle = manager['scout']!;
      expect(handle.status, SubagentStatus.completed);
      expect(handle.requests, 2);
      expect(handle.tokens, 55, reason: 'only the final turn carries tokens');
      expect(result.tokens, 55);
    });
  });
}
