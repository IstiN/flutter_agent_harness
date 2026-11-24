// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// gh-2399: `scripts/merge_dart_json_reports.py` — the healed-shard
/// evidence fold behind `scripts/load_drop_retry.sh`.
///
/// When the load-drop retry wrapper heals a sharded dart test leg (loopback-ws
/// drop #2331 or the engine-abandonment wedge gh-2381), the attempt-1
/// reporter log stays a TRUNCATED stream — the suites the rerun ran exist
/// only in `<retry-log>.rerunK`, which no consumer read. The #928
/// duration-budget gate (pty-coverage-gate) reads the main shard json only
/// and phantom-failed "budgeted suite did not run" on run 45389186796
/// (v1.0.772) for `test/integration/trajectory/cli_integration_test.dart`
/// and `perf_open_gate_test.dart` — both ran GREEN in shard 2/3's rerun.
///
/// The merge script folds attempt-1 + every rerun log into ONE valid
/// dart-json stream: spans deduped per (suite path, test name), the LATEST
/// attempt winning (a re-run file is never double-counted), raw attempt-1
/// preserved by the caller. The end-to-end test below drives the incident
/// shape through the real gate: truncated main → FAIL, merged → OK.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' show max, min;

import 'package:test/test.dart';

const scriptPath = 'scripts/merge_dart_json_reports.py';
const gatePath = 'scripts/check_test_durations.py';
const shardGatePath = 'scripts/check_shard_durations.py';
const junitPath = 'scripts/junit_from_dart_json.py';

/// Minimal dart-json reporter stream: one suite, spans as
/// testStart/testDone pairs (durations in ms), optional trailing `done`.
String report(
  String suitePath,
  List<(String, int, int, String)> spans, {
  bool done = false,
}) {
  final lines = <String>[
    '{"protocolVersion":"0.1.1","type":"start","pid":1,"time":0}',
    '{"type":"suite","suite":{"id":1,"platform":"vm","path":"$suitePath"},"time":0}',
  ];
  var id = 1;
  var lastT1 = 0;
  for (final (name, t0, t1, result) in spans) {
    lines.add(
      '{"type":"testStart","test":{"id":$id,"name":"$name","suiteID":1,'
      '"groupIDs":[],"metadata":{"skip":false}},"time":$t0}',
    );
    lines.add(
      '{"type":"testDone","testID":$id,"result":"$result","hidden":false,'
      '"skipped":false,"time":$t1}',
    );
    id++;
    lastT1 = t1;
  }
  if (done) {
    lines.add('{"type":"done","success":true,"time":$lastT1}');
  }
  return lines.join('\n');
}

Future<(String stdout, int exitCode)> runScript(List<String> args) async {
  final proc = await Process.run('python3', [scriptPath, ...args]);
  return (proc.stdout as String, proc.exitCode);
}

Future<int> runGate(List<String> args) async {
  final proc = await Process.run('python3', [gatePath, ...args]);
  return proc.exitCode;
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('merge_reports_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  Future<String> write(String name, String content) async {
    final file = File('${tmp.path}/$name')..writeAsStringSync(content);
    return file.path;
  }

  test('python3 is available (the wrapper and this file require it)', () {
    final probe = Process.runSync('python3', ['--version']);
    expect(probe.exitCode, 0);
  });

  test('gh-2399 end-to-end: the gate fails on the truncated attempt-1 log '
      'and passes on the merged log — the incident shape', () async {
    // Baseline budgeting one suite (the gh-2399 shape: the trajectory
    // suites). Attempt 1 wedged before the suite ran — its main json has
    // NO span for it; the rerun log has the suite's spans.
    final baseline = await write(
      'baseline.json',
      '{"suites": {"test/integration/trajectory/lost_test.dart": 41.7},'
          '"per_test": {}}',
    );
    final main = await write(
      'main.json',
      report('test/healthy_test.dart', const [
        ('healthy case', 0, 5, 'success'),
      ], done: false), // truncated attempt-1 stream: no done event
    );
    final rerun = await write(
      'retry.json.rerun1',
      report('test/integration/trajectory/lost_test.dart', const [
        ('lost case one', 100, 5000, 'success'),
        ('lost case two', 5100, 7000, 'success'),
      ], done: true),
    );

    // RED-shape proof (run 45389186796): the gate on the RAW attempt-1 log
    // fails exactly like the incident.
    final rawGate = await Process.run('python3', [
      gatePath,
      '--baseline',
      baseline,
      main,
    ]);
    expect(rawGate.exitCode, 1);
    expect(
      rawGate.stdout as String,
      contains(
        'budgeted suite did not run: `test/integration/trajectory/lost_test.dart`',
      ),
    );

    // Fold + gate again: complete evidence, gate OK.
    final merged = '${tmp.path}/main.json.merged';
    final (out, code) = await runScript([merged, main, rerun]);
    expect(code, 0, reason: out);
    final mergedGate = await Process.run('python3', [
      gatePath,
      '--baseline',
      baseline,
      merged,
    ]);
    expect(mergedGate.exitCode, 0, reason: mergedGate.stdout);
    expect(mergedGate.stdout as String, contains('RESULT: OK'));
  });

  test('fold semantics: attempt-1-only suites survive, rerun spans win per '
      '(suite, name), no double counting', () async {
    final main = await write(
      'main.json',
      [
        report('test/healthy_test.dart', const [
          ('healthy case', 0, 5, 'success'),
        ]),
        '',
        report('test/superseded_test.dart', const [
          ('the case', 0, 9000, 'failure'),
        ]),
      ].join('\n'),
    );
    final rerun = await write(
      'rerun.json',
      report('test/superseded_test.dart', const [
        ('the case', 0, 4000, 'success'),
      ], done: true),
    );
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([merged, main, rerun]);
    expect(code, 0, reason: out);

    final text = File(merged).readAsStringSync();
    // Healthy span kept once; superseded suite present with the RERUN span
    // only (4.0 s), the attempt-1 9.0 s span gone — one span per name.
    expect(text, contains('"path":"test/healthy_test.dart"'));
    expect(text, contains('"path":"test/superseded_test.dart"'));
    expect('"the case"'.allMatches(text), hasLength(1));
    final junit = '${tmp.path}/junit.xml';
    final conv = await Process.run('python3', [junitPath, merged, junit]);
    expect(conv.exitCode, 0, reason: conv.stderr);
    final xml = File(junit).readAsStringSync();
    expect(xml, contains('time="4.000"'), reason: 'rerun span wins');
    expect(xml, isNot(contains('time="9.000"')), reason: 'no double count');
    expect(xml, contains('time="0.005"'), reason: 'attempt-1 span survives');
  });

  test('an attempt-1 test that never finished (started, no testDone) is '
      'taken from the rerun — never a torn span', () async {
    final main = await write(
      'main.json',
      [
        '{"protocolVersion":"0.1.1","type":"start","pid":1,"time":0}',
        '{"type":"suite","suite":{"id":1,"platform":"vm","path":"test/inflight_test.dart"},"time":0}',
        '{"type":"testStart","test":{"id":1,"name":"in flight","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":6}',
        '{"type":"allSuites","count":1,"time":12}',
      ].join('\n'),
    );
    final rerun = await write(
      'rerun.json',
      report('test/inflight_test.dart', const [
        ('in flight', 0, 2500, 'success'),
      ], done: true),
    );
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([merged, main, rerun]);
    expect(code, 0, reason: out);
    final junit = '${tmp.path}/junit.xml';
    final conv = await Process.run('python3', [junitPath, merged, junit]);
    expect(conv.exitCode, 0, reason: conv.stderr);
    expect(File(junit).readAsStringSync(), contains('time="2.500"'));
  });

  test('hidden pseudo-tests (loading <path>) never enter the merged stream', () async {
    final main = await write(
      'main.json',
      [
        '{"protocolVersion":"0.1.1","type":"start","pid":1,"time":0}',
        '{"type":"suite","suite":{"id":1,"platform":"vm","path":"test/a_test.dart"},"time":0}',
        '{"type":"testStart","test":{"id":1,"name":"loading test/a_test.dart","suiteID":1},"time":0}',
        '{"type":"testDone","testID":1,"result":"success","hidden":true,"skipped":false,"time":5}',
        '{"type":"testStart","test":{"id":2,"name":"real case","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":6}',
        '{"type":"testDone","testID":2,"result":"success","hidden":false,"skipped":false,"time":10}',
      ].join('\n'),
    );
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([merged, main]);
    expect(code, 0, reason: out);
    final text = File(merged).readAsStringSync();
    expect(text, isNot(contains('loading test/a_test.dart')));
    expect(text, contains('"real case"'));
  });

  test('torn/partial trailing lines and empty rerun logs are tolerated '
      '(a SIGKILLed stream ends mid-line sometimes)', () async {
    final main = await write(
      'main.json',
      '${report('test/a_test.dart', const [('case a', 0, 10, 'success')])}\n'
          '{"type":"testStart","test":{"id":9,"name":"torn case","suiteID":1,"gr',
    );
    final rerun = await write('rerun.json', '');
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([merged, main, rerun]);
    expect(code, 0, reason: out);
    expect(File(merged).readAsStringSync(), contains('"case a"'));
  });

  test('a missing primary log degrades to the rerun evidence (a crash '
      'before the reporter flushed must not lose the rerun spans)', () async {
    final rerun = await write(
      'rerun.json',
      report('test/rebuilt_test.dart', const [
        ('rebuilt case', 0, 1200, 'success'),
      ], done: true),
    );
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([
      merged,
      '${tmp.path}/missing.json',
      rerun,
    ]);
    expect(code, 0, reason: out);
    expect(File(merged).readAsStringSync(), contains('"rebuilt case"'));
  });

  test('a failure that never reran stays failed in the merged stream '
      '(junit keeps the loss loud)', () async {
    final main = await write(
      'main.json',
      report('test/red_test.dart', const [('the red case', 0, 100, 'failure')]),
    );
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([merged, main]);
    expect(code, 0, reason: out);
    final junit = '${tmp.path}/junit.xml';
    final conv = await Process.run('python3', [junitPath, merged, junit]);
    expect(conv.exitCode, 0, reason: conv.stderr);
    expect(File(junit).readAsStringSync(), contains('<failure'));
  });

  test('usage error (no output path) exits 2 with usage on stderr', () async {
    final (_, code) = await runScript([]);
    expect(code, 2);
  });

  test('folded shard wall = the SUM of the attempt walls — the gh-1300 '
      'shard metric stays meaningful, never the span sum', () async {
    // Reviewer fixture shape (PR #2402 thread on
    // merge_dart_json_reports.py:114): attempt-1 spans INTERLEAVED under
    // --concurrency=4 (wall 12.0 s, span-sum 12.85 s) + a rerun with wall
    // 105.0 s / span-sum 198.0 s. The old synthetic sequential clock laid
    // the spans end-to-end, so the merged wall came out as the SPAN SUM
    // (210.85 s) — and check_shard_durations.py measures
    // max(testDone) - min(testStart) over exactly this artifact.
    final main = await write(
      'main.json',
      [
        '{"protocolVersion":"0.1.1","type":"start","pid":1,"time":0}',
        '{"type":"suite","suite":{"id":1,"platform":"vm","path":"test/a_test.dart"},"time":0}',
        '{"type":"testStart","test":{"id":1,"name":"case a","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":100}',
        '{"type":"testStart","test":{"id":2,"name":"case b","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":200}',
        '{"type":"testDone","testID":1,"result":"success","hidden":false,"skipped":false,"time":900}',
        '{"type":"testStart","test":{"id":3,"name":"case c","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":800}',
        '{"type":"testDone","testID":2,"result":"success","hidden":false,"skipped":false,"time":950}',
        '{"type":"testDone","testID":3,"result":"success","hidden":false,"skipped":false,"time":12100}',
      ].join('\n'),
    );
    final rerun = await write(
      'rerun.json',
      [
        '{"protocolVersion":"0.1.1","type":"start","pid":2,"time":0}',
        '{"type":"suite","suite":{"id":1,"platform":"vm","path":"test/b_test.dart"},"time":0}',
        '{"type":"testStart","test":{"id":1,"name":"case d","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":0}',
        '{"type":"testStart","test":{"id":2,"name":"case e","suiteID":1,"groupIDs":[],"metadata":{"skip":false}},"time":500}',
        '{"type":"testDone","testID":1,"result":"success","hidden":false,"skipped":false,"time":105000}',
        '{"type":"testDone","testID":2,"result":"success","hidden":false,"skipped":false,"time":93500}',
      ].join('\n'),
    );
    final merged = '${tmp.path}/merged.json';
    final (out, code) = await runScript([merged, main, rerun]);
    expect(code, 0, reason: out);

    // The gate's own wall formula (check_shard_durations.shard_wall):
    // max(testDone) - min(testStart) over real (paired, non-hidden) spans.
    double wall(String path) {
      final starts = <int, int>{};
      final startTimes = <int>[];
      final doneTimes = <int>[];
      for (final line in File(path).readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final ev = jsonDecode(line) as Map<String, dynamic>;
        if (ev['type'] == 'testStart') {
          starts[(ev['test'] as Map)['id'] as int] = ev['time'] as int;
        } else if (ev['type'] == 'testDone') {
          if (ev['hidden'] == true) continue;
          final t0 = starts.remove(ev['testID']);
          if (t0 == null) continue;
          startTimes.add(t0);
          doneTimes.add(ev['time'] as int);
        }
      }
      return (doneTimes.reduce(max) - startTimes.reduce(min)) / 1000.0;
    }

    expect(
      wall(merged),
      closeTo(117.0, 0.001),
      reason:
          'the merged wall must equal the SUM of the attempt walls '
          '(12.0 + 105.0) — not the span sum (12.85 + 198.0 = 210.85)',
    );
    // Per-test durations are untouched by the clock offset — the junit
    // conversion and the per-suite #928 numbers stay faithful.
    final junit = '${tmp.path}/junit.xml';
    final conv = await Process.run('python3', [junitPath, merged, junit]);
    expect(conv.exitCode, 0, reason: conv.stderr);
    final xml = File(junit).readAsStringSync();
    expect(xml, contains('time="105.000"'), reason: 'rerun case d');
    expect(xml, contains('time="11.300"'), reason: 'attempt-1 case c');

    // End-to-end through the REAL gh-1300 gate: a 150 s budget fits the
    // summed attempt walls (117 s) but not the span-sum wall (210.85 s)
    // the old fold produced.
    final budgets = await write(
      'budgets.json',
      '{"_meta":{},"warn_fraction":0.9,"shards":{"merged":150.0}}',
    );
    final shardGate = await Process.run('python3', [
      shardGatePath,
      '--budgets',
      budgets,
      merged,
    ]);
    expect(shardGate.exitCode, 0, reason: shardGate.stdout as String);
    expect(shardGate.stdout as String, contains('RESULT: OK'));
  });

  test(
    'the span walk is the SHARED junit_from_dart_json walk — no '
    'duplicated parser to drift (#194/#928 fixes must reach the fold)',
    () async {
      final probe = await Process.run('python3', [
        '-c',
        'import sys; sys.path.insert(0, "scripts");\n'
            'import merge_dart_json_reports as m;\n'
            'seen = []\n'
            'def spy(path):\n'
            '    seen.append(path)\n'
            '    yield from ()\n'
            'm.iter_test_events = spy\n'
            'assert m.spans_from_log("scripts/junit_from_dart_json.py") == ([], 0)\n'
            'assert seen == ["scripts/junit_from_dart_json.py"], "merge must '
            'delegate the span walk to junit_from_dart_json.iter_test_events"\n',
      ]);
      expect(probe.exitCode, 0, reason: probe.stderr as String);
    },
  );
}
