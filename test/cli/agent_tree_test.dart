@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/cli/agent_tree.dart';
import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:test/test.dart';

SubagentHandle _handle({
  String id = 'a1',
  String agentType = 'explore',
  SubagentStatus status = SubagentStatus.running,
  String task = 'scout the files',
  int tokens = 0,
  String? modelId,
}) {
  final handle = SubagentHandle(
    id: id,
    name: id,
    agentType: agentType,
    sessionId: '/tmp/$id.jsonl',
    createdAt: '2026-01-01T00:00:00Z',
    task: task,
  );
  handle.status = status;
  handle.tokens = tokens;
  handle.modelId = modelId;
  return handle;
}

void main() {
  group('agentStatusIcon', () {
    test('maps every status to an emoji', () {
      expect(agentStatusIcon(SubagentStatus.queued), '⏳');
      expect(agentStatusIcon(SubagentStatus.running), '🔄');
      expect(agentStatusIcon(SubagentStatus.idle), '⏸');
      expect(agentStatusIcon(SubagentStatus.completed), '✅');
      expect(agentStatusIcon(SubagentStatus.failed), '❌');
      expect(agentStatusIcon(SubagentStatus.aborted), '🛑');
    });
  });

  group('agentRowDescription', () {
    test('status plus task preview', () {
      final description = agentRowDescription(_handle());
      expect(description, contains('running'));
      expect(description, contains('scout the files'));
    });

    test('long tasks are truncated with an ellipsis', () {
      final description = agentRowDescription(_handle(task: 'x' * 100));
      expect(description.length, lessThan(60));
      expect(description, contains('…'));
    });

    test('tokens and model join when present', () {
      final description = agentRowDescription(
        _handle(tokens: 1500, modelId: 'gpt-4o-mini'),
      );
      expect(description, contains('1500t'));
      expect(description, contains('gpt-4o-mini'));
    });

    test('multiline tasks are flattened', () {
      final description = agentRowDescription(
        _handle(task: 'line one\nline two'),
      );
      expect(description, contains('line one line two'));
    });
  });

  group('buildAgentTreeItems', () {
    test('main row first with model and message count', () {
      final items = buildAgentTreeItems(
        const [],
        modelId: 'k3',
        messageCount: 42,
      );
      expect(items.first.key, 'main');
      expect(items.first.label, contains('main (orchestrator)'));
      expect(items.first.description, contains('k3'));
      expect(items.first.description, contains('42'));
    });

    test('one row per child with status icon and key prefix', () {
      final items = buildAgentTreeItems(
        [
          _handle(id: 'a1'),
          _handle(id: 'b2', status: SubagentStatus.completed),
        ],
        modelId: 'k3',
        messageCount: 1,
      );
      expect(items, hasLength(3));
      expect(items[1].key, 'child:a1');
      expect(items[1].label, contains('🔄 explore:a1'));
      expect(items[2].label, contains('✅ explore:b2'));
    });

    test('empty children append the noop row', () {
      final items = buildAgentTreeItems(
        const [],
        modelId: 'k3',
        messageCount: 0,
      );
      expect(items.last.key, 'noop');
      expect(items.last.label, contains('no subagents yet'));
    });
  });

  group('subagentReceiveGuard', () {
    test('null handle refuses with the unknown-id message', () {
      expect(subagentReceiveGuard(null, 'ghost'), 'no subagent "ghost"');
    });

    test('failed and aborted children refuse', () {
      final failed = _handle(status: SubagentStatus.failed);
      final aborted = _handle(status: SubagentStatus.aborted);
      expect(
        subagentReceiveGuard(failed, 'a1'),
        'cannot send to failed subagent "a1"',
      );
      expect(
        subagentReceiveGuard(aborted, 'a1'),
        'cannot send to aborted subagent "a1"',
      );
    });

    test('running/idle/completed children accept', () {
      for (final status in [
        SubagentStatus.running,
        SubagentStatus.idle,
        SubagentStatus.completed,
        SubagentStatus.queued,
      ]) {
        expect(subagentReceiveGuard(_handle(status: status), 'a1'), isNull);
      }
    });
  });

  group('formatActiveAgentsBadge', () {
    test('empty when nothing is active', () {
      expect(formatActiveAgentsBadge(const []), '');
      expect(
        formatActiveAgentsBadge([
          _handle(status: SubagentStatus.completed),
          _handle(status: SubagentStatus.failed),
        ]),
        '',
      );
    });

    test('active children show type, id, and elapsed seconds', () {
      final now = DateTime.parse('2026-01-01T00:01:00Z');
      final active = SubagentHandle(
        id: 'a1',
        name: 'a1',
        agentType: 'explore',
        sessionId: '/tmp/a1.jsonl',
        createdAt: '2026-01-01T00:00:00Z',
        task: '',
      )..status = SubagentStatus.running;
      final badge = formatActiveAgentsBadge([active], now: now);
      expect(badge, 'bg:explore:a1(60s)');
    });

    test('overflow beyond max collapses to +N', () {
      final handles = [
        for (var i = 0; i < 5; i++)
          _handle(id: 'a$i', status: SubagentStatus.running),
      ];
      final badge = formatActiveAgentsBadge(handles, max: 2);
      expect(badge, contains(',+3'));
      expect(badge.split(',').length, 3);
    });
  });
}
