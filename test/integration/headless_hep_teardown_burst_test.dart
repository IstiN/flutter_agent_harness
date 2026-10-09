/// gh-1455: headless HEP teardown stability under an event burst.
///
/// The old per-line writers fired an unawaited `stdout.flush()` for every
/// HEP frame; a flush still in flight when the next `writeln` landed threw
/// the synchronous `StateError("StreamSink is bound to a stream")` from an
/// event-callback frame — an uncaught zone error that crashed shutdown
/// (crash.log) and, on the exit path, let the process linger until the
/// runner's stall-kill. The serialized line chain in `bin/fah_util.dart`
/// makes the burst-and-exit sequence clean.
///
/// Boots the real CLI as a subprocess against the mock LLM (same
/// convention as `headless_log_file_test.dart`), drives a multi-turn tool
/// loop so hundreds of HEP frames flush back-to-back, and asserts a clean
/// exit with an intact, ordered frame stream and no sink StateError
/// anywhere.
@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'package:fa_llm_mock/fa_llm_mock.dart';

import 'pty_harness.dart';

void main() {
  late Directory tempHome;
  late Directory workspace;

  setUp(() {
    tempHome = Directory.systemTemp.createTempSync('hep_burst_home_');
    File('${tempHome.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('approvalMode: yolo\n');
    workspace = Directory.systemTemp.createTempSync('hep_burst_ws_');
  });

  tearDown(() {
    tempHome.deleteSync(recursive: true);
    workspace.deleteSync(recursive: true);
  });

  test(
    'a tool-loop HEP burst exits cleanly with an intact frame stream',
    () async {
      final server = await MockLlmServer.start();
      // A 30-cycle bash tool loop: every turn flushes a full frame group
      // (turn_start, message frames, tool_call/tool_result, turn_end) into
      // the pipe back-to-back — hundreds of frames through the writer in
      // the shortest possible wall time, the load profile that made the
      // old unawaited per-line flushes overlap.
      for (var i = 0; i < 30; i++) {
        server.enqueueToolCall('bash', '{"command":"echo cycle-$i"}');
        server.enqueueText('cycle $i done');
      }
      addTearDown(server.stop);

      final command = faCliCommand([
        '--provider',
        'openai-completions',
        '--base-url',
        server.baseUrl,
        '--model',
        'mock-model',
        '--cwd',
        workspace.path,
        '--output',
        'events',
        '-p',
        'run the loop',
      ], jitPrefix: const ['dart', 'run', 'bin/fah.dart']);
      final result = await Process.run(
        command.first,
        command.sublist(1),
        workingDirectory: Directory.current.path,
        // Whitelist child env (same convention as headless_log_file_test):
        // the ambient FA_PROVIDER_* / FA_SESSION_* variables on this
        // runner must NOT leak in — with only the mock reachable, a script
        // mismatch fails loudly instead of silently talking to a live
        // provider.
        environment: {
          'OPENAI_API_KEY': 'mock',
          'HOME': tempHome.path,
          'FA_STATE_DIR': '${tempHome.path}/.fah',
        },
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(minutes: 4));

      final stdoutText = result.stdout as String;
      final stderrText = result.stderr as String;
      expect(
        result.exitCode,
        0,
        reason: 'stdout: $stdoutText\nstderr: $stderrText',
      );
      expect(stderrText, isNot(contains('StateError')));
      expect(stdoutText, isNot(contains('StateError')));

      final lines = <Map<String, dynamic>>[];
      final stray = <String>[];
      for (final line in stdoutText.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        // Defensive: non-JSON noise on the events channel (e.g. the KB
        // tag generator's stdout prompt log — a separate wart) must not
        // mask the teardown assertions; HEP frames all start with '{'.
        if (!trimmed.startsWith('{')) {
          stray.add(trimmed);
          continue;
        }
        lines.add(jsonDecode(trimmed) as Map<String, dynamic>);
      }
      // Every frame is valid JSONL, in order, with a frame type.
      expect(lines.length, greaterThan(120));
      for (final frame in lines) {
        expect(frame.containsKey('type') || frame.containsKey('event'), isTrue,
            reason: 'malformed frame: $frame');
      }
      final types = [
        for (final frame in lines)
          (frame['type'] ?? frame['event']) as String,
      ];
      expect(types.where((t) => t.contains('tool')), isNotEmpty);
      expect(types, anyElement(contains('turn')));
    },
  );
}
