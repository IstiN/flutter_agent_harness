@TestOn('vm')
library;

import 'package:flutter_agent_harness/src/task/delivery_slo.dart';
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
  });

  Future<String> statusDetail() async {
    final tools = subagentMonitoringTools(manager: mgr);
    final statusTool = tools.firstWhere((t) => t.name == 'task_status');
    final result = await statusTool.execute({'id': 'a1'}, null, null);
    return (result.content.first as dynamic).text as String;
  }

  Future<void> enqueue({required Duration age, required String text}) =>
      mgr.enqueueMessage(
        'a1',
        SubagentMessage(
          fromId: 'main',
          text: text,
          // sentAt IS the enqueue stamp — backdate through this public
          // seam instead of stubbing a clock.
          sentAt: DateTime.now().subtract(age).toIso8601String(),
        ),
      );

  test('pending mail older than the delivery SLO escalates to a visible '
      'UNDELIVERED line (issue #1923 AC3)', () async {
    await enqueue(age: const Duration(seconds: 10), text: 'stale mail');
    final detail = await statusDetail();
    expect(detail, contains('mail: 1 pending — UNDELIVERED '));
    expect(detail, contains('(past the 2s delivery SLO)'));
  });

  test('fresh pending mail is within the SLO — no UNDELIVERED line', () async {
    await enqueue(age: Duration.zero, text: 'fresh mail');
    final detail = await statusDetail();
    expect(detail, isNot(contains('UNDELIVERED')));
  });

  test('no pending mail — no UNDELIVERED line', () async {
    final detail = await statusDetail();
    expect(detail, isNot(contains('UNDELIVERED')));
  });

  test('oldestPendingMailSince answers the oldest pending stamp', () async {
    expect(await mgr.oldestPendingMailSince('a1'), isNull);
    await enqueue(age: const Duration(seconds: 30), text: 'old');
    await enqueue(age: Duration.zero, text: 'newer');
    final oldest = await mgr.oldestPendingMailSince('a1');
    expect(oldest, isNotNull);
    expect(
      DateTime.now().difference(oldest!) > deliverySlo,
      isTrue,
      reason: 'the 30s-old stamp is the oldest pending mail',
    );
  });

  test('deliveryStage marks a stage past the SLO with BREACH', () {
    final lines = <String>[];
    deliverySloSink = lines.add;
    deliveryStage(
      'a1',
      'enqueued',
      since: DateTime.now().subtract(const Duration(seconds: 3)),
    );
    deliveryStage('a1', 'enqueued', since: DateTime.now());
    deliverySloSink = null;
    expect(
      lines.where((l) => l.contains(' BREACH')),
      hasLength(1),
      reason: 'only the 3s-old stage breaches the 2s SLO',
    );
  });
}
