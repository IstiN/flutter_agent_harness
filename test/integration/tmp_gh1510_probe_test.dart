@TestOn('vm')
@Tags(['integration', 'pty'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test('probe: dump raw stream around final reply', () async {
    final tempHome = Directory.systemTemp.createTempSync('fa_probe_');
    final workspace = Directory.systemTemp.createTempSync('fa_probe_ws_');
    addTearDown(() {
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    });
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
tui:
  classic: true
''');
    final script = MockLlmScript.parse('''
scenarios:
  - match: "Use the memory_add tool"
    responses:
      - toolCall:
          name: memory_add
          arguments: '{"text": "The project uses Dart 3.12"}'
      - toolCall:
          name: memory_search
          arguments: '{"query": "Dart"}'
      - text: "memory round-trip complete"
  - match: "Existing tags:"
    sticky: true
    responses:
      - text: ""
''');
    final server = await MockLlmServer.start(script: script);
    addTearDown(server.stop);
    final config = File('${tempHome.path}/.fah/config.yaml');
    config.writeAsStringSync(
      config.readAsStringSync().replaceFirst(
        'baseUrl: http://localhost:9999/v1',
        'baseUrl: ${server.baseUrl}',
      ),
    );
    final harness = await FaCliHarness.spawn(
      workingDirectory: workspace.path,
      extraEnv: {'HOME': tempHome.path},
    );
    harness.startListening();
    addTearDown(() async => harness.close());
    await harness.waitForBoot();
    harness.sendText(
      'Use the memory_add tool to save this fact: "The project uses Dart '
      '3.12". Then use memory_search to find it.',
    );
    harness.sendEnter();
    final screen = await harness.waitForScreen(
      'memory round-trip complete',
      timeout: const Duration(seconds: 30),
    );
    expect(screen, contains('✔ memory_search'));

    // Dump the raw stream segment around the final reply paint.
    final raw = harness.rawOutput;
    final idx = raw.indexOf('memory round-trip');
    final start = idx - 400 < 0 ? 0 : idx - 400;
    final seg = raw.substring(start, idx + 200);
    // Visualize escapes.
    final viz = seg
        .replaceAll('\x1b', '<ESC>')
        .replaceAll('\r', '<CR>')
        .replaceAll('\n', '<LF>\n');
    print('=== RAW SEGMENT AROUND REPLY ===');
    print(viz);
    print('=== SCREEN ===');
    print(screen);
  });
}
