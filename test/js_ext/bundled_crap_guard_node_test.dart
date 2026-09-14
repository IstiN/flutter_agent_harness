// Wrapper for the JS behavior suite: runs `node --test test/js_ext/node/*.mjs`
// when node is on PATH; skips cleanly when it is not. The real assertions
// live in test/js_ext/node/crap_guard_behavior_test.mjs.
//
// Glob form only: a bare directory argument is a MODULE PATH on every node
// (including v26) — `node --test test/js_ext/node/` fails with
// 'test failed' in ~30ms (issue #334: it flaked every full gate run, rescued
// only by the retry). Globs are supported since node 21.
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('node --test test/js_ext/node/*.mjs passes when node is on PATH', () async {
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

    final result = await _runNodeSuite(const ['test/js_ext/node/*.mjs']);
    stdout.write(result.stdout);
    stderr.write(result.stderr);
    if (result.exitCode != 0) {
      fail('node behavior suite failed (exit ${result.exitCode})');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<ProcessResult> _runNodeSuite(List<String> testArgs) =>
    Process.run('node', ['--test', ...testArgs], runInShell: true);
