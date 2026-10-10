@TestOn('vm')
@Tags(['integration', 'pty'])
@Timeout(Duration(minutes: 8))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

String _analyze(String raw) {
  final out = StringBuffer();
  // Tokenize: CSI sequences, OSC sequences, ESC single-char, text runs.
  final re = RegExp(
    r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b.|[^\x1b]+',
  );
  var row = -1;
  var col = 1;
  final ws = raw.replaceAll('\r', '');
  for (final m in re.allMatches(ws)) {
    final tok = m.group(0)!;
    if (tok.startsWith('\x1b[')) {
      final cm = RegExp(r'^\x1b\[(\d+);(\d+)H$').firstMatch(tok);
      if (cm != null) {
        row = int.parse(cm.group(1)!);
        col = int.parse(cm.group(2)!);
        continue;
      }
      if (tok == '\x1b[K') {
        if (row == 17) out.write('«R17: EL from col $col»\n');
        continue;
      }
      final sm = RegExp(r'^\x1b\[(\d*)S$').firstMatch(tok);
      if (sm != null) {
        out.write('«SCROLL UP ${sm.group(1)!.isEmpty ? 1 : sm.group(1)}»\n');
        continue;
      }
      final dm = RegExp(r'^\x1b\[(\d*)T$').firstMatch(tok);
      if (dm != null) {
        out.write('«SCROLL DOWN ${dm.group(1)!.isEmpty ? 1 : dm.group(1)}»\n');
        continue;
      }
      // Other CSI (SGR etc.): ignore.
    } else if (tok.startsWith('\x1b')) {
      // Other escapes: ignore.
    } else {
      final text = tok.replaceAll('\n', '<LF>');
      if (row == 17) {
        out.write('«R17: col $col: ${text.length} chars: "$text"»\n');
      }
      col += text.length;
    }
  }
  return out.toString();
}

void main() {
  test('probe: row-17 write history until failure', () async {
    for (var attempt = 1; attempt <= 4; attempt++) {
      final tempHome = Directory.systemTemp.createTempSync('fa_probe_');
      final workspace = Directory.systemTemp.createTempSync('fa_probe_ws_');
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
      await harness.waitForBoot();
      harness.sendText(
        'Use the memory_add tool to save this fact: "The project uses Dart '
        '3.12". Then use memory_search to find it.',
      );
      harness.sendEnter();
      var failed = false;
      try {
        await harness.waitForScreen(
          'memory round-trip complete',
          timeout: const Duration(seconds: 30),
        );
      } catch (_) {
        failed = true;
      }
      await harness.close();
      await server.stop();
      print('=== ATTEMPT $attempt: ${failed ? 'FAILED (bug repro)' : 'passed'}');
      if (failed) {
        final log = _analyze(harness.rawOutput);
        print(log);
        tempHome.deleteSync(recursive: true);
        workspace.deleteSync(recursive: true);
        return;
      }
      tempHome.deleteSync(recursive: true);
      workspace.deleteSync(recursive: true);
    }
  });
}
