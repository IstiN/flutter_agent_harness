import 'dart:convert';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

void main() {
  final protocol = AgentWireProtocol();
  final event = TaskLedgerEvent(
    const TaskLedger(items: [
      TaskLedgerItem(
        requirement: 'create script.py',
        command: 'test -f script.py',
        expected: 'exit 0',
        actual: 'exit 0',
        status: TaskLedgerItemStatus.pass,
      ),
      TaskLedgerItem(
        requirement: 'script.py is executable',
        command: 'test -x script.py',
        expected: 'exit 0',
        actual: 'exit 1',
        status: TaskLedgerItemStatus.fixed,
      ),
    ]),
  );
  print(jsonEncode({
    'kind': 'task_ledger',
    'protocolVersion': 1,
    'frame': protocol.encodeEvent(event),
  }));
}
