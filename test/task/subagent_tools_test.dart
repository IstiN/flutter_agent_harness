@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/env/memory_execution_env.dart';
import 'package:flutter_agent_harness/src/messaging/agent_message.dart';
import 'package:flutter_agent_harness/src/messaging/file_messaging_repository.dart';
import 'package:flutter_agent_harness/src/messaging/messaging_repository.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/session/session_repo.dart'
    show decodeSessionCwd;
import 'package:flutter_agent_harness/src/task/subagent_tools.dart';
import 'package:test/test.dart';

/// Test-only messaging fabric that reports specific [MailboxEntry] values.
final class _FakeMessagingRepository implements MessagingRepository {
  _FakeMessagingRepository({required this.entries});

  final List<MailboxEntry> entries;
  final _inboxes = <String, List<AgentMessage>>{};

  @override
  Future<void> send(AgentMessage message) async {
    _inboxes.putIfAbsent(message.toId, () => []).add(message);
  }

  @override
  Future<void> register(String agentId, {String? sessionName}) async {}

  @override
  Future<void> touch(String agentId) async {}

  @override
  Future<List<AgentMessage>> peek(String agentId) async =>
      List.unmodifiable(_inboxes[agentId] ?? const []);

  @override
  Future<List<AgentMessage>> drain(String agentId) async {
    final messages = _inboxes.remove(agentId) ?? const [];
    return List.unmodifiable(messages);
  }

  @override
  Future<List<MailboxEntry>> directory() async => List.unmodifiable(entries);
}

void main() {
  late SubagentManager mgr;

  setUp(() async {
    mgr = SubagentManager(parentSessionId: 'parent');
    await mgr.register(
      id: 'a1',
      name: 'task-1',
      agentType: 'explore',
      task: 'find tests',
    );
    await mgr.update(
      'a1',
      status: SubagentStatus.completed,
      tokens: 500,
      modelId: 'gpt-4o-mini',
    );
  });

  group('subagentMonitoringTools', () {
    test('returns empty list when manager is null', () {
      expect(subagentMonitoringTools(manager: null), isEmpty);
    });

    test('returns 6 tools', () {
      final tools = subagentMonitoringTools(manager: mgr);
      expect(tools.length, 6);
      expect(
        tools.map((t) => t.name),
        containsAll([
          'task_status',
          'task_observe',
          'task_send',
          'reply',
          'agent_message',
          'agent_directory',
        ]),
      );
    });

    test('agent_directory lists fabric mailboxes and marks self', () async {
      final env = MemoryExecutionEnv(cwd: '/work');
      final repo = FileMessagingRepository(
        env: env,
        root: '/sessions/--work--/messages',
        decodeSessionCwd: decodeSessionCwd,
      );
      final fabricMgr = SubagentManager(parentSessionId: 'p', messaging: repo)
        ..mailboxPrefix = 'sess1';
      await fabricMgr.register(
        id: 'a1',
        name: 'a1',
        agentType: 'task',
        task: 'work',
      );
      await fabricMgr.enqueueMessage(
        'a1',
        SubagentMessage(
          fromId: 'main',
          text: 'note',
          sentAt: '2026-01-01T00:00:00Z',
        ),
      );
      // Another instance's mailbox exists in the same fabric.
      await repo.send(
        AgentMessage(
          id: 'x1',
          fromId: 'sess2/main',
          toId: 'sess1/main',
          text: 'cross-instance',
          sentAt: '2026-01-01T00:00:00Z',
        ),
      );

      final tools = subagentMonitoringTools(manager: fabricMgr);
      final directory = tools.firstWhere((t) => t.name == 'agent_directory');
      final result = await directory.execute(const {}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('you are "sess1/main"'));
      expect(text, contains('sess1/main — 1 pending'));
      expect(text, contains('← you'));
      expect(text, contains('sess1/a1 — 1 pending'));
    });

    test(
      'agent_directory hides stale zero-mail mailboxes unless all',
      () async {
        final env = MemoryExecutionEnv(cwd: '/work');
        final repo = FileMessagingRepository(
          env: env,
          root: '/sessions/--work--/messages',
          decodeSessionCwd: decodeSessionCwd,
        );
        final fabricMgr = SubagentManager(parentSessionId: 'p', messaging: repo)
          ..mailboxPrefix = 'sess1';
        final hourAgo = DateTime.now()
            .toUtc()
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch;
        // Stale and empty — hidden by default. The mail is drained (read/),
        // then everything is backdated past the live window.
        await repo.send(
          AgentMessage(
            id: 'old1',
            fromId: 'gone',
            toId: 'old/main',
            text: 'old',
            sentAt: '2026-01-01T00:00:00Z',
          ),
        );
        await repo.drain('old/main');
        env.setMtime(
          '/sessions/--work--/messages/old_main/read/old1.json',
          hourAgo,
        );
        // Stale but holding unread mail — never hidden, whatever its age.
        await repo.send(
          AgentMessage(
            id: 'old2',
            fromId: 'gone',
            toId: 'stale-mailbox',
            text: 'pending',
            sentAt: '2026-01-01T00:00:00Z',
          ),
        );
        env.setMtime(
          '/sessions/--work--/messages/stale-mailbox/inbox/old2.json',
          hourAgo,
        );

        final tools = subagentMonitoringTools(manager: fabricMgr);
        final directory = tools.firstWhere((t) => t.name == 'agent_directory');
        final result = await directory.execute(const {}, null, null);
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('stale-ma… — 1 pending'));
        expect(text, isNot(contains('old/main')));
        expect(text, contains('1 stale mailbox(es) hidden'));

        final everything = await directory.execute(
          const {'all': true},
          null,
          null,
        );
        final allText = (everything.content.first as dynamic).text as String;
        expect(allText, contains('old/main'));
        expect(allText, contains('stale-mailbox — 1 pending'));
      },
    );

    test('agent_directory renders cwd tag for a remote mailbox', () async {
      final fabricMgr = SubagentManager(
        parentSessionId: 'p',
        messaging: _FakeMessagingRepository(
          entries: const [
            MailboxEntry(id: 'sess1/main'),
            MailboxEntry(id: 'sess2/main', cwd: '/work/project-b'),
          ],
        ),
      )..mailboxPrefix = 'sess1';
      await fabricMgr.enqueueMessage(
        'main',
        SubagentMessage(
          fromId: 'a1',
          text: 'self note',
          sentAt: '2026-01-01T00:00:00Z',
        ),
      );

      final tools = subagentMonitoringTools(manager: fabricMgr);
      final directory = tools.firstWhere((t) => t.name == 'agent_directory');
      final result = await directory.execute(const {}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('sess2/main — 0 pending  [/work/project-b]'));
      expect(text, contains('sess1/main — 1 pending'));
      expect(text, contains('← you'));
      // Self entry has no cwd tag when cwd is null.
      expect(text, isNot(contains('sess1/main — 1 pending  [')));
    });

    test(
      'agent_directory without a fabric still lists registered children',
      () async {
        final tools = subagentMonitoringTools(manager: mgr);
        final directory = tools.firstWhere((t) => t.name == 'agent_directory');
        final result = await directory.execute(const {}, null, null);
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('task-1 — subagent (completed)'));
        expect(text, contains('subagent'));
      },
    );

    test('task_status without id lists all subagents', () async {
      final tools = subagentMonitoringTools(manager: mgr);
      final statusTool = tools.firstWhere((t) => t.name == 'task_status');
      final result = await statusTool.execute({}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('a1'));
      expect(text, contains('explore'));
      expect(text, contains('completed'));
    });

    test('task_status with id shows detail', () async {
      final tools = subagentMonitoringTools(manager: mgr);
      final statusTool = tools.firstWhere((t) => t.name == 'task_status');
      final result = await statusTool.execute({'id': 'a1'}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('id: a1'));
      expect(text, contains('type: explore'));
      expect(text, contains('tokens: 500'));
    });

    test('task_status with unknown id gives clean error', () async {
      final tools = subagentMonitoringTools(manager: mgr);
      final statusTool = tools.firstWhere((t) => t.name == 'task_status');
      final result = await statusTool.execute({'id': 'nope'}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('no subagent with id "nope"'));
    });

    test('task_observe reads messages via callback', () async {
      final tools = subagentMonitoringTools(
        manager: mgr,
        readMessages: (sessionId, {tail = 10}) async => [
          ('user', 'find tests'),
          ('assistant', 'found 3 tests'),
        ],
      );
      final observeTool = tools.firstWhere((t) => t.name == 'task_observe');
      final result = await observeTool.execute({'id': 'a1'}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('user: find tests'));
      expect(text, contains('assistant: found 3 tests'));
    });

    test('task_observe without callback gives status hint', () async {
      final tools = subagentMonitoringTools(manager: mgr);
      final observeTool = tools.firstWhere((t) => t.name == 'task_observe');
      final result = await observeTool.execute({'id': 'a1'}, null, null);
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('session reading not available'));
    });

    test('task_send sends to completed child and resumes it', () async {
      var sentMessage = '';
      final tools = subagentMonitoringTools(
        manager: mgr,
        sendToChild: (sessionId, message) async {
          sentMessage = message;
        },
      );
      final sendTool = tools.firstWhere((t) => t.name == 'task_send');
      final result = await sendTool.execute(
        {'id': 'a1', 'message': 'look deeper'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('sent message to "a1"'));
      expect(sentMessage, 'look deeper');
      expect(mgr['a1']!.status, SubagentStatus.running);
    });

    test('task_send rejects failed subagent', () async {
      await mgr.register(
        id: 'failed-1',
        name: 'f',
        agentType: 'task',
        task: '',
      );
      await mgr.update('failed-1', status: SubagentStatus.failed, error: 'x');
      final tools = subagentMonitoringTools(
        manager: mgr,
        sendToChild: (_, _) async {},
      );
      final sendTool = tools.firstWhere((t) => t.name == 'task_send');
      final result = await sendTool.execute(
        {'id': 'failed-1', 'message': 'retry'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('cannot send to failed'));
    });

    test('task_send empty message is error', () async {
      final tools = subagentMonitoringTools(
        manager: mgr,
        sendToChild: (_, _) async {},
      );
      final sendTool = tools.firstWhere((t) => t.name == 'task_send');
      final result = await sendTool.execute(
        {'id': 'a1', 'message': ''},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('error: message is required'));
    });

    test('reply without a current subagent scope is refused', () async {
      final tools = subagentMonitoringTools(manager: mgr);
      final replyTool = tools.firstWhere((t) => t.name == 'reply');
      final result = await replyTool.execute(
        {'message': 'the answer'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('only available inside a subagent run'));
    });

    test('reply records the explicit reply on the handle', () async {
      final tools = subagentMonitoringTools(
        manager: mgr,
        currentSubagentId: () => 'a1',
      );
      final replyTool = tools.firstWhere((t) => t.name == 'reply');
      final result = await replyTool.execute(
        {'message': 'the explicit answer'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('delivered'));
      expect(mgr['a1']!.lastReply, 'the explicit answer');
    });

    test('agent_message queues a sibling message and drains it', () async {
      await mgr.register(
        id: 'b2',
        name: 'task-2',
        agentType: 'task',
        task: 'other work',
      );
      final tools = subagentMonitoringTools(
        manager: mgr,
        currentSubagentId: () => 'a1',
      );
      final messageTool = tools.firstWhere((t) => t.name == 'agent_message');
      final result = await messageTool.execute(
        {'to': 'b2', 'message': 'hand over the file list'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('queued for "b2"'));
      final drained = await mgr.drainMessages('b2');
      expect(drained, hasLength(1));
      expect(drained.single.fromId, 'a1');
      expect(drained.single.text, 'hand over the file list');
      expect(await mgr.drainMessages('b2'), isEmpty);
    });

    test('agent_message to self is refused', () async {
      final tools = subagentMonitoringTools(
        manager: mgr,
        currentSubagentId: () => 'a1',
      );
      final messageTool = tools.firstWhere((t) => t.name == 'agent_message');
      final result = await messageTool.execute(
        {'to': 'a1', 'message': 'note to self'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('cannot message yourself'));
    });

    test('agent_message to an unknown sibling lists available ids', () async {
      final tools = subagentMonitoringTools(
        manager: mgr,
        currentSubagentId: () => 'a1',
      );
      final messageTool = tools.firstWhere((t) => t.name == 'agent_message');
      final result = await messageTool.execute(
        {'to': 'ghost', 'message': 'hello?'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('unknown subagent'));
    });

    test('pending queue is bounded by maxPendingMessages', () async {
      final small = SubagentManager(
        parentSessionId: 'p',
        maxPendingMessages: 2,
      );
      await small.register(
        id: 'c3',
        name: 'task-3',
        agentType: 'task',
        task: 'work',
      );
      final msg = SubagentMessage(
        fromId: 'a1',
        text: 'hi',
        sentAt: '2026-01-01T00:00:00Z',
      );
      await small.enqueueMessage('c3', msg);
      await small.enqueueMessage('c3', msg);
      expect(() => small.enqueueMessage('c3', msg), throwsStateError);
    });

    test('oversized message bodies are capped', () async {
      final small = SubagentManager(parentSessionId: 'p', maxReplyChars: 10);
      await small.register(
        id: 'd4',
        name: 'task-4',
        agentType: 'task',
        task: 'work',
      );
      await small.enqueueMessage(
        'd4',
        SubagentMessage(
          fromId: 'a1',
          text: 'a very long message body indeed',
          sentAt: '2026-01-01T00:00:00Z',
        ),
      );
      final queued = small['d4']!.pendingMessages.single;
      expect(queued.text.length, lessThanOrEqualTo(22));
      expect(queued.text, contains('truncated'));
    });

    test('handle JSON round-trips lastReply and pendingMessages', () async {
      await mgr.recordReply('a1', 'explicit reply');
      await mgr.enqueueMessage(
        'a1',
        SubagentMessage(
          fromId: 'b2',
          text: 'queued',
          sentAt: '2026-01-01T00:00:00Z',
          hops: 2,
        ),
      );
      final restored = SubagentHandle.fromJson(mgr['a1']!.toJson());
      expect(restored.lastReply, 'explicit reply');
      expect(restored.pendingMessages, hasLength(1));
      expect(restored.pendingMessages.single.fromId, 'b2');
      expect(restored.pendingMessages.single.hops, 2);
    });
  });

  group('name-based addressing', () {
    _FakeMessagingRepository fakeFabric(List<MailboxEntry> entries) =>
        _FakeMessagingRepository(entries: entries);

    MailboxEntry box(String id, {String? name, String? cwd}) =>
        MailboxEntry(id: id, name: name, cwd: cwd, lastActivity: null);

    Future<SubagentManager> fabricManager(_FakeMessagingRepository repo) async {
      final m = SubagentManager(parentSessionId: 'p', messaging: repo)
        ..mailboxPrefix = 'sess1';
      await m.register(id: 'a1', name: 'a1', agentType: 'task', task: 'work');
      return m;
    }

    test(
      'agent_directory renders the session name with the mailbox id',
      () async {
        final repo = fakeFabric([
          box('sess9/main', name: 'goal_builder', cwd: '/work/x'),
        ]);
        final m = await fabricManager(repo);
        final directory = subagentMonitoringTools(
          manager: m,
        ).firstWhere((t) => t.name == 'agent_directory');
        final result = await directory.execute({}, null, null);
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('goal_builder (sess9/main)'));
        expect(text, contains('/work/x'));
      },
    );

    test(
      'agent_message resolves a plain session name to its mailbox',
      () async {
        final repo = fakeFabric([box('sess9/main', name: 'goal_builder')]);
        final m = await fabricManager(repo);
        final tool = subagentMonitoringTools(
          manager: m,
          currentSubagentId: () => 'a1',
        ).firstWhere((t) => t.name == 'agent_message');
        final result = await tool.execute(
          {'to': 'goal_builder', 'message': 'hi by name'},
          null,
          null,
        );
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('queued for "goal_builder"'));
        expect(repo._inboxes['sess9/main'], hasLength(1));
      },
    );

    test('agent_message resolves "<name>/main" to the named session', () async {
      final repo = fakeFabric([box('sess9/main', name: 'goal_builder')]);
      final m = await fabricManager(repo);
      final tool = subagentMonitoringTools(
        manager: m,
        currentSubagentId: () => 'a1',
      ).firstWhere((t) => t.name == 'agent_message');
      final result = await tool.execute(
        {'to': 'goal_builder/main', 'message': 'hi by name/main'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('queued for "goal_builder/main"'));
      expect(repo._inboxes['sess9/main'], hasLength(1));
    });

    test(
      'agent_message ambiguity by name is an error listing candidates',
      () async {
        final repo = fakeFabric([
          box('sessA/main', name: 'goal_builder', cwd: '/work/a'),
          box('sessB/main', name: 'goal_builder', cwd: '/work/b'),
        ]);
        final m = await fabricManager(repo);
        final tool = subagentMonitoringTools(
          manager: m,
          currentSubagentId: () => 'a1',
        ).firstWhere((t) => t.name == 'agent_message');
        final result = await tool.execute(
          {'to': 'goal_builder', 'message': 'which one?'},
          null,
          null,
        );
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('error'));
        expect(text, contains('sessA/main'));
        expect(text, contains('sessB/main'));
        expect(repo._inboxes, isEmpty);
      },
    );

    test(
      'agent_message keeps exact absolute ids working (no name needed)',
      () async {
        final repo = fakeFabric([box('sess9/main')]);
        final m = await fabricManager(repo);
        final tool = subagentMonitoringTools(
          manager: m,
          currentSubagentId: () => 'a1',
        ).firstWhere((t) => t.name == 'agent_message');
        final result = await tool.execute(
          {'to': 'sess9/main', 'message': 'by raw id'},
          null,
          null,
        );
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('queued for "sess9/main"'));
        expect(repo._inboxes['sess9/main'], hasLength(1));
      },
    );

    test('messaging your own session name is refused', () async {
      final repo = fakeFabric([box('sess1/a1', name: 'me_myself')]);
      final m = await fabricManager(repo);
      final tool = subagentMonitoringTools(
        manager: m,
        currentSubagentId: () => 'a1',
      ).firstWhere((t) => t.name == 'agent_message');
      final result = await tool.execute(
        {'to': 'me_myself', 'message': 'note to self'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('cannot message yourself'));
      expect(repo._inboxes, isEmpty);
    });

    test('unknown name falls through to the unknown-recipient error', () async {
      final repo = fakeFabric([box('sess9/main', name: 'goal_builder')]);
      final m = await fabricManager(repo);
      final tool = subagentMonitoringTools(
        manager: m,
        currentSubagentId: () => 'a1',
      ).firstWhere((t) => t.name == 'agent_message');
      final result = await tool.execute(
        {'to': 'no_such_name', 'message': 'anyone?'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('error'));
      expect(text, contains('no_such_name'));
      expect(repo._inboxes, isEmpty);
    });
  });

  group('agent_directory: compact ids, activity, subagent clarity', () {
    Future<String> render(SubagentManager manager, {bool all = false}) async {
      final tools = subagentMonitoringTools(manager: manager);
      final directory = tools.firstWhere((t) => t.name == 'agent_directory');
      final result = await directory.execute(
        all ? const {'all': true} : const {},
        null,
        null,
      );
      return (result.content.first as dynamic).text as String;
    }

    test(
      'named mailboxes show a short id, activity and a shortened cwd',
      () async {
        final fabricMgr = SubagentManager(
          parentSessionId: 'p',
          homeDir: '/home/u',
          messaging: _FakeMessagingRepository(
            entries: [
              const MailboxEntry(
                id: '01a06102-15be-78be-9879-37615d698cf2/main',
                name: 'jsr',
                cwd: '/home/u/git/flutter_js_widget_runtime',
                lastActivity: null,
              ),
            ],
          ),
        );
        final text = await render(fabricMgr);
        expect(text, contains('jsr (01a06102…'));
        expect(text, isNot(contains('15be-78be')));
        expect(text, contains('~/git/flutter_js_widget_runtime'));
        expect(text, isNot(contains('/home/u/git/flutter_js_widget_runtime')));
      },
    );

    test('a live mailbox says active; a stale one says asleep', () async {
      final now = DateTime.now();
      final fabricMgr = SubagentManager(
        parentSessionId: 'p',
        messaging: _FakeMessagingRepository(
          entries: [
            MailboxEntry(
              id: 'sess-live/main',
              lastActivity: now.subtract(const Duration(minutes: 2)),
            ),
            MailboxEntry(
              id: 'sess-dead/main',
              cwd: '/work',
              lastActivity: now.subtract(const Duration(hours: 3)),
            ),
          ],
        ),
      );
      final text = await render(fabricMgr, all: true);
      expect(text, contains('sess-live/main — 0 pending — active 2m ago'));
      expect(text, contains('sess-dead/main — 0 pending — last active 3h ago'));
      expect(text, contains('(asleep)'));
    });

    test('all:true shows full mailbox ids', () async {
      final fabricMgr = SubagentManager(
        parentSessionId: 'p',
        messaging: _FakeMessagingRepository(
          entries: [
            const MailboxEntry(
              id: '01a06102-15be-78be-9879-37615d698cf2/main',
              name: 'jsr',
            ),
          ],
        ),
      );
      final text = await render(fabricMgr, all: true);
      expect(text, contains('01a06102-15be-78be-9879-37615d698cf2/main'));
    });

    test('failed subagents say how to resume them', () async {
      await mgr.register(
        id: 'a2',
        name: 'task-2',
        agentType: 'explore',
        task: 'x',
      );
      await mgr.update('a2', status: SubagentStatus.failed);
      final text = await render(mgr);
      expect(
        text,
        contains('task-2 — subagent (failed — resume with task_send)'),
      );
      expect(text, contains('task-1 — subagent (completed)'));
    });
  });

  group('agent_message: waking an asleep cross-session target', () {
    MailboxEntry sleepyEntry() => MailboxEntry(
      id: '01a0bbbb-0000-0000-0000-000000000000/main',
      name: 'sleepy',
      cwd: '/home/u/git/x',
      lastActivity: DateTime.now().subtract(const Duration(hours: 5)),
    );

    test('asleep target launches a headless run after delivery', () async {
      var launchedCwd = '';
      var launchedSessionId = '';
      String? launchedName;
      final fabricMgr = SubagentManager(
        parentSessionId: 'p',
        messaging: _FakeMessagingRepository(entries: [sleepyEntry()]),
        wakeProcess: ({required cwd, required sessionId, sessionName}) async {
          launchedCwd = cwd;
          launchedSessionId = sessionId;
          launchedName = sessionName;
          return null;
        },
      );
      final tools = subagentMonitoringTools(manager: fabricMgr);
      final msg = tools.firstWhere((t) => t.name == 'agent_message');
      final result = await msg.execute(
        const {'to': 'sleepy', 'message': 'wake up'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(launchedCwd, '/home/u/git/x');
      expect(launchedSessionId, '01a0bbbb-0000-0000-0000-000000000000');
      expect(launchedName, 'sleepy');
      expect(text, contains('asleep'));
      expect(text, contains('headless run of session "sleepy"'));
    });

    test('a live target is not woken', () async {
      var launches = 0;
      final fabricMgr = SubagentManager(
        parentSessionId: 'p',
        messaging: _FakeMessagingRepository(
          entries: [
            MailboxEntry(
              id: '01a0bbbb-0000-0000-0000-000000000000/main',
              name: 'sleepy',
              lastActivity: DateTime.now().subtract(const Duration(seconds: 5)),
            ),
          ],
        ),
        wakeProcess: ({required cwd, required sessionId, sessionName}) async {
          launches++;
          return null;
        },
      );
      final tools = subagentMonitoringTools(manager: fabricMgr);
      final msg = tools.firstWhere((t) => t.name == 'agent_message');
      await msg.execute(const {'to': 'sleepy', 'message': 'hi'}, null, null);
      expect(launches, 0);
    });

    test(
      'without a wake launcher the result says how to start the agent',
      () async {
        final fabricMgr = SubagentManager(
          parentSessionId: 'p',
          messaging: _FakeMessagingRepository(entries: [sleepyEntry()]),
        );
        final tools = subagentMonitoringTools(manager: fabricMgr);
        final msg = tools.firstWhere((t) => t.name == 'agent_message');
        final result = await msg.execute(
          const {'to': 'sleepy', 'message': 'hi'},
          null,
          null,
        );
        final text = (result.content.first as dynamic).text as String;
        expect(text, contains('fa --session sleepy'));
      },
    );
  });

  group('truncated-id addressing (agent_directory short ids are safe)', () {
    Future<SubagentManager> fabricManager(_FakeMessagingRepository repo) async {
      final m = SubagentManager(parentSessionId: 'p', messaging: repo)
        ..mailboxPrefix = 'sess1';
      await m.register(id: 'a1', name: 'a1', agentType: 'task', task: 'work');
      return m;
    }

    Future<dynamic> messageTool(SubagentManager m) async =>
        subagentMonitoringTools(
          manager: m,
          currentSubagentId: () => 'a1',
        ).firstWhere((t) => t.name == 'agent_message');

    test(
      'agent_message delivers to the full id for a truncated prefix',
      () async {
        final repo = _FakeMessagingRepository(
          entries: [
            MailboxEntry(
              id: '01a060f2-7d4b-73b3-a360-bdf56e8a3a14/main',
              name: 'support',
              cwd: '/work/fa',
              lastActivity: null,
            ),
          ],
        );
        final m = await fabricManager(repo);
        final tool = await messageTool(m);
        final result = await tool.execute(
          {'to': '01a060f2/main', 'message': 'hi via short id'},
          null,
          null,
        );
        final text = (result.content.first as dynamic).text as String;
        expect(text, isNot(contains('error')), reason: text);
        expect(
          repo._inboxes['01a060f2-7d4b-73b3-a360-bdf56e8a3a14/main'],
          hasLength(1),
        );
        expect(
          repo._inboxes.containsKey('01a060f2/main'),
          isFalse,
          reason: 'no dead mailbox may be created for a truncated id',
        );
      },
    );

    test('agent_message resolves an ellipsis-decorated short id', () async {
      final repo = _FakeMessagingRepository(
        entries: [
          MailboxEntry(
            id: '01a060f2-7d4b-73b3-a360-bdf56e8a3a14/main',
            name: 'support',
            cwd: '/work/fa',
            lastActivity: null,
          ),
        ],
      );
      final m = await fabricManager(repo);
      final tool = await messageTool(m);
      final result = await tool.execute(
        {'to': '01a060f2…/main', 'message': 'hi via copied short id'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, isNot(contains('error')), reason: text);
      expect(
        repo._inboxes['01a060f2-7d4b-73b3-a360-bdf56e8a3a14/main'],
        hasLength(1),
      );
    });

    test('agent_message ambiguity by truncated prefix is an error listing '
        'candidates', () async {
      final repo = _FakeMessagingRepository(
        entries: [
          MailboxEntry(
            id: '01a06ddb-3098-7f36-95e3-010ca2ca531b/main',
            name: 'support',
            cwd: '/work/runtime',
            lastActivity: null,
          ),
          MailboxEntry(
            id: '01a06ddb-d2b2-7e3a-9471-22ca40d8a1f5/main',
            name: 'widgets',
            cwd: '/work/fa',
            lastActivity: null,
          ),
        ],
      );
      final m = await fabricManager(repo);
      final tool = await messageTool(m);
      final result = await tool.execute(
        {'to': '01a06ddb/main', 'message': 'hi ambiguous'},
        null,
        null,
      );
      final text = (result.content.first as dynamic).text as String;
      expect(text, contains('error'));
      expect(text, contains('01a06ddb-3098-7f36-95e3-010ca2ca531b/main'));
      expect(text, contains('01a06ddb-d2b2-7e3a-9471-22ca40d8a1f5/main'));
      expect(
        repo._inboxes,
        isEmpty,
        reason: 'an ambiguous address must deliver nowhere',
      );
    });
  });
}
