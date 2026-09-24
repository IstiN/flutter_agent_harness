@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test('probe: what does a task call persist?', () async {
    final tempHome = Directory.systemTemp.createTempSync('fa_probe_task_');
    final workspace = Directory('/tmp/fa_probe_task_ws')
      ..createSync(recursive: true);
    addTearDown(() => workspace.deleteSync(recursive: true));
    final server = await MockLlmServer.start()
      ..enqueueToolCall(
        'task',
        '{"context": "probe", "tasks": [{"name": "p1", "task": "list files"}]}',
      )
      ..enqueueText('task done');
    addTearDown(server.stop);
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
''');

    final harness = await FaCliHarness.spawn(
      workingDirectory: workspace.path,
      extraEnv: {'HOME': tempHome.path},
      columns: 100,
      rows: 30,
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
    });
    await harness.waitForBoot();
    harness.sendText('run one task');
    harness.sendEnter();
    await harness.waitForText(
      'task done',
      timeout: const Duration(seconds: 60),
    );
    await Future<void>.delayed(const Duration(seconds: 1));

    final sessionsDir = Directory('${tempHome.path}/.fah/sessions');
    await for (final entry in sessionsDir.list(recursive: true)) {
      if (entry is File && entry.path.endsWith('.jsonl')) {
        // ignore: avoid_print
        print('=== ${entry.path.split('/').last} ===');
        for (final line in entry.readAsLinesSync()) {
          try {
            final obj = jsonDecode(line) as Map<String, dynamic>;
            final kind = (obj['type'] ?? obj['role'] ?? '?').toString();
            final id = (obj['toolCallId'] ?? obj['id'] ?? '-').toString();
            final name = (obj['name'] ?? '').toString();
            final err = (obj['isError'] ?? '').toString();
            // ignore: avoid_print
            print('kind=$kind id=$id name=$name err=$err');
          } catch (_) {}
        }
      }
    }
  });
}
