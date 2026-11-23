// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #2331: `scripts/load_drop_retry.sh` — the bounded loopback-ws
/// load-drop retry behind the sharded dart test legs.
///
/// Under CI-leg load the dart test loader's loopback WebSocket to a freshly
/// spawned test VM dies mid-handshake (`Failed to load "x_test.dart": Connection closed before full header was received` /
/// `Connection reset by peer, uri=http://127.0.0.1:…/ws`). The victim file is arbitrary, never an
/// assertion failure (10/10 occurrences on the card). The wrapper must:
///   - rerun at all ONLY on that signature (no signature → no rerun, loud);
///   - rerun the FULL failed inventory of the failing attempt — the
///     ws-dropped files PLUS every failed suite the attempt's reporter log
///     records (`gate_failed_targets.py`) — so a healed rerun can never
///     mask a co-occurring real failure (PR #2347 review round 1,
///     blocking): assertion failure + drop → the rerun includes the
///     failing suite and the shard stays red;
///   - never rerun blind (signature without any failed-file inventory);
///   - retry with BOUND: each red attempt whose OWN output carries the
///     signature buys one more rerun of that attempt's inventory, up to
///     `$LOAD_DROP_RETRY_MAX_RERUNS` (default 2), with a drain backoff
///     before each rerun (`$LOAD_DROP_RETRY_BACKOFF_S`, default 5 s,
///     doubling per rerun) — detection reads the failing attempt's own
///     console segment, so a healed file's old signature line can never
///     re-arm the loop;
///   - point each rerun's --file-reporter at `<retry-log>.rerunK` while
///     the main log keeps attempt-1 evidence for junit/duration consumers.
/// Fixture-tested here with a stubbed runner — no CI, no real dart test.
///
/// gh-2381 (merged on top of the #2379 bounded loop) extends the same
/// discipline to the engine-abandonment wedge (run 45200064457, PTY shard
/// 2/3): a coverage-gather crash kills the test_core engine mid-queue —
/// tests left IN FLIGHT (tearDowns never run → live pty2 children → the
/// `Attempt:N waiting for isolate _waitForExitCode` exit-handshake wedge,
/// whole 40-minute budget burned, job concluded `cancelled`) and whole
/// suites never loaded (allSuites 26 planned, 16 loaded). The wrapper now
///   - SIGKILLs the wedged runner's process group on sustained
///     `Attempt:N waiting for isolate` spam counted over THIS attempt's
///     fresh console bytes (AC24: a rerun sharing the console is never
///     insta-killed by attempt-1 spam) — never again a 40-minute burn;
///   - treats unfinished tests and never-loaded invocation targets as
///     transient losses in the SAME bounded rerun inventory (AC20-AC23),
///     so the leg heals green; the projections are trusted ONLY when the
///     attempt's reporter log exists (a missing log never widens the
///     inventory);
///   - keeps real assertion failures loud — they join the rerun and fail
///     it again (AC21), never masked by a healed transient.
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

/// Stub runner. Invocation 1 prints the MODE's failure output (and, for the
/// reporter-fixture modes, writes the dart-json log the wrapper's
/// --file-reporter flag points at); each later invocation (a rerun) behaves
/// per MODE: real-failure files fail again, pure ws drops heal, and the
/// chained modes model a SECOND drop of a different file / a real failure
/// surfacing in the rerun.
String stubRunner(String tmp) =>
    '''
#!/usr/bin/env bash
C=\$(cat "$tmp/runcount" 2>/dev/null || echo 0)
N=\$((C + 1))
echo "\$N" > "$tmp/runcount"
main=''
for a in "\$@"; do
  case "\$a" in --file-reporter=json:*) main="\${a#--file-reporter=json:}" ;; esac
done
echo "\$*" >> "$tmp/argv.log"
if [ "\$N" -ge 2 ]; then
  case "\$MODE" in
    wedge-abandon-rerun-red)
      echo '$droppedClosedHeader'
      exit 1 ;;
    wedge-slow-rerun)
      # gh-2381 AC24: the rerun writes its retry reporter BEFORE exiting —
      # a slow enough start that a stale-spam watchdog poll would land
      # mid-run (the whole-console spam count insta-killed a healthy
      # rerun; the per-run baseline must not).
      printf '%s\n' '{"type":"done","success":true}' > "\$main"
      sleep 2
      exit 0 ;;
    drop-then-drop-other)
      if [ "\$N" -eq 2 ]; then
        echo 'Failed to load "test/cli/b_drop_test.dart": Connection reset by peer, uri=http://127.0.0.1:3/c/ws'
        exit 1
      fi
      exit 0 ;;
    drop-then-assert)
      echo '[E] Expected: true'
      echo '  Actual: false'
      exit 1 ;;
    backoff-drop-once) exit 0 ;;
    drop-always)
      echo '$droppedClosedHeader'
      exit 1 ;;
  esac
  case "\$*" in
    *b_two_test*|*ok_test*|*rep_only_test*) exit 1 ;;
  esac
  exit 0
fi
case "\$MODE" in
  ok) exit 0 ;;
  slow-ok)
    # gh-2381 review round 2 (AC25): a HEALTHY run whose whole duration
    # the exit-handshake watchdog lives through — the wrapper tree must
    # spend near-zero CPU waiting (the watchdog poll timer must block,
    # never busy-spin).
    sleep 3
    exit 0 ;;
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
    printf '%s\\n' '${reporterFixture(failingSuitePath: "test/b_two_test.dart", failingCase: "loading test/b_two_test.dart", loadingPath: "test/b_two_test.dart")}' > "\$main"
    echo 'Failed to load "test/a_one_test.dart": Connection closed before full header was received, uri = http://127.0.0.1:1/a/ws'
    echo 'Failed to load "test/b_two_test.dart": Error: Compilation failed'
    echo 'Failed to load "test/c_three_test.dart": Connection reset by peer, uri=http://127.0.0.1:2/b/ws'
    exit 1 ;;
  assert-fail-plus-drop)
    printf '%s\\n' '${reporterFixture(failingSuitePath: "test/cli/ok_test.dart", failingCase: "the real case", loadingPath: "test/cli/dropped_test.dart")}' > "\$main"
    echo '00:01 +0 -1: test/cli/ok_test.dart [E]'
    echo '  Expected: true'
    echo '   Actual: false'
    echo '$droppedClosedHeader'
    exit 1 ;;
  rep-only-union)
    printf '%s\\n' '${reporterFixture(failingSuitePath: "test/rep_only_test.dart", failingCase: "reporter-only failure", loadingPath: "test/cli/dropped_test.dart")}' > "\$main"
    echo '$droppedClosedHeader'
    exit 1 ;;
  drop-then-drop-other)
    echo 'Failed to load "test/cli/a_drop_test.dart": Connection closed before full header was received, uri = http://127.0.0.1:4/d/ws'
    exit 1 ;;
  drop-then-assert)
    echo 'Failed to load "test/cli/a_drop_test.dart": Connection closed before full header was received, uri = http://127.0.0.1:5/e/ws'
    exit 1 ;;
  backoff-drop-once)
    echo 'Failed to load "test/cli/a_drop_test.dart": Connection reset by peer, uri=http://127.0.0.1:6/f/ws'
    exit 1 ;;
  wedge-abandon|wedge-abandon-rerun-red)
    # gh-2381 AC20/AC21: the engine-abandonment wedge — the reporter
    # records healthy + a suite whose test STARTED but never finished,
    # then sustained exit-handshake spam and the process never exits.
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
  wedge-slow-rerun)
    printf '%s\n' '{"type":"suite","suite":{"id":1,"path":"test/healthy_test.dart","platform":"vm"}}' > "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":10,"name":"healthy case","suiteID":1,"groupIDs":[]},"time":0}' >> "\$main"
    printf '%s\n' '{"type":"testDone","testID":10,"result":"success","hidden":false,"skipped":false,"time":5}' >> "\$main"
    printf '%s\n' '{"type":"done","success":true}' >> "\$main"
    echo 'Attempt:1 waiting for isolate _waitForExitCode to check in'
    echo 'Attempt:2 waiting for isolate _waitForExitCode to check in'
    echo 'Attempt:3 waiting for isolate _waitForExitCode to check in'
    sleep 300
    exit 0 ;;
  unfinished-exit70)
    # gh-2381 AC22: the engine died mid-queue (coverage-gather crash) but
    # the process EXITED (no pty2 children to wedge the handshake) — the
    # reporter shows a test started, never finished, exit 70 (software).
    printf '%s\n' '{"type":"suite","suite":{"id":3,"path":"test/inflight_test.dart","platform":"vm"}}' > "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":20,"name":"in flight","suiteID":3,"groupIDs":[]},"time":0}' >> "\$main"
    printf '%s\n' '{"type":"allSuites","count":1,"time":1}' >> "\$main"
    printf '%s\n' '{"type":"done","success":false}' >> "\$main"
    exit 70 ;;
  never-loaded-exit70)
    # gh-2381 AC23: whole suites never loaded — the invocation planned
    # them, the reporter has a suite event for the healthy one only.
    printf '%s\n' '{"type":"suite","suite":{"id":4,"path":"test/healthy_test.dart","platform":"vm"}}' > "\$main"
    printf '%s\n' '{"type":"testStart","test":{"id":30,"name":"healthy","suiteID":4,"groupIDs":[]},"time":0}' >> "\$main"
    printf '%s\n' '{"type":"testDone","testID":30,"result":"success","hidden":false,"skipped":false,"time":5}' >> "\$main"
    printf '%s\n' '{"type":"allSuites","count":2,"time":6}' >> "\$main"
    printf '%s\n' '{"type":"done","success":false}' >> "\$main"
    exit 70 ;;
  *) echo "unknown MODE \$MODE" >&2; exit 3 ;;
esac
''';

Future<ProcessResult> runWrapper(
  String tmp, {
  required String mode,
  String targets = 'test/cli/first_test.dart test/cli/second_test.dart',
  Map<String, String> env = const {},
  String? pathPrefix,
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
      // Backoff off by default — the ladder itself is pinned by AC12
      // through a stubbed `sleep`, never by wall-clock waits.
      'LOAD_DROP_RETRY_BACKOFF_S': '0',
      ...env,
      if (pathPrefix != null)
        'PATH': '$pathPrefix:${Platform.environment['PATH']}',
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

  test('AC6 a drop-always runner reds after MAX_RERUNS reruns — bounded, '
      'never an unbounded loop, exit code preserved', () async {
    final r = await runWrapper(tmp.path, mode: 'drop-always');
    expect(r.exitCode, 1, reason: 'the last attempt\'s exit code surfaces');
    expect(r.stderr, contains('still red after 2 rerun'));
    expect(invocations(tmp.path), hasLength(3), reason: '1 + MAX_RERUNS');
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

  test('AC10 a chained drop heals across attempts: rerun 1 drops a DIFFERENT '
      'file, rerun 2 targets only that file and heals', () async {
    final r = await runWrapper(tmp.path, mode: 'drop-then-drop-other');
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(r.stderr, contains('healed'));
    expect(r.stderr, contains('rerun 2/2'));
    final calls = invocations(tmp.path);
    expect(calls, hasLength(3));
    expect(
      calls[1],
      contains('test/cli/a_drop_test.dart'),
      reason: 'rerun 1 targets attempt-1\'s dropped file',
    );
    expect(calls[1], isNot(contains('test/cli/b_drop_test.dart')));
    expect(
      calls[2],
      contains('test/cli/b_drop_test.dart'),
      reason:
          'rerun 2 targets the file rerun 1 dropped — detected from '
          'rerun 1\'s OWN console segment',
    );
    expect(
      calls[2],
      isNot(contains('test/cli/a_drop_test.dart')),
      reason:
          'per-attempt detection: attempt-1\'s healed signature line must '
          'never re-arm the loop or re-run its file',
    );
    expect(
      calls[2],
      contains('--file-reporter=json:${tmp.path}/retry.json.rerun2'),
      reason: 'each rerun writes its own evidence log',
    );
  });

  test('AC11 a red rerun WITHOUT the signature stops the loop — real '
      'failures in a rerun stay loud and buy no extra attempts', () async {
    final r = await runWrapper(tmp.path, mode: 'drop-then-assert');
    expect(r.exitCode, 1);
    expect(r.stderr, contains('no loopback-ws drop signature'));
    expect(invocations(tmp.path), hasLength(2));
  });

  test('AC12 the drain backoff waits before each rerun and doubles — '
      'observable via the sleep invocations', () async {
    Directory('${tmp.path}/bin').createSync();
    File('${tmp.path}/bin/sleep').writeAsStringSync(
      '#!/usr/bin/env bash\necho "\$*" >> ${tmp.path}/sleep.log\n',
    );
    Process.runSync('chmod', ['755', '${tmp.path}/bin/sleep']);
    final r = await runWrapper(
      tmp.path,
      mode: 'drop-then-drop-other',
      env: {'LOAD_DROP_RETRY_BACKOFF_S': '7'},
      pathPrefix: '${tmp.path}/bin',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(
      File('${tmp.path}/sleep.log').readAsLinesSync(),
      ['7', '14'],
      reason:
          'one sleep before the rerun (7s), doubling on a second '
          'rerun (14s) — the drain ladder',
    );
  });

  test(
    'AC13 non-integer retry knobs fall back to the documented defaults',
    () async {
      for (final invalid in ['5s', 'abc']) {
        final caseDir = Directory('${tmp.path}/knobs-$invalid')..createSync();
        Directory('${caseDir.path}/bin').createSync();
        File('${caseDir.path}/bin/sleep').writeAsStringSync(
          '#!/usr/bin/env bash\necho "\$*" >> ${caseDir.path}/sleep.log\n',
        );
        Process.runSync('chmod', ['755', '${caseDir.path}/bin/sleep']);
        final r = await runWrapper(
          caseDir.path,
          mode: 'drop-then-drop-other',
          env: {
            'LOAD_DROP_RETRY_BACKOFF_S': invalid,
            'LOAD_DROP_RETRY_MAX_RERUNS': invalid,
          },
          pathPrefix: '${caseDir.path}/bin',
        );
        expect(
          r.exitCode,
          0,
          reason: 'knobs=$invalid must not disable healing: ${r.stderr}',
        );
        expect(r.stderr, contains('rerun 2/2'));
        expect(invocations(caseDir.path), hasLength(3));
        expect(File('${caseDir.path}/sleep.log').readAsLinesSync(), [
          '5',
          '10',
        ], reason: 'knobs=$invalid uses BACKOFF=5 and doubles it normally');
      }
    },
  );

  // ── gh-2381: the engine-abandonment wedge (run 45200064457, PTY shard
  //    2/3). A coverage-gather crash killed Engine.run() mid-queue: three
  //    tests in flight (their tearDowns never ran — live pty2 children),
  //    ten queued suites never loaded, and the process hung forever at
  //    exit (`Attempt:N waiting for isolate _waitForExitCode to check in`,
  //    40-minute timeout-kill, shard conclusion `cancelled`). The wrapper
  //    must (a) SIGKILL the wedged runner's process group once the
  //    exit-handshake spam is sustained on the attempt's OWN fresh console
  //    output — the evidence is already in the reporter — and (b) treat
  //    the abandoned inventory (unfinished tests + never-loaded targets)
  //    as transient losses in the same bounded rerun budget so the leg
  //    HEALS green instead of burning the shard.
  test('AC20 the exit-handshake wedge is killed and the abandoned '
      'inventory reruns once (heals)', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'wedge-abandon',
      targets:
          'test/healthy_test.dart test/countdown_test.dart test/never_loaded_test.dart',
      env: {'LOAD_DROP_RETRY_SPAM_LIMIT': '2'},
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    expect(r.stderr, contains('exit-handshake wedge'));
    expect(r.stderr, contains('healed'));
    expect(
      RegExp('exit-handshake wedge').allMatches(r.stderr.toString()),
      hasLength(1),
      reason: 'exactly ONE wedge kill — attempt 1 only',
    );
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2), reason: 'exactly one rerun');
    expect(calls[1], contains('test/countdown_test.dart'));
    expect(calls[1], contains('test/never_loaded_test.dart'));
    expect(
      calls[1],
      isNot(contains('test/healthy_test.dart')),
      reason: 'the suite that finished its tests is done',
    );
    expect(calls[1], contains('--file-reporter=json:${tmp.path}/retry.json'));
    expect(
      calls[1],
      isNot(contains('--file-reporter=json:${tmp.path}/main.json')),
    );
  });

  test('AC21 the wedge rerun that fails again stays red — bounded, never '
      'masked by a healed transient', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'wedge-abandon-rerun-red',
      targets:
          'test/healthy_test.dart test/countdown_test.dart test/never_loaded_test.dart',
      env: {
        'LOAD_DROP_RETRY_SPAM_LIMIT': '2',
        'LOAD_DROP_RETRY_MAX_RERUNS': '1',
      },
    );
    expect(r.exitCode, isNot(0), reason: 'stderr: ${r.stderr}');
    expect(r.stderr, contains('still red'));
    expect(invocations(tmp.path), hasLength(2));
  });

  test('AC22 unfinished tests alone (started, never finished, exit 70) '
      'trigger the abandonment rerun', () async {
    // Targets-consistent fixture (review round 2 digest): the in-flight
    // suite IS an invocation target — real in-flight suites always are.
    // The suite is loaded (a suite event exists), so the never-loaded
    // complement is empty and the rerun triggers on the --unfinished
    // projection ALONE.
    final r = await runWrapper(
      tmp.path,
      mode: 'unfinished-exit70',
      targets: 'test/inflight_test.dart',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    expect(calls[1], contains('test/inflight_test.dart'));
  });

  test('AC23 never-loaded targets (a planned suite with no suite event) '
      'join the abandonment rerun', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'never-loaded-exit70',
      targets: 'test/healthy_test.dart test/never_loaded_test.dart',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    expect(calls[1], contains('test/never_loaded_test.dart'));
    expect(calls[1], isNot(contains('test/healthy_test.dart')));
  });

  test('AC24 the rerun is never insta-killed by attempt-1 spam already in '
      'the shared console (the --append baseline)', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'wedge-slow-rerun',
      env: {'LOAD_DROP_RETRY_SPAM_LIMIT': '2'},
    );
    final stderrText = r.stderr.toString();
    expect(r.exitCode, 0, reason: 'stderr: $stderrText');
    expect(stderrText, contains('healed'));
    expect(
      RegExp('exit-handshake wedge').allMatches(stderrText),
      hasLength(1),
      reason: 'exactly ONE wedge kill — attempt 1 only',
    );
    expect(invocations(tmp.path), hasLength(2));
  });

  test(
    'AC25 the watchdog poll timer never busy-spins: a healthy 3s run '
    'consumes near-zero wrapper-tree CPU and leaks no redirect error',
    () async {
      // gh-2381 review round 2 (IMPORTANT, both rounds): the watchdog's
      // `read -t 1 -u 3` timer read /dev/zero, which never blocks — the
      // builtin looped on instant read() syscalls for the attempt's whole
      // lifetime, pinning ~1 core (measured 3.21 CPU-s over a 3 s wall run
      // on the round-2 head). The timer must BLOCK: a healthy run's
      // wrapper tree (bash + watchdog subshell + tail/grep polls) spends
      // near-zero CPU while the runner sleeps. Measured with
      // /usr/bin/time over the wrapper process tree (user + sys, children
      // reaped before the wrapper exits — the watchdog subshell is killed
      // and reaped by then). The same fresh-invocation run also pins the
      // round-2 digest stderr leak: the spam baseline is computed before
      // tee starts, so `wc -c <` never hits a not-yet-created console.
      if (!File('/usr/bin/time').existsSync()) {
        return; // no measurement tool on this host — nothing to assert
      }
      final stub = File('${tmp.path}/stub_runner.sh')
        ..writeAsStringSync(stubRunner(tmp.path));
      final watch = Stopwatch()..start();
      final r = await Process.run(
        '/usr/bin/time',
        [
          '-f',
          '%U %S',
          '-o',
          '${tmp.path}/cpu.txt',
          'bash',
          scriptPath,
          '${tmp.path}/main.json',
          '${tmp.path}/retry.json',
          '--',
          'bash',
          stub.path,
          '--exclude-tags',
          'integration',
          '--concurrency=4',
          '--file-reporter=json:${tmp.path}/main.json',
          'test/cli/first_test.dart test/cli/second_test.dart',
        ],
        environment: {'MODE': 'slow-ok', 'LOAD_DROP_RETRY_BACKOFF_S': '0'},
      );
      watch.stop();
      final wall = watch.elapsedMilliseconds / 1000;
      expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
      expect(invocations(tmp.path), hasLength(1), reason: 'green single run');
      expect(
        wall,
        greaterThanOrEqualTo(2.5),
        reason: 'the stub slept ~3s — the watchdog lived through it',
      );
      final cpuLine = File('${tmp.path}/cpu.txt').readAsLinesSync().last.trim();
      final parts = cpuLine.split(RegExp(r'\s+'));
      final cpu = double.parse(parts[0]) + double.parse(parts[1]);
      expect(
        cpu,
        lessThan(wall * 0.5),
        reason:
            'wrapper-tree CPU $cpu s over $wall s wall — a busy-spinning '
            'poll timer pins ~1 core (CPU ≈ wall); a blocking timer is '
            'near-zero. time output: "$cpuLine"',
      );
      expect(
        r.stderr.toString(),
        isNot(contains('No such file or directory')),
        reason:
            'the fresh first invocation computes its spam baseline '
            'before tee starts — no failing `wc -c <` redirect error '
            'leaks to stderr',
      );
    },
  );
}
