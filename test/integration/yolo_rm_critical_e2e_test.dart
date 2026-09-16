/// YOLO rm false-positive e2e (issue #460 AC4):
///
/// Boots the real CLI as a subprocess against the mock LLM with
/// `approvalMode: yolo` and scripts one bash tool call per run:
///
/// - `rm -f /tmp/…` (the owner's false-positive shape) must EXECUTE: no
///   critical dialog, no denial, run completes normally.
/// - `rm -rf /` (the canonical catastrophe) must still trip the critical
///   interceptor. Headless has no approval UI, so the forced prompt denies
///   the call and the denial reason reaches the model as the tool result.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:fa_llm_mock/fa_llm_mock.dart';

void main() {
  late Directory tempHome;
  late Directory workspace;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('yolo_rm_home_');
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('approvalMode: yolo\n');
    workspace = Directory.systemTemp.createTempSync('yolo_rm_ws_');
  });

  tearDown(() {
    tempHome.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  Future<ProcessResult> runHeadless(MockLlmServer server) {
    return Process.run(
      'dart',
      [
        'run',
        'bin/fah.dart',
        '--provider',
        'openai-completions',
        '--base-url',
        server.baseUrl,
        '--model',
        'mock-model',
        '--cwd',
        workspace.path,
        '-p',
        'hi',
      ],
      workingDirectory: Directory.current.path,
      environment: {'OPENAI_API_KEY': 'mock', 'HOME': tempHome.path},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 4));
  }

  test('yolo executes rm -f /tmp/… with no critical outcome', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    final probe = '/tmp/fah460_${DateTime.now().microsecondsSinceEpoch}.js';
    server
      ..enqueueToolCall('bash', '{"command": "rm -f $probe"}')
      ..enqueueText('removed');

    final result = await runHeadless(server);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final output = '${result.stdout}${result.stderr}';
    expect(output, isNot(contains('Critical pattern')));
    expect(output, contains('removed'));
  });

  test('yolo still denies rm -rf / via the critical interceptor', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    server
      ..enqueueToolCall('bash', '{"command": "rm -rf /"}')
      ..enqueueToolResultEcho();

    final result = await runHeadless(server);
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final output = '${result.stdout}${result.stderr}';
    expect(
      output,
      contains('Critical pattern detected: recursive delete from a root path'),
    );
    expect(output, contains('no approval UI is available'));
  });
}
