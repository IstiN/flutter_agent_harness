// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Issue #2331: `scripts/load_drop_retry.sh` — the one-shot loopback-ws
/// load-drop retry behind the sharded dart test legs.
///
/// Under CI-leg load the dart test loader's loopback WebSocket to a freshly
/// spawned test VM dies mid-handshake (`Failed to load "x_test.dart": Connection closed before full header was received`).
/// The victim file is arbitrary, never an
/// assertion failure (6/6 occurrences). The wrapper must:
///   - re-run ONLY the dropped file(s), exactly once, on that signature;
///   - keep every real failure loud (no signature → no rerun);
///   - never rerun blind (signature without an extractable file);
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

/// Stub runner: per MODE, prints loader-drop lines on attempt 1 and exits 1;
/// exits 0 on the rerun (except drop-always). Every invocation appends its
/// argv to `<tmp>/argv.log` so the rerun's exact command line is assertable.
String stubRunner(String tmp) =>
    '''
#!/usr/bin/env bash
echo "\$*" >> "$tmp/argv.log"
case "\$MODE" in
  ok) exit 0 ;;
  drop-closed-header)
    [ -f "$tmp/attempt2" ] && exit 0
    touch "$tmp/attempt2"
    echo '$droppedClosedHeader'
    exit 1 ;;
  drop-conn-reset)
    [ -f "$tmp/attempt2" ] && exit 0
    touch "$tmp/attempt2"
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
    [ -f "$tmp/attempt2" ] && exit 0
    touch "$tmp/attempt2"
    echo 'Failed to load "test/a_one_test.dart": Connection closed before full header was received, uri = http://127.0.0.1:1/a/ws'
    echo 'Failed to load "test/b_two_test.dart": Error: Compilation failed'
    echo 'Failed to load "test/c_three_test.dart": Connection reset by peer, uri=http://127.0.0.1:2/b/ws'
    exit 1 ;;
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
    environment: {'MODE': mode},
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
    // must not re-run.
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

  test('AC4 a real assertion failure never reruns — stays loud', () async {
    final r = await runWrapper(tmp.path, mode: 'assert-fail');
    expect(r.exitCode, isNot(0));
    expect(r.stdout, contains('Expected: true'));
    expect(invocations(tmp.path), hasLength(1));
  });

  test(
    'AC5 ws signature without a Failed-to-load file never reruns blind',
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

  test('AC7 mixed run: only signature-bearing dropped files rerun; a '
      'compile-error load failure does not', () async {
    final r = await runWrapper(
      tmp.path,
      mode: 'drop-two-plus-compile-error',
      targets:
          'test/a_one_test.dart test/b_two_test.dart test/c_three_test.dart',
    );
    expect(r.exitCode, 0, reason: 'stderr: ${r.stderr}');
    final calls = invocations(tmp.path);
    expect(calls, hasLength(2));
    expect(calls[1], contains('test/a_one_test.dart'));
    expect(calls[1], contains('test/c_three_test.dart'));
    expect(
      calls[1],
      isNot(contains('test/b_two_test.dart')),
      reason: 'a compile-error load failure is deterministic — never rerun',
    );
  });
}
