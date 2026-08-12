@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

/// Terminal reset integration test: verifies the CLI writes mouse-tracking
/// disable + cursor-show + exit-alt-screen sequences on exit so the shell
/// never sees raw mouse sequences.
void main() {
  group('terminal reset on exit', () {
    test(
      '/exit writes mouse-disable, cursor-show, and exit-alt-screen',
      () async {
        final tempHome = _tempHome();
        final harness = await FaCliHarness.spawn(
          extraEnv: {'HOME': tempHome.path},
        );

        await harness.waitForBoot();

        // Send /exit and wait for the process to finish.
        await harness.runSlashCommand('/exit');

        // Wait until the PTY process exits. After that the raw buffer holds
        // every byte the CLI wrote, including the trailing reset sequences.
        // exitCode is a Future that completes when the process terminates.
        await harness.pty.exitCode.timeout(
          const Duration(seconds: 30),
          onTimeout: () => -1,
        );

        // Give the output stream one final drain cycle so the last bytes
        // (written immediately before exit(0)) reach _rawBuffer.
        await Future<void>.delayed(const Duration(milliseconds: 200));

        // Capture the raw output BEFORE close() kills anything.
        final rawOutput = harness.rawOutput;

        await harness.close();
        tempHome.deleteSync(recursive: true);

        // Mouse tracking disabled (?1002l, ?1006l, ?1000l, ?1003l).
        expect(rawOutput, contains('\x1b[?1002l'));
        expect(rawOutput, contains('\x1b[?1006l'));
        expect(rawOutput, contains('\x1b[?1000l'));
        expect(rawOutput, contains('\x1b[?1003l'));
        // Cursor visible.
        expect(rawOutput, contains('\x1b[?25h'));
        // Exit alternate screen.
        expect(rawOutput, contains('\x1b[?1049l'));
        // Bracketed paste mode disabled.
        expect(rawOutput, contains('\x1b[?2004l'));
        // Focus reporting disabled.
        expect(rawOutput, contains('\x1b[?1004l'));
      },
    );
  });
}

/// Creates a temp HOME with a minimal config so the CLI boots without any
/// real API key.
Directory _tempHome() {
  final tempHome = Directory.systemTemp.createTempSync('fa_term_reset_');
  File('${tempHome.path}/.fah/config.yaml')
    ..createSync(recursive: true)
    ..writeAsStringSync('''
provider: openai-completions
model: test-model
baseUrl: http://localhost:9999/v1
mode: code
approvalMode: yolo
allowedTools: []
''');
  return tempHome;
}
