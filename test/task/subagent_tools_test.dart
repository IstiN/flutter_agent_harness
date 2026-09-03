@TestOn('vm')
library;

import 'package:flutter_sandbox/flutter_sandbox.dart';
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
  Future<void> register(String agentId) async {}

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
        expect(text, contains('stale-mailbox — 1 pending'));
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
        expect(text, contains('a1'));
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
}
