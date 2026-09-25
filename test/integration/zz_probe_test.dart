import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test('probe: dump the idle + busy screen at 80x24', () async {
    final tempHome = Directory.systemTemp.createTempSync('fa_probe_');
    // Unique per test — fixed /tmp paths collided across overlapping
    // runs (gh-936).
    final workspace = FaCliHarness.uniqueTempDir('fprob');
    addTearDown(() => workspace.deleteSync(recursive: true));
    final server = await MockLlmServer.start()
      ..enqueueToolCall('bash', '{"command": "sleep 6"}')
      ..enqueueText('probe done');
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
      columns: 80,
      rows: 24,
    );
    addTearDown(() async {
      await harness.close();
      tempHome.deleteSync(recursive: true);
    });

    await harness.waitForBoot();
    String dump(String tag) {
      // ignore: avoid_print
      print('=== $tag ===');
      // ignore: avoid_print
      harness.viewportLines.asMap().forEach((i, l) {
        // ignore: avoid_print
        print('${i.toString().padLeft(2)}|$l|');
      });
      return harness.screenText;
    }

    dump('idle boot');
    harness.sendText('hello probe');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    harness.sendEnter();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    dump('mid-run +2s');
    await Future<void>.delayed(const Duration(seconds: 7));
    dump('settled');
  });
}
