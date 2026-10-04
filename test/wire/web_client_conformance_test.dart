// sdk/web conformance hook (issue #1101, AC4/UT-3): the web reference
// client must parse every golden event fixture and reproduce every pinned
// command frame. CI runs the node suite through THIS test so the Dart
// server and the TypeScript client drift-proof each other in one gate.
//
// Loud failure when node is missing — a silently skipped conformance run
// would pin nothing.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('sdk/web conformance runner passes', () {
    final script = File('sdk/web/test/conformance.test.mjs');
    expect(
      script.existsSync(),
      isTrue,
      reason: 'run from the package root: ${script.path} not found',
    );
    final ProcessResult result;
    try {
      result = Process.runSync('node', ['--test'], workingDirectory: 'sdk/web');
    } on ProcessException catch (error) {
      fail('node is required for the sdk/web conformance suite: $error');
    }
    expect(
      result.exitCode,
      0,
      reason: 'sdk/web conformance failed:\n${result.stdout}\n${result.stderr}',
    );
  });
}
