// Wrapper for the JS behavior suite: runs `node --test test/js_ext/node/`
// when node is on PATH; skips cleanly when it is not. The real assertions
// live in test/js_ext/node/crap_guard_behavior_test.mjs.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('node --test test/js_ext/node/ passes when node is on PATH', () async {
    ProcessResult probe;
    try {
      probe = await Process.run('node', ['--version'], runInShell: true);
    } on ProcessException {
      print('skip: node not on PATH');
      return;
    }
    if (probe.exitCode != 0) {
      print('skip: node unusable: ${probe.stderr}');
      return;
    }
    print('node ${(probe.stdout as String).trim()}');

    var result = await _runNodeSuite(const ['test/js_ext/node/']);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      // Node < 23 rejects a directory argument (MODULE_NOT_FOUND); retry
      // with a glob, supported by node >= 21.
      result = await _runNodeSuite(const ['test/js_ext/node/*.mjs']);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
      if (result.exitCode != 0) {
        fail('node behavior suite failed (exit ${result.exitCode})');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<ProcessResult> _runNodeSuite(List<String> testArgs) =>
    Process.run('node', ['--test', ...testArgs], runInShell: true);
