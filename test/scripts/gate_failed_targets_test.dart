// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-1026: `scripts/gate_failed_targets.py` — the failed-file extractor
/// behind the gate's `FA_GATE_PTY_RETRIES` rerun-only-failed flake budget.
///
/// The script consumes dart test `--file-reporter=json:<log>` output (the
/// same file-reporter the CI legs already emit) and prints the suite
/// paths of failed tests, one per line, sorted and deduped — the exact
/// rerun targets. Anything else (passes, skips, noise events) stays out.
library;

import 'dart:io';

import 'package:test/test.dart';

const scriptPath = 'scripts/gate_failed_targets.py';

/// dart test json file-reporter protocol (0.1.1) fixture builder.
String jsonLog({
  List<Map<String, Object?>> suites = const [],
  List<Map<String, Object?>> tests = const [],
  List<Map<String, Object?>> testDones = const [],
}) => [
      '{"protocolVersion":"0.1.1","type":"start","pid":1}',
      for (final s in suites)
        '{"type":"suite","suite":${s["json"]}}',
      for (final t in tests)
        '{"type":"testStart","test":${t["json"]}}',
      for (final d in testDones) '{"type":"testDone",${d["json"]}}',
      '{"type":"allSuites","success":false}',
      '{"type":"done","success":false}',
    ].join('\n');

Map<String, Object?> suite(int id, String path) => {
      'json':
          '{"id":$id,"platform":"vm","path":"$path"}',
    };

Map<String, Object?> testEntry(int id, int suiteId, String name) => {
      'json':
          '{"id":$id,"name":"$name","suiteID":$suiteId,"groupIDs":[],'
          '"startTime":0,"metadata":{"skip":false}}',
    };

Map<String, Object?> done(
  int testId,
  String result, {
  bool hidden = false,
}) => {
      'json':
          '"testID":$testId,"result":"$result","hidden":$hidden,'
          '"skipped":false',
    };

Future<(String stdout, int exitCode)> runScript(List<String> args) async {
  final proc = await Process.run('python3', [scriptPath, ...args]);
  return (proc.stdout as String, proc.exitCode);
}

Future<String> runOnLog(String log) async {
  final dir = await Directory.systemTemp.createTemp('gate_targets_');
  addTearDown(() => dir.deleteSync(recursive: true));
  final file = File('${dir.path}/log.json')..writeAsStringSync(log);
  final (out, code) = await runScript([file.path]);
  expect(code, 0);
  return out;
}

void main() {
  test('python3 is available (the gate and this file require it)', () {
    final probe = Process.runSync('python3', ['--version']);
    expect(probe.exitCode, 0);
  });

  test('extracts the suite path of a failed test', () async {
    final out = await runOnLog(jsonLog(
      suites: [suite(0, 'test/integration/a_test.dart')],
      tests: [testEntry(1, 0, 'loading test/integration/a_test.dart'),
              testEntry(2, 0, 'a case')],
      testDones: [
        done(1, 'success', hidden: true),
        done(2, 'failure'),
      ],
    ));
    expect(out, 'test/integration/a_test.dart\n');
  });

  test('dedupes several failures in one file to a single line', () async {
    final out = await runOnLog(jsonLog(
      suites: [suite(0, 'test/integration/a_test.dart')],
      tests: [
        testEntry(1, 0, 'one'),
        testEntry(2, 0, 'two'),
        testEntry(3, 0, 'three passes'),
      ],
      testDones: [
        done(1, 'failure'),
        done(2, 'error'),
        done(3, 'success'),
      ],
    ));
    expect(out, 'test/integration/a_test.dart\n');
  });

  test('ignores passes and skips; other files stay out', () async {
    final out = await runOnLog(jsonLog(
      suites: [
        suite(0, 'test/integration/green_test.dart'),
        suite(1, 'test/integration/red_test.dart'),
      ],
      tests: [
        testEntry(1, 0, 'passing'),
        testEntry(2, 0, 'skipped'),
        testEntry(3, 1, 'failing'),
      ],
      testDones: [
        done(1, 'success'),
        done(2, 'skip'),
        done(3, 'failure'),
      ],
    ));
    expect(out, 'test/integration/red_test.dart\n');
  });

  test('a hidden (suite-load) failure maps to its suite path', () async {
    final out = await runOnLog(jsonLog(
      suites: [suite(0, 'test/integration/broken_test.dart')],
      tests: [testEntry(1, 0, 'loading test/integration/broken_test.dart')],
      testDones: [done(1, 'error', hidden: true)],
    ));
    expect(out, 'test/integration/broken_test.dart\n');
  });

  test('a load failure with NO suite event falls back to the loading '
      'test name', () async {
    final out = await runOnLog(jsonLog(
      suites: [],
      tests: [testEntry(7, 3, 'loading test/integration/worse_test.dart')],
      testDones: [done(7, 'error', hidden: true)],
    ));
    expect(out, 'test/integration/worse_test.dart\n');
  });

  test('multiple failing files come out sorted, deduped, one per line',
      () async {
    final out = await runOnLog(jsonLog(
      suites: [
        suite(0, 'test/integration/b_test.dart'),
        suite(1, 'test/integration/a_test.dart'),
        suite(2, 'test/cli/unit_test.dart'),
      ],
      tests: [
        testEntry(1, 0, 'b one'),
        testEntry(2, 0, 'b two'),
        testEntry(3, 1, 'a one'),
        testEntry(4, 2, 'cli passes'),
      ],
      testDones: [
        done(1, 'failure'),
        done(2, 'failure'),
        done(3, 'error'),
        done(4, 'success'),
      ],
    ));
    expect(
      out,
      'test/integration/a_test.dart\n'
      'test/integration/b_test.dart\n',
    );
  });

  test('a missing log file is a clean empty result (no blind rerun)',
      () async {
    final (out, code) = await runScript(['/nonexistent/log.json']);
    expect(code, 0);
    expect(out, isEmpty);
  });

  test('an empty log is a clean empty result', () async {
    final out = await runOnLog('');
    expect(out, isEmpty);
  });
}
