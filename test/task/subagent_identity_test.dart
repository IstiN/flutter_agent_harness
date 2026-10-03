@TestOn('vm')
library;

/// gh-970 — inter-agent mail sender attribution for subagents:
///
/// - The child-only `reply`/`agent_message` tools must carry the identity
///   of the child whose run is EXECUTING the call. The executor's id stack
///   is shared by all concurrent children, so its head is "the child that
///   started last" — with several background children the sender label was
///   shifted onto a sibling (the reported swapped envelopes).
/// - The identity must also reach SHARED tools with self-mailbox semantics:
///   `schedule_message` inside a child run defaults to the CHILD's mailbox,
///   never main's, and the fired record delivers back into the child's
///   inbox (the queue must not re-address subagent mail to main).
/// - A retained child whose inbox received mail while it was finished gets
///   woken (resumed in its own session) by the manager's wake sweep — the
///   child-side analog of the host's idle inbox wake.

import 'dart:async';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
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

/// A scripted turn ending in one tool call.
List<AssistantMessageEvent> _toolTurn(String name, Map<String, dynamic> args) {
  final empty = _assistant();
  final call = ToolCall(id: 'call-1', name: name, arguments: args);
  final partial = _assistant(content: [call], stopReason: StopReason.toolUse);
  return [
    StartEvent(partial: empty),
    ToolCallStartEvent(contentIndex: 0, partial: empty),
    ToolCallEndEvent(contentIndex: 0, toolCall: call, partial: partial),
    DoneEvent(reason: StopReason.toolUse, message: partial),
  ];
}

/// Push-based stream whose events release once [gate] completes — a child
/// whose turn must not finish before a sibling's run reached a checkpoint.
AssistantMessageEventStream _gated(
  List<AssistantMessageEvent> events,
  Future<void> gate,
) {
  final stream = AssistantMessageEventStream();
  unawaited(
    gate.then((_) {
      for (final event in events) {
        stream.push(event);
      }
      stream.end();
    }),
  );
  return stream;
}

AssistantMessageEventStream _immediate(List<AssistantMessageEvent> events) {
  final stream = AssistantMessageEventStream();
  for (final event in events) {
    stream.push(event);
  }
  stream.end();
  return stream;
}

/// Scripted stream function: routes each provider call by a marker in the
/// last user message to a queue of turn factories (one per call).
final class _Router {
  final _routes = <String, List<AssistantMessageEventStream Function()>>{};
  final contexts = <Context>[];

  void route(
    String marker,
    List<AssistantMessageEventStream Function()> turns,
  ) {
    _routes[marker] = turns;
  }

  AssistantMessageEventStream call(
    Model model,
    Context context, {
    CancelToken? cancelToken,
  }) {
    contexts.add(context);
    final text = _lastUserText(context);
    for (final entry in _routes.entries) {
      if (text.contains(entry.key) && entry.value.isNotEmpty) {
        return entry.value.removeAt(0)();
      }
    }
    return _immediate(_textTurn('done'));
  }

  static String _lastUserText(Context context) {
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

/// Test-only fabric recording per-mailbox inboxes (mirrors the lifecycle
/// test's fake — no disk).
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

/// An executor over [manager] whose children run the [router] script.
TaskExecutor _executor(SubagentManager manager, _Router router) {
  return TaskExecutor(
    childTools: [_fakeTool('read', ApprovalTier.read)],
    streamFunction: () => router.call,
    model: () => _model,
    registry: TaskAgentRegistry(const []),
    semaphore: Semaphore(4),
    store: AgentOutputStore(),
    subagentManager: manager,
  );
}

/// Spawns two concurrent children: `alpha` gates its first turn on [betaRan]
/// (so beta's id is already live when alpha's tool call executes) and beta
/// stays alive until [alphaDone]. Returns (alphaResult future, beta future).
(Future<TaskSingleResult>, Future<TaskSingleResult>, void Function())
_pairWiring(
  TaskExecutor executor,
  _Router router, {
  required Completer<void> betaRan,
  required Completer<void> alphaDone,
  required List<AssistantMessageEvent> alphaTurn,
}) {
  router.route('alpha', [
    () => _gated(alphaTurn, betaRan.future),
    () => _immediate(_textTurn('done')),
  ]);
  router.route('beta', [
    () {
      betaRan.complete();
      return _gated(_textTurn('beta done'), alphaDone.future);
    },
  ]);
  final alpha = executor.runSpawn(
    item: const TaskItem(name: 'alpha', task: 'monitor alpha repo'),
    index: 0,
    context: 'ctx',
  );
  final beta = executor.runSpawn(
    item: const TaskItem(name: 'beta', task: 'monitor beta repo'),
    index: 1,
    context: 'ctx',
  );
  return (alpha, beta, alphaDone.complete);
}

void main() {
  group('subagent scope zone', () {
    test('publishes the id inside the scope, nothing outside', () {
      expect(activeSubagentId(), isNull);
      expect(
        runWithSubagentScope('child-7', () => activeSubagentId()),
        'child-7',
      );
      expect(activeSubagentId(), isNull);
    });

    test('nested scopes resolve to the innermost child', () {
      final inner = runWithSubagentScope('outer', () {
        return runWithSubagentScope('inner', () => activeSubagentId());
      });
      expect(inner, 'inner');
    });
  });

  group('gh-970 sender attribution under concurrent children', () {
    test(
      'agent_message from child X is delivered with sender X, not a sibling',
      () async {
        final fabric = _FakeFabric();
        final manager = SubagentManager(
          parentSessionId: 'sess',
          messaging: fabric,
        )..mailboxPrefix = 'sess';
        final router = _Router();
        final executor = _executor(manager, router);
        final betaRan = Completer<void>();
        final alphaDone = Completer<void>();
        final (alpha, beta, finishAlpha) = _pairWiring(
          executor,
          router,
          betaRan: betaRan,
          alphaDone: alphaDone,
          alphaTurn: _toolTurn('agent_message', {
            'to': 'main',
            'message': 'alpha monitor baseline pass 1',
          }),
        );
        final alphaResult = await alpha;
        final mail = await fabric.peek(manager.mailboxOf('main'));
        expect(mail, hasLength(1));
        expect(
          mail.single.fromId,
          manager.mailboxOf(alphaResult.id),
          reason:
              'the envelope must name the child that SENT it (gh-970: the '
              'label used to shift onto the last-started sibling)',
        );
        expect(mail.single.text, contains('alpha monitor baseline pass 1'));
        finishAlpha();
        await beta;
      },
    );

    test('reply is recorded on the calling child, not a sibling', () async {
      final fabric = _FakeFabric();
      final manager = SubagentManager(
        parentSessionId: 'sess',
        messaging: fabric,
      )..mailboxPrefix = 'sess';
      final router = _Router();
      final executor = _executor(manager, router);
      final betaRan = Completer<void>();
      final alphaDone = Completer<void>();
      final (alpha, beta, finishAlpha) = _pairWiring(
        executor,
        router,
        betaRan: betaRan,
        alphaDone: alphaDone,
        alphaTurn: _toolTurn('reply', {'message': 'alpha explicit answer'}),
      );
      final alphaResult = await alpha;
      expect(
        manager[alphaResult.id]!.lastReply,
        'alpha explicit answer',
        reason: 'gh-970: the reply used to land on the last-started sibling',
      );
      final betaId = manager.handles.length > 1
          ? manager.handles
                .map((h) => h.id)
                .firstWhere((id) => id != alphaResult.id)
          : null;
      if (betaId != null) {
        expect(manager[betaId]!.lastReply, isNull);
      }
      finishAlpha();
      await beta;
    });
  });

  group('gh-970 schedule_message inside a child run', () {
    test(
      'defaults to the child mailbox, and the fired record lands back there',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final root = '/sessions/--work--/messages';
        final repo = FileMessagingRepository(
          env: env,
          root: root,
          homeDir: null,
          decodeSessionCwd: decodeSessionCwd,
        );
        var now = DateTime.utc(2026, 9, 26, 10);
        final queue = ScheduledMessageQueue(
          env: env,
          repo: () => repo,
          root: () => root,
          selfMailbox: () => 'sess/main',
          ownerPrefix: () => 'sess',
          clock: () => now,
        );
        final fabric = _FakeFabric();
        final manager = SubagentManager(
          parentSessionId: 'sess',
          messaging: fabric,
        )..mailboxPrefix = 'sess';
        final router = _Router();
        // The same wiring hosts use: the shared schedule_message tool reads
        // the subagent scope at call time to resolve "your own mailbox".
        final executor = TaskExecutor(
          childTools: [
            _fakeTool('read', ApprovalTier.read),
            scheduleMessageTool(
              queue,
              senderMailbox: () {
                final id = activeSubagentId();
                return id == null ? null : manager.mailboxOf(id);
              },
            ),
          ],
          streamFunction: () => router.call,
          model: () => _model,
          registry: TaskAgentRegistry(const []),
          semaphore: Semaphore(4),
          store: AgentOutputStore(),
          subagentManager: manager,
        );
        final betaRan = Completer<void>();
        final alphaDone = Completer<void>();
        final (alpha, beta, finishAlpha) = _pairWiring(
          executor,
          router,
          betaRan: betaRan,
          alphaDone: alphaDone,
          alphaTurn: _toolTurn('schedule_message', {
            'text': 'next monitoring pass',
            'delay': '15m',
          }),
        );
        final alphaResult = await alpha;
        final childMailbox = manager.mailboxOf(alphaResult.id);

        // The record is self-addressed to the CHILD, not main.
        final pending = await queue.pendingRecords();
        expect(pending, hasLength(1));
        final fired = now.add(const Duration(minutes: 16));
        now = fired;
        expect(await queue.deliverDue(), 1);
        final mail = await repo.peek(childMailbox);
        expect(
          mail,
          hasLength(1),
          reason:
              'gh-970: the child self-reminder must fire into the child '
              'inbox — the queue must not re-address it to main',
        );
        expect(mail.single.text, contains('[scheduled] next monitoring pass'));
        expect(mail.single.fromId, childMailbox);
        expect(await repo.peek('sess/main'), isEmpty);
        expect(await repo.peek(manager.mailboxOf('main')), isEmpty);
        finishAlpha();
        await beta;
      },
    );
  });

  group('gh-970 wake sweep for children with pending mail', () {
    test('resumes completed and idle children holding inbox mail', () async {
      final fabric = _FakeFabric();
      final manager = SubagentManager(
        parentSessionId: 'sess',
        messaging: fabric,
      );
      Future<void> register(String id, SubagentStatus status) async {
        await manager.register(id: id, name: id, agentType: 'task', task: 't');
        await manager.update(id, status: status);
      }

      await register('done-child', SubagentStatus.completed);
      await register('idle-child', SubagentStatus.idle);
      await register('running-child', SubagentStatus.running);
      await register('failed-child', SubagentStatus.failed);
      await register('quiet-child', SubagentStatus.completed);
      Future<void> mail(String id) => fabric.send(
        AgentMessage(
          id: 'm-$id',
          fromId: 'somewhere',
          toId: manager.mailboxOf(id),
          text: 'wake up',
          sentAt: '2026-09-26T10:00:00Z',
        ),
      );
      await mail('done-child');
      await mail('idle-child');
      await mail('running-child');
      await mail('failed-child');
      final woken = <String>[];
      manager.wakeChild = (id) async {
        woken.add(id);
      };
      expect(await manager.wakeChildrenWithPendingMail(), 2);
      expect(woken, containsAll(['done-child', 'idle-child']));
      expect(woken, isNot(contains('running-child')));
      expect(woken, isNot(contains('failed-child')));
      expect(woken, isNot(contains('quiet-child')));
    });

    test('a wake in flight is not duplicated while it runs', () async {
      final fabric = _FakeFabric();
      final manager = SubagentManager(
        parentSessionId: 'sess',
        messaging: fabric,
      );
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 't',
      );
      await manager.update('a1', status: SubagentStatus.completed);
      await fabric.send(
        AgentMessage(
          id: 'm1',
          fromId: 'x',
          toId: manager.mailboxOf('a1'),
          text: 'hello',
          sentAt: '2026-09-26T10:00:00Z',
        ),
      );
      var started = 0;
      final release = Completer<void>();
      manager.wakeChild = (id) async {
        started++;
        await release.future;
      };
      expect(await manager.wakeChildrenWithPendingMail(), 1);
      // The wake is still in flight: the next tick must not stack another.
      expect(await manager.wakeChildrenWithPendingMail(), 0);
      expect(started, 1);
      release.complete();
      // Settled — but the inbox is still conceptually full in this fake
      // (the fake wake does not drain), so only the wake lifecycle is
      // pinned here, not redelivery.
    });

    test(
      'a throwing wake retires the child instead of spinning the sweep',
      () async {
        final fabric = _FakeFabric();
        final manager = SubagentManager(
          parentSessionId: 'sess',
          messaging: fabric,
        );
        await manager.register(
          id: 'a1',
          name: 'a1',
          agentType: 'task',
          task: 't',
        );
        await manager.update('a1', status: SubagentStatus.completed);
        await fabric.send(
          AgentMessage(
            id: 'm1',
            fromId: 'x',
            toId: manager.mailboxOf('a1'),
            text: 'hello',
            sentAt: '2026-09-26T10:00:00Z',
          ),
        );
        var attempts = 0;
        manager.wakeChild = (id) async {
          attempts++;
          throw StateError('unreadable session');
        };
        await manager.wakeChildrenWithPendingMail();
        await Future<void>.delayed(Duration.zero);
        expect(await manager.wakeChildrenWithPendingMail(), 0);
        expect(attempts, 1);
      },
    );

    test('a settled wake re-arms the child for its next reminder', () async {
      final fabric = _FakeFabric();
      final manager = SubagentManager(
        parentSessionId: 'sess',
        messaging: fabric,
      );
      await manager.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 't',
      );
      await manager.update('a1', status: SubagentStatus.completed);
      var attempts = 0;
      manager.wakeChild = (id) async {
        attempts++;
        // A real resume drains the inbox as its first action.
        await fabric.drain(manager.mailboxOf(id));
      };
      await fabric.send(
        AgentMessage(
          id: 'm1',
          fromId: 'x',
          toId: manager.mailboxOf('a1'),
          text: 'tick one',
          sentAt: '2026-09-26T10:00:00Z',
        ),
      );
      expect(await manager.wakeChildrenWithPendingMail(), 1);
      await Future<void>.delayed(Duration.zero);
      // Next scheduled reminder arrives; the child must be wakeable again.
      await fabric.send(
        AgentMessage(
          id: 'm2',
          fromId: 'x',
          toId: manager.mailboxOf('a1'),
          text: 'tick two',
          sentAt: '2026-09-26T10:15:00Z',
        ),
      );
      expect(await manager.wakeChildrenWithPendingMail(), 1);
      expect(attempts, 2);
    });

    test('no wake capability or no fabric → the sweep is a no-op', () async {
      final bare = SubagentManager(parentSessionId: 'sess');
      await bare.register(id: 'a1', name: 'a1', agentType: 'task', task: 't');
      await bare.update('a1', status: SubagentStatus.completed);
      expect(await bare.wakeChildrenWithPendingMail(), 0);
    });
  });
}
