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
  for (final s in suites) '{"type":"suite","suite":${s["json"]}}',
  for (final t in tests) '{"type":"testStart","test":${t["json"]}}',
  for (final d in testDones) '{"type":"testDone",${d["json"]}}',
  '{"type":"allSuites","success":false}',
  '{"type":"done","success":false}',
].join('\n');

Map<String, Object?> suite(int id, String path) => {
  'json': '{"id":$id,"platform":"vm","path":"$path"}',
};

Map<String, Object?> testEntry(int id, int suiteId, String name) => {
  'json':
      '{"id":$id,"name":"$name","suiteID":$suiteId,"groupIDs":[],'
      '"startTime":0,"metadata":{"skip":false}}',
};

Map<String, Object?> done(int testId, String result, {bool hidden = false}) => {
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
    final out = await runOnLog(
      jsonLog(
        suites: [suite(0, 'test/integration/a_test.dart')],
        tests: [
          testEntry(1, 0, 'loading test/integration/a_test.dart'),
          testEntry(2, 0, 'a case'),
        ],
        testDones: [done(1, 'success', hidden: true), done(2, 'failure')],
      ),
    );
    expect(out, 'test/integration/a_test.dart\n');
  });

  test('dedupes several failures in one file to a single line', () async {
    final out = await runOnLog(
      jsonLog(
        suites: [suite(0, 'test/integration/a_test.dart')],
        tests: [
          testEntry(1, 0, 'one'),
          testEntry(2, 0, 'two'),
          testEntry(3, 0, 'three passes'),
        ],
        testDones: [done(1, 'failure'), done(2, 'error'), done(3, 'success')],
      ),
    );
    expect(out, 'test/integration/a_test.dart\n');
  });

  test('ignores passes and skips; other files stay out', () async {
    final out = await runOnLog(
      jsonLog(
        suites: [
          suite(0, 'test/integration/green_test.dart'),
          suite(1, 'test/integration/red_test.dart'),
        ],
        tests: [
          testEntry(1, 0, 'passing'),
          testEntry(2, 0, 'skipped'),
          testEntry(3, 1, 'failing'),
        ],
        testDones: [done(1, 'success'), done(2, 'skip'), done(3, 'failure')],
      ),
    );
    expect(out, 'test/integration/red_test.dart\n');
  });

  test('a hidden (suite-load) failure maps to its suite path', () async {
    final out = await runOnLog(
      jsonLog(
        suites: [suite(0, 'test/integration/broken_test.dart')],
        tests: [testEntry(1, 0, 'loading test/integration/broken_test.dart')],
        testDones: [done(1, 'error', hidden: true)],
      ),
    );
    expect(out, 'test/integration/broken_test.dart\n');
  });

  test('a load failure with NO suite event falls back to the loading '
      'test name', () async {
    final out = await runOnLog(
      jsonLog(
        suites: [],
        tests: [testEntry(7, 3, 'loading test/integration/worse_test.dart')],
        testDones: [done(7, 'error', hidden: true)],
      ),
    );
    expect(out, 'test/integration/worse_test.dart\n');
  });

  test(
    'multiple failing files come out sorted, deduped, one per line',
    () async {
      final out = await runOnLog(
        jsonLog(
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
        ),
      );
      expect(
        out,
        'test/integration/a_test.dart\n'
        'test/integration/b_test.dart\n',
      );
    },
  );

  test('a missing log file is a clean empty result (no blind rerun)', () async {
    final (out, code) = await runScript(['/nonexistent/log.json']);
    expect(code, 0);
    expect(out, isEmpty);
  });

  test('an empty log is a clean empty result', () async {
    final out = await runOnLog('');
    expect(out, isEmpty);
  });

  // ── gh-2381: the engine-abandonment evidence (run 45200064457, shard 2/3:
  //    testStart 101 vs testDone 98; the resume_tail coverage-gather crash
  //    killed Engine.run() mid-queue and left three tests in flight). The
  //    wrapper needs these two extra projections off the same log.
  group('gh-2381 — unfinished and loaded projections', () {
    /// The REAL abandonment shape from run 45200064457: two suites loaded
    /// (one finished both tests, one has a test started at t=28169 that
    /// never finished), plus `allSuites` counting 26 planned.
    String abandonedLog() => [
      '{"type":"start","pid":1}',
      '{"type":"allSuites","count":26,"time":12}',
      '{"type":"suite","suite":{"id":126,"platform":"vm",'
          '"path":"test/integration/resume_tail_grid_pty_test.dart"}}',
      '{"type":"suite","suite":{"id":128,"platform":"vm",'
          '"path":"test/integration/shell_job_countdown_pty_test.dart"}}',
      '{"type":"suite","suite":{"id":135,"platform":"vm",'
          '"path":"test/integration/ssh_shift_gate_test.dart"}}',
      '{"type":"testStart","test":{"id":133,"name":"ten background bash '
          'jobs start, count down on camera, drain to 0 running (#573 '
          'review)","suiteID":128,"groupIDs":[132],'
          '"metadata":{"skip":false}},"time":28169}',
      '{"type":"testStart","test":{"id":138,"name":"SSH session env: the '
          'first Enter submits and Ctrl+C quits","suiteID":135,'
          '"groupIDs":[137],"metadata":{"skip":false}},"time":31113}',
      '{"type":"testStart","test":{"id":131,"name":"resume tail + single '
          'lost summary at 80 x 24","suiteID":126,"groupIDs":[],'
          '"metadata":{"skip":false}},"time":27430}',
      '{"type":"testDone","testID":131,"result":"success","hidden":false,'
          '"skipped":false,"time":30498}',
      '{"type":"done","success":true}',
    ].join('\n');

    test('--unfinished lists the suite paths of started-but-never-finished '
        'tests', () async {
      final dir = await Directory.systemTemp.createTemp('gate_targets_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/log.json')
        ..writeAsStringSync(abandonedLog());
      final (out, code) = await runScript([file.path, '--unfinished']);
      expect(code, 0);
      expect(
        out,
        'test/integration/shell_job_countdown_pty_test.dart\n'
        'test/integration/ssh_shift_gate_test.dart\n',
        reason:
            'both in-flight tests belong to suites whose tearDowns never '
            'ran — exactly the rerun targets (sorted, deduped)',
      );
    });

    test('--unfinished dedupes several in-flight tests of one suite', () async {
      final dir = await Directory.systemTemp.createTemp('gate_targets_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/log.json')
        ..writeAsStringSync(
          jsonLog(
            suites: [suite(9, 'test/integration/multi_test.dart')],
            tests: [
              testEntry(10, 9, 'one in flight'),
              testEntry(11, 9, 'two in flight'),
            ],
          ),
        );
      final (out, code) = await runScript([file.path, '--unfinished']);
      expect(code, 0);
      expect(out, 'test/integration/multi_test.dart\n');
    });

    test('--unfinished stays clean-empty on a fully finished log', () async {
      final dir = await Directory.systemTemp.createTemp('gate_targets_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/log.json')
        ..writeAsStringSync(
          jsonLog(
            suites: [suite(0, 'test/integration/a_test.dart')],
            tests: [testEntry(1, 0, 'a case')],
            testDones: [done(1, 'success')],
          ),
        );
      final (out, code) = await runScript([file.path, '--unfinished']);
      expect(code, 0);
      expect(out, isEmpty);
    });

    test('--loaded lists every suite event path (the never-loaded '
        'complement source)', () async {
      final dir = await Directory.systemTemp.createTemp('gate_targets_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/log.json')
        ..writeAsStringSync(abandonedLog());
      final (out, code) = await runScript([file.path, '--loaded']);
      expect(code, 0);
      expect(
        out,
        'test/integration/resume_tail_grid_pty_test.dart\n'
        'test/integration/shell_job_countdown_pty_test.dart\n'
        'test/integration/ssh_shift_gate_test.dart\n',
      );
    });

    test('the DEFAULT projection still reports only failures (the '
        'ci_fast_gate flake-budget contract is unchanged)', () async {
      final dir = await Directory.systemTemp.createTemp('gate_targets_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/log.json')
        ..writeAsStringSync(abandonedLog());
      final (out, code) = await runScript([file.path]);
      expect(code, 0);
      expect(out, isEmpty, reason: 'no failure/error results in this log');
    });

    test('--unfinished with a missing log is a clean empty result', () async {
      final (out, code) = await runScript([
        '/nonexistent/log.json',
        '--unfinished',
      ]);
      expect(code, 0);
      expect(out, isEmpty);
    });
  });
}
