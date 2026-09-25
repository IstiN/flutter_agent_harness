/// Overlap acceptance REG test (gh-936): on the 2026-09-24/25 night two
/// overlapping runs of the PTY suites on one runner shared fixed /tmp
/// dirs and raced hub ports — 4 red legs, forced admin merges. The
/// acceptance: two full PTY runs over the SAME checkout, OVERLAPPING,
/// stay green.
///
/// This test is the in-suite proxy: two concurrent PTY CLI lifecycles
/// (boot → prompt → reply → exit), each with its own mock provider and
/// unique HOME, sharing the default-CWD machinery — exactly the state a
/// cancelled predecessor and its successor used to collide in. The
/// per-run root makes the two runs' dirs disjoint by construction; the
/// hub-side shared bind + retry is pinned separately in
/// `test/hub/local_hub_bind_test.dart`.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 4))
library;

import 'dart:io';

import 'package:fa_llm_mock/fa_llm_mock.dart';
import 'package:test/test.dart';

import 'pty_harness.dart';

void main() {
  test(
    'two overlapping PTY CLI runs on one machine both stay green',
    () async {
      final outcomes = await Future.wait([
        _runSuite('overlap-a'),
        _runSuite('overlap-b'),
      ]);
      for (final outcome in outcomes) {
        expect(outcome, 'green', reason: 'both overlapping runs must pass');
      }
    },
  );
}

/// One full PTY lifecycle: boot, one answered prompt, clean exit.
/// Returns 'green', or the failure description.
Future<String> _runSuite(String session) async {
  final server = await MockLlmServer.start()..enqueueText('reply for $session');
  final home = FaCliHarness.uniqueTempDir('fa_pty_overlap_${session}_home_');
  try {
    File('${home.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('''
provider: openai-completions
model: mock-model
baseUrl: ${server.baseUrl}
mode: code
approvalMode: yolo
allowedTools: []
''');

    // Default workingDirectory: exercises the per-spawn unique cwd under
    // the per-run root (the old fixed /tmp/fa_pty_cwd was shared).
    final harness = await FaCliHarness.spawn(
      extraEnv: {'HOME': home.path},
      args: ['--session', session],
    );
    try {
      await harness.waitForBoot();
      harness.sendText('say the marker');
      harness.sendEnter();
      await harness.waitForText(
        'reply for $session',
        timeout: const Duration(seconds: 60),
      );
      await harness.runSlashCommand('/exit');
      final code = await harness.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => -1,
      );
      if (code != 0) return 'exit code $code';
      return 'green';
    } on Object catch (error) {
      return '$error';
    } finally {
      await harness.close();
    }
  } on Object catch (error) {
    return '$error';
  } finally {
    try {
      await server.stop();
    } on Object {
      // Teardown never masks the verdict.
    }
    if (home.existsSync()) home.deleteSync(recursive: true);
  }
}
