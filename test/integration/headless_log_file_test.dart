/// Headless `--log-file` flag proof (issue #91):
///
/// Boots the real CLI as a subprocess against the mock LLM and asserts the
/// live session trace lands in the tee file:
///
/// - the assistant reply is teed (`write` channel)
/// - tool-trace diagnostics are teed (`writeln` channel — stderr headless,
///   invisible in a stdout-only parent capture; exactly the issue's scenario)
/// - without the flag no file is written and stdout still carries the reply
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
    tempHome = Directory.systemTemp.createTempSync('headless_log_home_');
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('approvalMode: yolo\n');
    workspace = Directory.systemTemp.createTempSync('headless_log_ws_');
  });

  tearDown(() {
    tempHome.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  /// Spawns one headless `fah` prompt (temp HOME, `--cwd <workspace>`),
  /// same convention as `fa_cube_headless_helper.dart`, with [extraArgs]
  /// appended before the prompt.
  Future<ProcessResult> runHeadless(
    MockLlmServer server,
    List<String> extraArgs,
  ) {
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
        ...extraArgs,
        '-p',
        'hi',
      ],
      workingDirectory: Directory.current.path,
      environment: {'OPENAI_API_KEY': 'mock', 'HOME': tempHome.path},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 4));
  }

  test('--log-file tees the assistant reply and the tool trace', () async {
    final server = await MockLlmServer.start();
    addTearDown(server.stop);
    // Turn 1: the model calls `bash`; turn 2: the reply echoes the tool
    // result. The `[bash]` trace line must reach the file even though
    // headless prints diagnostics to stderr (invisible in a stdout-only
    // parent capture — exactly the issue's scenario).
    server
      ..enqueueToolCall('bash', '{"command": "echo log-file-proof"}')
      ..enqueueToolResultEcho();

    final logPath = '${workspace.path}/trace.log';
    final result = await runHeadless(server, ['--log-file', logPath]);
    expect(result.exitCode, 0, reason: '${result.stderr}');

    final log = File(logPath).readAsStringSync();
    expect(log, contains('[bash]'));
    expect(log, contains('log-file-proof'));
  });

  test(
    'without the flag the stdout trace is unchanged and no file lands',
    () async {
      final server = await MockLlmServer.start();
      addTearDown(server.stop);
      server.enqueueText('plain reply');

      final logPath = '${workspace.path}/absent.log';
      final result = await runHeadless(server, const []);
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout as String, contains('plain reply'));
      expect(File(logPath).existsSync(), isFalse);
    },
  );
}
