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
}
