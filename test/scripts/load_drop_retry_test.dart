// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #2331: `scripts/load_drop_retry.sh` — the one-shot loopback-ws
/// load-drop retry behind the sharded dart test legs.
///
/// Under CI-leg load the dart test loader's loopback WebSocket to a freshly
/// spawned test VM dies mid-handshake (`Failed to load "x_test.dart": Connection closed before full header was received` /
/// `Connection reset by peer, uri=http://127.0.0.1:…/ws`). The victim file is arbitrary, never an
/// assertion failure (6/6 occurrences). The wrapper must:
///   - rerun at all ONLY on that signature (no signature → no rerun, loud);
///   - rerun the FULL attempt-1 failed inventory ONCE — the ws-dropped
///     files PLUS every failed suite the attempt-1 reporter log records
///     (`gate_failed_targets.py`) — so a healed rerun can never mask a
///     co-occurring real failure (PR #2347 review round 1, blocking):
///     assertion failure + drop → the rerun includes the failing suite and
///     the shard stays red;
///   - never rerun blind (signature without any failed-file inventory);
///   - point the rerun's --file-reporter at the retry log while the main
///     log keeps its attempt-1 evidence for junit/duration consumers.
/// Fixture-tested here with a stubbed runner — no CI, no real dart test.
library;

import 'dart:io';
import 'package:test/test.dart';

const scriptPath = 'scripts/load_drop_retry.sh';

/// The two loader-drop shapes observed on issue #2331 (occ1/occ5 = reset,
/// occ2/occ3/occ4/occ6 = closed-header; both `uri` spellings appear).
const droppedClosedHeader =
    'Failed to load "test/cli/dropped_test.dart": Connection closed before full header was received, uri = http://127.0.0.1:42491/as8k8g_yb50=/ws';
const droppedConnReset =
    'Failed to load "test/cli/wire_serve_test.dart": Connection reset by peer, uri=http://127.0.0.1:46295/x/ws';

/// Minimal dart-json file-reporter fixture: one real suite with one failing
/// test (resolved via the suite map) and one hidden `loading <path>` error
/// (load failure, resolved from the name — no suite event, the real dart
/// shape for a file that never loaded).
String reporterFixture({
  required String failingSuitePath,
  required String failingCase,
  String? loadingPath,
}) => [
  '{"type":"suite","suite":{"id":7,"path":"$failingSuitePath","platform":"vm"}}',
  if (loadingPath != null)
    '{"type":"testStart","test":{"id":70,"name":"loading $loadingPath","suiteID":99},"time":0}',
  if (loadingPath != null)
    '{"type":"testDone","testID":70,"result":"error","hidden":true,"time":5}',
  '{"type":"testStart","test":{"id":71,"name":"$failingCase","suiteID":7},"time":6}',
  '{"type":"testDone","testID":71,"result":"failure","time":10}',
  '{"type":"done","success":false}',
].join('\n');

/// Stub runner. Attempt 1 prints the MODE's failure output (and, for the
/// reporter-fixture modes, writes the dart-json log the wrapper's
/// --file-reporter flag points at); the rerun (attempt 2) fails iff a
/// deterministic failure file appears in its targets — modeling that real
/// failures fail again — else passes (a pure ws drop heals).
String stubRunner(String tmp) =>
    '''
#!/usr/bin/env bash
main=''
for a in "\$@"; do
  case "\$a" in --file-reporter=json:*) main="\${a#--file-reporter=json:}" ;; esac
done
echo "\$*" >> "$tmp/argv.log"
if [ -f "$tmp/attempt2" ]; then
  case "\$MODE" in
    drop-always|wedge-abandon-rerun-red)
      echo '$droppedClosedHeader'
      exit 1 ;;
  esac
  case "\$*" in
    *b_two_test*|*ok_test*|*rep_only_test*) exit 1 ;;
  esac
  exit 0
fi
touch "$tmp/attempt2"
case "\$MODE" in
  ok) exit 0 ;;
  drop-closed-header)
    echo '$droppedClosedHeader'
    exit 1 ;;
  drop-conn-reset)
    echo '$droppedConnReset'
    exit 1 ;;
  drop-always)
    echo '$droppedClosedHeader'
    exit 1 ;;
  assert-fail)
    echo '[E] Expected: true'
    echo '  Actual: false'
    exit 1 ;;
  ws-no-path)
    echo 'socket error: Connection reset by peer'
    exit 1 ;;
  drop-two-plus-compile-error)
    printf '%s\n' '${reporterFixture(failingSuitePath: "test/b_two_test.dart", failingCase: "loading test/b_two_test.dart", loadingPath: "test/b_two_test.dart")}' > "\$main"
    echo 'Failed to load "test/a_one_test.dart": Connection closed before full header was received, uri = http://127.0.0.1:1/a/ws'
    echo 'Failed to load "test/b_two_test.dart": Error: Compilation failed'
    echo 'Failed to load "test/c_three_test.dart": Connection reset by peer, uri=http://127.0.0.1:2/b/ws'
    exit 1 ;;
  assert-fail-plus-drop)
    printf '%s\n' '${reporterFixture(failingSuitePath: "test/cli/ok_test.dart", failingCase: "the real case", loadingPath: "test/cli/dropped_test.dart")}' > "\$main"
    echo '00:01 +0 -1: test/cli/ok_test.dart [E]'
    echo '  Expected: true'
    echo '   Actual: false'
    echo '$droppedClosedHeader'
    exit 1 ;;
  rep-only-union)
    printf '%s\n' '${reporterFixture(failingSuitePath: "test/rep_only_test.dart", failingCase: "reporter-only failure", loadingPath: "test/cli/dropped_test.dart")}' > "\$main"
    echo '$droppedClosedHeader'
    exit 1 ;;
  wedge-abandon|wedge-abandon-rerun-red)
    printf '%s\n' '{"type":"suite","suite":{"id":1,"path":"test/healthy_test.dart","platform":"vm"}}' > "\$main"
    printf '%s\n' '{"type":"suite","suite":{"id":2,"path":"test/countdown_test.dart","platform":"vm"}}' >> "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":10,"name":"healthy case","suiteID":1,"groupIDs":[]},"time":0}' >> "\$main"
    printf '%s\n' '{"type":"testDone","testID":10,"result":"success","hidden":false,"skipped":false,"time":5}' >> "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":11,"name":"ten jobs","suiteID":2,"groupIDs":[]},"time":6}' >> "\$main"
    printf '%s\n' '{"type":"allSuites","count":3,"time":12}' >> "\$main"
    printf '%s\n' '{"type":"done","success":true}' >> "\$main"
    echo 'Attempt:1 waiting for isolate _waitForExitCode to check in'
    echo 'Attempt:2 waiting for isolate _waitForExitCode to check in'
    echo 'Attempt:3 waiting for isolate _waitForExitCode to check in'
    sleep 300
    exit 0 ;;
  unfinished-exit70)
    printf '%s\n' '{"type":"suite","suite":{"id":3,"path":"test/inflight_test.dart","platform":"vm"}}' > "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":20,"name":"in flight","suiteID":3,"groupIDs":[]},"time":0}' >> "\$main"
    printf '%s\n' '{"type":"allSuites","count":1,"time":1}' >> "\$main"
    printf '%s\n' '{"type":"done","success":false}' >> "\$main"
    exit 70 ;;
  never-loaded-only)
    printf '%s\n' '{"type":"suite","suite":{"id":4,"path":"test/healthy_test.dart","platform":"vm"}}' > "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":30,"name":"healthy","suiteID":4,"groupIDs":[]},"time":0}' >> "\$main"
    printf '%s\n' '{"type":"testDone","testID":30,"result":"success","hidden":false,"skipped":false,"time":5}' >> "\$main"
    printf '%s\n' '{"type":"allSuites","count":2,"time":6}' >> "\$main"
    printf '%s\n' '{"type":"done","success":true}' >> "\$main"
    exit 0 ;;
  *) echo "unknown MODE \$MODE" >&2; exit 3 ;;
esac
''';

Future<ProcessResult> runWrapper(
  String tmp, {
  required String mode,
  String targets = 'test/cli/first_test.dart test/cli/second_test.dart',
}) async {
  final stub = File('$tmp/stub_runner.sh')..writeAsStringSync(stubRunner(tmp));
  return Process.run(
    'bash',
    [
      scriptPath,
      '$tmp/main.json',
      '$tmp/retry.json',
      '--',
      'bash',
      stub.path,
      '--exclude-tags',
      'integration',
      '--concurrency=4',
      '--file-reporter=json:$tmp/main.json',
      targets,
    ],
    environment: {
      'MODE': mode,
      // Bounded spam budget: the wedge modes emit 3 lines; the real default
      // budget is only relevant on a genuine 1/s VM-exit spam.
      'LOAD_DROP_RETRY_SPAM_LIMIT': '2',
    },
  );
}

List<String> invocations(String tmp) => File('$tmp/argv.log').readAsLinesSync();

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('load_drop_retry_test');
    File('${tmp.path}/argv.log').writeAsStringSync('');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('AC1 green run passes through with a single invocation', () async {
    final r = await runWrapper(tmp.path, mode: 'ok');
    expect(r.exitCode, 0);
    expect(invocations(tmp.path), hasLength(1));
  });

  test('AC2 closed-header drop heals: rerun runs ONLY the dropped file once, '
      'retry reporter replaces the main reporter, flags preserved', () async {
    final r = await runWrapper(tmp.path, mode: 'drop-closed-header');
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(r.stderr, contains('healed'));
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    // Rerun argv: the dropped file ONLY — the healthy target from attempt 1
    // must not re-run. (The stub writes no reporter log, so this also pins
    // the console-derived fallback when the attempt-1 log is absent.)
    expect(
      calls[1],
      contains('test/cli/dropped_test.dart'),
      reason: 'rerun must target the dropped file',
    );
    expect(
      calls[1],
      isNot(contains('test/cli/first_test.dart')),
      reason: 'rerun must NOT re-run healthy files',
    );
    expect(calls[1], contains('--file-reporter=json:${tmp.path}/retry.json'));
    expect(
      calls[1],
      isNot(contains('--file-reporter=json:${tmp.path}/main.json')),
      reason: 'the rerun must never clobber the main reporter log',
    );
    expect(calls[1], contains('--concurrency=4'));
    expect(calls[1], contains('--exclude-tags integration'));
  });

  test('AC3 conn-reset drop heals too (both observed signatures)', () async {
    final r = await runWrapper(tmp.path, mode: 'drop-conn-reset');
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(invocations(tmp.path), hasLength(2));
  });

  test(
    'AC4 a real assertion failure alone never reruns — stays loud',
    () async {
      final r = await runWrapper(tmp.path, mode: 'assert-fail');
      expect(r.exitCode, isNot(0));
      expect(r.stdout, contains('Expected: true'));
      expect(invocations(tmp.path), hasLength(1));
    },
  );

  test(
    'AC5 ws signature without a failed-file inventory never reruns blind',
    () async {
      final r = await runWrapper(tmp.path, mode: 'ws-no-path');
      expect(r.exitCode, isNot(0));
      expect(invocations(tmp.path), hasLength(1));
    },
  );

  test('AC6 a rerun that drops/fails again exits with its code — one retry, '
      'never a loop', () async {
    final r = await runWrapper(tmp.path, mode: 'drop-always');
    expect(r.exitCode, isNot(0));
    expect(invocations(tmp.path), hasLength(2), reason: 'exactly one rerun');
  });

  test('AC7 co-occurring compile-error load failure joins the rerun and '
      'keeps the shard red (review round 1, blocking variant 2)', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'drop-two-plus-compile-error',
      targets:
          'test/a_one_test.dart test/b_two_test.dart test/c_three_test.dart',
    );
    // Precise targeting is not enough: a deterministic compile-error load
    // failure from attempt 1 must be IN the rerun and fail it again.
    expect(r.exitCode, isNot(0), reason: 'stderr: ${r.stderr}');
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    expect(calls[1], contains('test/a_one_test.dart'));
    expect(calls[1], contains('test/c_three_test.dart'));
    expect(
      calls[1],
      contains('test/b_two_test.dart'),
      reason:
          'the compile-error file comes from the attempt-1 reporter log '
          '(gate_failed_targets.py) — the rerun must include it',
    );
  });

  test(
    'AC8 assertion failure + ws drop in one run: rerun includes the '
    'failing suite, shard stays RED (review round 1, blocking variant 1)',
    () async {
      final r = await runWrapper(tmp.path, mode: 'assert-fail-plus-drop');
      expect(r.exitCode, isNot(0), reason: 'stderr: ${r.stderr}');
      final calls = invocations(tmp.path);
      expect(calls, hasLength(2));
      expect(
        calls[1],
        contains('test/cli/ok_test.dart'),
        reason:
            'the genuinely failing suite must rerun — a healed dropped '
            'file alone must never green-light the shard',
      );
      expect(calls[1], contains('test/cli/dropped_test.dart'));
    },
  );

  test('AC9 the rerun inventory unions both sources: a reporter-only failed '
      'suite rides along with the console-derived dropped file', () async {
    final r = await runWrapper(tmp.path, mode: 'rep-only-union');
    expect(r.exitCode, isNot(0), reason: 'stderr: ${r.stderr}');
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    expect(
      calls[1],
      contains('test/rep_only_test.dart'),
      reason:
          'failed suite present ONLY in the attempt-1 reporter log '
          '(gate_failed_targets.py) must join the rerun',
    );
    expect(
      calls[1],
      contains('test/cli/dropped_test.dart'),
      reason: 'console-derived ws drop stays a rerun target',
    );
  });

  // ── gh-2381: the engine-abandonment wedge (run 45200064457, shard 2/3).
  //    The coverage-gather crash killed Engine.run() mid-queue: three tests
  //    in flight (their tearDowns never ran — live pty2 children), ten
  //    queued suites never loaded, and the process hung forever at exit
  //    (`Attempt:N waiting for isolate _waitForExitCode to check in`,
  //    40-minute timeout-kill, shard conclusion `cancelled`). The wrapper
  //    must (a) SIGKILL the wedged runner once the exit-handshake spam is
  //    sustained — the evidence is already in the reporter — and (b) rerun
  //    the abandoned inventory ONCE so the shard heals green instead of
  //    burning the budget.
  test('AC10 the exit-handshake wedge is killed and the abandoned '
      'inventory reruns once (heals)', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'wedge-abandon',
      targets:
          'test/healthy_test.dart test/countdown_test.dart test/never_loaded_test.dart',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(
      r.stderr,
      contains('exit-handshake'),
      reason: 'the wedge kill is named loudly in the leg log',
    );
    expect(r.stderr, contains('healed'));
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2), reason: 'exactly one rerun');
    // The abandoned inventory: the in-flight suites + the never-loaded
    // invocation targets; healthy completed suites never rerun.
    expect(calls[1], contains('test/countdown_test.dart'));
    expect(calls[1], contains('test/never_loaded_test.dart'));
    expect(
      calls[1],
      isNot(contains('test/healthy_test.dart')),
      reason: 'the suite that finished its tests is done',
    );
    expect(calls[1], contains('--file-reporter=json:${tmp.path}/retry.json'));
  });

  test('AC11 the wedge rerun that fails again stays red — one retry, '
      'never a loop', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'wedge-abandon-rerun-red',
      targets:
          'test/healthy_test.dart test/countdown_test.dart test/never_loaded_test.dart',
    );
    expect(r.exitCode, isNot(0), reason: 'stderr: ${r.stderr}');
    expect(invocations(tmp.path), hasLength(2));
  });

  test('AC12 unfinished tests alone (no spam, non-zero exit) trigger the '
      'abandonment rerun', () async {
    final r = await runWrapper(tmp.path, mode: 'unfinished-exit70');
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(invocations(tmp.path), hasLength(2));
    expect(invocations(tmp.path)[1], contains('test/inflight_test.dart'));
  });

  test('AC13 never-loaded targets alone (a planned suite with no suite '
      'event and no results) trigger the abandonment rerun', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'never-loaded-only',
      targets: 'test/healthy_test.dart test/never_loaded_test.dart',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    expect(calls[1], contains('test/never_loaded_test.dart'));
    expect(calls[1], isNot(contains('test/healthy_test.dart')));
  });
}
