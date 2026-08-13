@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/task/subagent.dart';
import 'package:flutter_agent_harness/src/task/subagent_manager.dart';
import 'package:flutter_agent_harness/src/task/subagent_tools.dart';
import 'package:test/test.dart';

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

    test('returns 3 tools', () {
      final tools = subagentMonitoringTools(manager: mgr);
      expect(tools.length, 3);
      expect(
        tools.map((t) => t.name),
        containsAll(['task_status', 'task_observe', 'task_send']),
      );
    });

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
        sendToChild: (_, __) async {},
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
        sendToChild: (_, __) async {},
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
  });
}
