// sdk/web conformance hook (issue #1101, AC4/UT-3): the web reference
// client must parse every golden event fixture and reproduce every pinned
// command frame. CI runs the node suite through THIS test so the Dart
// server and the TypeScript client drift-proof each other in one gate.
//
// Loud failure when node is missing — a silently skipped conformance run
// would pin nothing.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('sdk/web conformance runner passes', () async {
    final script = File('sdk/web/test/conformance.test.mjs');
    expect(
      script.existsSync(),
      isTrue,
      reason: 'run from the package root: ${script.path} not found',
    );
    // Explicit file, never bare `--test`: node's default discovery also
    // executes mock-serve.mjs (top-level http.listen) as a "test", and the
    // open server handle keeps the run alive until the job timeout.
    const conformanceEntry = 'test/conformance.test.mjs';
    final Process process;
    try {
      process = await Process.start(
        'node',
        ['--test', conformanceEntry],
        workingDirectory: 'sdk/web',
      );
    } on ProcessException catch (error) {
      fail('node is required for the sdk/web conformance suite: $error');
    }
    // Drain output while the suite runs so a chatty run cannot wedge pipes.
    final stdoutFuture = process.stdout.transform(utf8.decoder).join();
    final stderrFuture = process.stderr.transform(utf8.decoder).join();
    // A wedged suite must fail loudly, not hang CI — and the orphaned node
    // process has to be killed, not merely abandoned by the timed-out future.
    const budget = Duration(minutes: 2);
    final int exitCode;
    try {
      exitCode = await process.exitCode.timeout(budget);
    } on TimeoutException {
      process.kill();
      final out = await stdoutFuture;
      final err = await stderrFuture;
      fail(
        'sdk/web conformance exceeded $budget and was killed:\n'
        '$out\n$err',
      );
    }
    final out = await stdoutFuture;
    final err = await stderrFuture;
    expect(
      exitCode,
      0,
      reason: 'sdk/web conformance failed:\n$out\n$err',
    );
  });
}
