// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../support/nwbgy7a_fixture.dart';

/// gh-1605 REG/eval: the mechanics behind the FinalizeGate "grader
/// parity" named check. The TB-2.1 verifier runs produced entry points
/// itself — typically `subprocess.run([sys.executable, script])` from a
/// different working directory with a fresh environment — while the
/// agent's self-check runs them from its own session cwd with its
/// session env. The modernize-scientific-stack__nwbgy7a trial passed
/// every in-session checklist item and still scored 0.0: the verifier's
/// clean run collapsed Station 102 to Station 101's mean because the
/// script resolved its dataset via the CWD. The check's prescribed
/// procedure — re-run each produced entry point from a neutral cwd in a
/// fresh subprocess with the session exports stripped, and diff stdout,
/// stderr and exit code against the in-session run — must CATCH that
/// divergence (the parity ledger item is `fail`, never `pass`) and must
/// NOT false-positive a cwd/env-independent entry point (`pass`).
void main() {
  late Directory tempDir;
  late String appDir;

  /// The agent's in-session verification run: the session cwd (the app
  /// directory it built), the session environment — exports included.
  Future<ProcessResult> inSessionRun(
    String script, {
    Map<String, String> sessionExports = const {},
  }) => Process.run(
    '/bin/bash',
    [script],
    workingDirectory: appDir,
    environment: {...Platform.environment, ...sessionExports},
  );

  /// The grader-parity re-run: a fresh subprocess from a NEUTRAL cwd
  /// (never the session cwd) with the session exports stripped from the
  /// session environment — the invocation shape the verifier uses. Takes
  /// the same [sessionExports] the in-session run merged in, so the
  /// strip is provably exercised for every member of [_sessionExports].
  Future<ProcessResult> graderParityRun(
    String script, {
    Map<String, String> sessionExports = const {},
  }) => Process.run(
    '/bin/bash',
    [script],
    workingDirectory: '/',
    // includeParentEnvironment: false is what makes the strip REAL: with
    // the default `true`, every key absent from the map is re-inherited
    // from this process — and the runner's own env carries a live
    // FAH_SESSION_ID, so a "stripped" var would silently leak back in
    // (the exact hole this REG pins).
    includeParentEnvironment: false,
    environment: {
      for (final entry in {
        ...Platform.environment,
        ...sessionExports,
      }.entries)
        if (!_sessionExports.contains(entry.key)) entry.key: entry.value,
    },
  );

  /// The parity ledger item the FinalizeGate contract mandates for a
  /// produced entry point: divergence in stdout, stderr or exit code is
  /// a `fail` — never a pass.
  TaskLedgerItem parityItem({
    required ProcessResult inSession,
    required ProcessResult parity,
  }) {
    final diverged =
        '${inSession.stdout}'.trim() != '${parity.stdout}'.trim() ||
        '${inSession.stderr}'.trim() != '${parity.stderr}'.trim() ||
        inSession.exitCode != parity.exitCode;
    return TaskLedgerItem(
      requirement:
          'grader parity: entry point output matches under the '
          "verifier's fresh cwd + clean env",
      command: 'cd / && /bin/bash <entry-point>',
      expected: '${inSession.stdout}'.trim(),
      actual: '${parity.stdout}'.trim(),
      status: diverged ? TaskLedgerItemStatus.fail : TaskLedgerItemStatus.pass,
    );
  }

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('fa-grader-parity-');
    tempDir = Directory(await tempDir.resolveSymbolicLinks());
    appDir = '${tempDir.path}/app';
    Directory(appDir).createSync();
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test(
    'REG: a cwd-dependent entry point is caught (fail, not passed)',
    () async {
      // The evidence bug shape: the entry point resolves its dataset via
      // the CWD — from the app directory the fixed stations.csv, from
      // anywhere else a stale bundled table. The fixture is the shared
      // nwbgy7a evidence shape (test/support/nwbgy7a_fixture.dart) —
      // the IT-3 replay in test/integration/fa_finalize_gate_test.dart
      // produces the very same files via bash.
      writeNwbgy7aFixture(appDir);
      final script = '$appDir/mean.sh';

      final inSession = await inSessionRun(script);
      final parity = await graderParityRun(script);

      // The failure shape of the evidence trial: the in-session run reads
      // the fixed dataset, the grader's clean-cwd run silently falls back
      // to the stale table — Station 102 collapses to 15.5.
      expect(inSession.exitCode, 0);
      expect(parity.exitCode, 0);
      expect('${inSession.stdout}', contains('30.3'));
      expect('${parity.stdout}', isNot(contains('30.3')));
      expect('${parity.stdout}', contains('15.5'));

      final item = parityItem(inSession: inSession, parity: parity);
      expect(item.status, TaskLedgerItemStatus.fail);
      expect(item.verified, isFalse);

      // The divergence survives the real ledger pipeline: the fenced block
      // parses back with the fail status intact — the record the bench
      // summary's checklist column reads.
      final parsed = parseTaskLedger(
        'Answer.\n${formatTaskLedgerBlock(TaskLedger(items: [item]))}\n',
      );
      expect(parsed!.items.single.status, TaskLedgerItemStatus.fail);
      expect(parsed.items.single.actual, contains('15.5'));
    },
  );

  test(
    'REG: a session-env-dependent entry point is caught (clean env)',
    () async {
      final script = '$appDir/unit.sh';
      File(script).writeAsStringSync(
        '#!/usr/bin/env bash\n'
        'echo "unit: \${TEMP_UNIT:-C}"\n'
        'echo "session: \${FAH_SESSION_ID:-none}"\n',
      );

      // BOTH session exports the parity run must strip: the unit symbol
      // and the harness's own session id. The parity re-run is handed
      // the same exports so the strip from a session env that provably
      // carries them is exercised — not assumed.
      // and the harness's own session id. The parity re-run is handed
      // the same exports so the strip from a session env that provably
      // carries them is exercised — not assumed.
      const sessionExports = {'TEMP_UNIT': 'F', 'FAH_SESSION_ID': 'sess-42'};

      final inSession = await inSessionRun(
        script,
        sessionExports: sessionExports,
      );
      final parity = await graderParityRun(
        script,
        sessionExports: sessionExports,
      );

      // The session exports leak into the in-session output; the grader's
      // clean env carries neither — both fall back to their defaults.
      expect('${inSession.stdout}', contains('unit: F'));
      expect('${inSession.stdout}', contains('session: sess-42'));
      expect('${parity.stdout}', contains('unit: C'));
      expect('${parity.stdout}', contains('session: none'));

      final item = parityItem(inSession: inSession, parity: parity);
      expect(item.status, TaskLedgerItemStatus.fail);
      expect(item.verified, isFalse);
    },
  );

  test('REG: a cwd/env-independent entry point parity-passes (no false '
      'positive)', () async {
    final script = '$appDir/report.sh';
    File(script).writeAsStringSync(
      '#!/usr/bin/env bash\n'
      'echo "Station 101 mean temperature: -15.5 C"\n'
      'echo "Station 102 mean temperature: 30.3 C"\n',
    );

    final inSession = await inSessionRun(
      script,
      sessionExports: const {'TEMP_UNIT': 'F'},
    );
    final parity = await graderParityRun(script);

    expect('${inSession.stdout}'.trim(), '${parity.stdout}'.trim());
    final item = parityItem(inSession: inSession, parity: parity);
    expect(item.status, TaskLedgerItemStatus.pass);
    expect(item.verified, isTrue);

    // The parity pass is the gate's green state: the item counts as
    // verified.
    expect(TaskLedger(items: [item]).allVerified, isTrue);
  });
}

/// The session-exported variable names the scenarios above "export" —
/// the parity re-run strips them (a grader never sees the session's
/// environment). Both members are exercised: the session-env REG exports
/// each of them in its in-session run and asserts the parity run sees
/// only the defaults.
const _sessionExports = {'FAH_SESSION_ID', 'TEMP_UNIT'};
