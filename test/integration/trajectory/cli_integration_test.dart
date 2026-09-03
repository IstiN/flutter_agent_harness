@TestOn('vm')
@Tags(['integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:test/test.dart';

import '../fa_cube_headless_helper.dart' show FaResult;
import 'mock_session.dart';

void main() {
  late Directory tempHome;
  late Directory sessionsRoot;
  late MockSessionFixture fixture;

  setUpAll(() async {
    tempHome = Directory.systemTemp.createTempSync('fa_traj_cli_home_');
    sessionsRoot = Directory.systemTemp.createTempSync('fa_traj_cli_sess_');
    // The full-ledger script: context, model change, one tooled turn, a
    // plain step, a checkpoint, a compaction, and a second turn — 10 rows.
    final script = MockSessionScript()
      ..contextInject('repo context: flutter_agent_harness')
      ..modelChange(provider: 'openai', modelId: 'gpt-mock')
      ..turn(
        'fix the bug',
        toolCalls: [
          const MockToolCallSpec(
            'call-1',
            name: 'read',
            args: {'path': 'lib/x.dart'},
          ),
        ],
      )
      ..assistantText('patched and verified')
      ..checkpoint(messageCount: 6, goal: 'investigate flaky test');
    script.compaction(
      summary: 'compacted summary',
      firstKeptEntryId: script.stepId(6),
    );
    script
      ..user('continue')
      ..assistantText(
        'finished',
        usage: const Usage(
          input: 200,
          output: 40,
          cacheRead: 0,
          cacheWrite: 0,
          totalTokens: 240,
          cost: UsageCost(total: 0.03),
        ),
      );
    fixture = await MockSessionFixture.build(
      script,
      sessionsRoot: sessionsRoot,
    );
  });

  tearDownAll(() {
    tempHome.deleteSync(recursive: true);
    sessionsRoot.deleteSync(recursive: true);
  });

  /// Runs the real binary: `dart run bin/fah.dart trajectory <args>`.
  ///
  /// `HOME` points at a temp home so the developer's `~/.fah` is never read;
  /// the session store is pinned with `--session-root` per call.
  Future<FaResult> runFaTrajectory(
    List<String> args, {
    String? sessionRoot,
  }) async {
    final run = await Process.run(
      'dart',
      [
        'run',
        'bin/fah.dart',
        'trajectory',
        ...args,
        '--session-root',
        sessionRoot ?? sessionsRoot.path,
      ],
      workingDirectory: Directory.current.path,
      environment: {'HOME': tempHome.path, 'OPENAI_API_KEY': 'mock'},
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(const Duration(minutes: 3));
    return FaResult(
      stdout: run.stdout as String,
      stderr: run.stderr as String,
      exitCode: run.exitCode,
    );
  }

  group('fa trajectory CLI against a real session store', () {
    test('view prints the ledger lines', () async {
      final run = await runFaTrajectory(['view', fixture.sessionId]);

      expect(run.exitCode, 0, reason: run.output);
      expect(run.stdout, contains('#1 CONTEXT'));
      expect(run.stdout, contains('#3 USER'));
      expect(run.stdout, contains('fix the bug'));
      expect(run.stdout, contains('#4 ASSISTANT'));
      expect(run.stdout, contains('#5 TOOL'));
      expect(run.stdout, contains('#8 COMPACTED'));
      expect(run.stdout, contains('compacted summary'));
      // Assistant rows carry tokens, the tool row a duration.
      expect(run.stdout, contains('120 tok'));
      expect(run.stdout, contains('2,000 ms'));
    });

    test('view --at N truncates the ledger to the first N rows', () async {
      final run = await runFaTrajectory([
        'view',
        fixture.sessionId,
        '--at',
        '3',
      ]);

      expect(run.exitCode, 0, reason: run.output);
      final rows = run.stdout
          .split('\n')
          .where((line) => line.startsWith('#'))
          .toList();
      expect(rows, hasLength(3));
      expect(rows.last, startsWith('#3 USER'));
    });

    test('cost prints the usage table with the cumulative line', () async {
      final run = await runFaTrajectory(['cost', fixture.sessionId]);

      expect(run.exitCode, 0, reason: run.output);
      expect(run.stdout, contains('turn/step'));
      expect(run.stdout, contains('mock-model'));
      // Per-request totals: 120, 120, 240 tokens at in 100/100/200.
      expect(run.stdout, contains('120'));
      expect(run.stdout, contains('240'));
      // Requests: assistant 1/1, assistant 1/2, compaction 1/0 (it sits in
      // turn 1), assistant 2/1.
      expect(run.stdout, contains('1/0'));
      expect(run.stdout, contains('session cumulative: in 400'));
    });

    test('inspect prints the full record detail', () async {
      final run = await runFaTrajectory(['inspect', '3', fixture.sessionId]);

      expect(run.exitCode, 0, reason: run.output);
      expect(run.stdout, contains('#3 USER'));
      expect(run.stdout, contains('text: fix the bug'));
      expect(run.stdout, contains('opens turn: yes'));
    });

    test('--json emits one JSON object per line', () async {
      final view = await runFaTrajectory(['view', fixture.sessionId, '--json']);
      expect(view.exitCode, 0, reason: view.output);
      final lines = view.stdout
          .split('\n')
          .where((line) => line.trim().isNotEmpty)
          .toList();
      expect(lines, hasLength(10));
      final first = jsonDecode(lines.first) as Map<String, dynamic>;
      expect(first['index'], 1);
      expect(first['kind'], 'context');
      final last = jsonDecode(lines.last) as Map<String, dynamic>;
      expect(last['index'], 10);
      expect(last['kind'], 'message');
      expect(last['tokens'], 240);

      final inspect = await runFaTrajectory([
        'inspect',
        '2',
        fixture.sessionId,
        '--json',
      ]);
      expect(inspect.exitCode, 0, reason: inspect.output);
      final single = jsonDecode(inspect.stdout.trim()) as Map<String, dynamic>;
      expect(single['index'], 2);
      expect(single['kind'], 'system');
    });

    test('unknown session id exits 1 with a stderr message', () async {
      final run = await runFaTrajectory(['view', 'no-such-session']);

      expect(run.exitCode, 1);
      expect(run.stderr, contains('session not found: no-such-session'));
    });

    test('out-of-range index exits 1 with the bounds message', () async {
      final inspect = await runFaTrajectory([
        'inspect',
        '999',
        fixture.sessionId,
      ]);
      expect(inspect.exitCode, 1);
      expect(
        inspect.stderr,
        contains('trajectory: record out of range: 999 (1..10)'),
      );

      final atZero = await runFaTrajectory([
        'view',
        fixture.sessionId,
        '--at',
        '0',
      ]);
      expect(atZero.exitCode, 1);
      expect(atZero.stderr, contains('trajectory: record out of range: 0'));
    });

    test('empty store exits 1 pointing at the session root', () async {
      final emptyRoot = Directory.systemTemp.createTempSync('fa_traj_empty_');
      try {
        final run = await runFaTrajectory([
          'view',
        ], sessionRoot: emptyRoot.path);
        expect(run.exitCode, 1);
        expect(run.stderr, contains('trajectory: no sessions in'));
      } finally {
        emptyRoot.deleteSync(recursive: true);
      }
    });
  });
}
