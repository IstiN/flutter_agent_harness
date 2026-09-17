/// PTY visual-stability proof for issue #539: stacked background-job boards
/// must never shift or lie.
///
/// Scenario A (width matrix 80/120/200): two waves of background jobs in two
/// turns stack two live board rows; the first wave's row ages out (`· older`)
/// and is captured, then its jobs settle under the camera — the printed
/// `· older` row must stay byte-identical (frozen snapshot, never re-derived
/// from the live registry) and the settled turn leaves exactly ONE terminal
/// summary card in the transcript. Every captured frame keeps the composer's
/// reserved bottom rows (input row, full-width rule, status row) — board
/// rows never paint into or shrink the input zone (AC6).
///
/// Scenario B (restart-lost REG): the CLI is SIGKILLed with live jobs; the
/// resumed session demotes every recorded-live card to `lost` — the
/// `268 running · 0 lost` frame is unrepresentable.
///
/// The provider is the `FA_TEST_STREAM_SCRIPT` hook: no network, real tool
/// execution, real session records.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 10))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

const _replyOne = 'wave one launched for pty539';
const _replyTwo = 'wave two launched for pty539';

/// Run 1 = turn 1 (five live jobs) + turn 2 (text, ends the run).
/// Run 2 = turn 3 (five more live jobs) + turn 4 (text, ends the run;
/// repeats as the wrap-around). Wave one's sleeps are staggered so its
/// settles land ~1 s apart — the freeze proof captures between them.
final _turns = [
  [
    {'text': 'launching the first wave'},
    for (var i = 1; i <= 5; i++)
      {
        'tool_call': {
          'id': 'c1-$i',
          'name': 'bash',
          'arguments': {
            'command': 'sleep ${4 + i} && echo p539-wave1-$i',
            'background': true,
          },
        },
      },
  ],
  [
    {'text': _replyOne},
  ],
  [
    {'text': 'launching the second wave'},
    for (var i = 1; i <= 6; i++)
      {
        'tool_call': {
          'id': 'c2-$i',
          'name': 'bash',
          'arguments': {
            'command': 'sleep 300 && echo p539-wave2-$i',
            'background': true,
          },
        },
      },
  ],
  [
    {'text': _replyTwo},
  ],
];

/// The first wave's collapsed live summary row (5 running, nothing settled).
final _olderRow = RegExp(
  r'Background jobs \(5\) · 5 running · 0 done · '
  r'0 lost · older',
);

/// The first settle notice — `[bash] sh-… exited(0)` prints once per
/// settled job; the first of wave one's staggered exits.
const _firstSettle = 'exited(0)';

/// The settled first wave's terminal transcript card body — unique to the
/// summary card's done hint row, stable on screen once painted.
const _settledCardBody = 'bash_job status lists ids';

/// Any live `N running` board segment — forbidden on a resumed frame.
final _runningSegment = RegExp(r'\d+ running');

void main() {
  late Directory home;
  late Directory project;
  late File turnsFile;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('fa_539_home_');
    project = await Directory.systemTemp.createTemp('fa_539_proj_');
    turnsFile = File('${home.path}/fa_539_turns.json')
      ..writeAsStringSync(jsonEncode(_turns));
  });

  tearDown(() async {
    await home.delete(recursive: true);
    await project.delete(recursive: true);
  });

  Map<String, String> env() => {
    'HOME': home.path,
    'FA_TEST_STREAM_SCRIPT': turnsFile.path,
    'FA_PROVIDER_TYPE': 'openai',
    'FA_PROVIDER_CONFIG': jsonEncode({
      'baseUrl': 'http://127.0.0.1:9', // never dialed — the script streams
      'model': 'pty-scripted',
    }),
  };

  /// The composer's reserved bottom rows: the full-width rule directly
  /// above the status row (board rows may never paint into that zone).
  void expectComposerReserved(List<String> viewport, int columns) {
    expect(viewport, isNotEmpty);
    final status = viewport.last;
    expect(
      status,
      contains('· ctx '),
      reason:
          'the status row is the frame\'s last row — nothing painted '
          'below it:\n${viewport.join('\n')}',
    );
    final rule = viewport[viewport.length - 2];
    expect(
      rule,
      '─' * columns,
      reason:
          'the input zone\'s lower rule is full-width and in place:\n'
          '${viewport.join('\n')}',
    );
  }

  test('stacked boards freeze across settles; composer stays reserved '
      'at 80/120/200', () async {
    for (final (columns, rows) in [(80, 24), (120, 30), (200, 40)]) {
      final harness = await FaCliHarness.spawn(
        workingDirectory: project.path,
        extraEnv: env(),
        args: ['--session', 'pty539-frames-$columns'],
        columns: columns,
        rows: rows,
      );
      addTearDown(harness.close);

      await harness.waitForBoot();
      for (final line in harness.viewportLines) {
        expect(
          line.length,
          lessThanOrEqualTo(columns),
          reason: 'no row may exceed the $columns-column glass',
        );
      }

      // ── wave one: five live jobs, one collapsed board row ────────────
      harness.sendText('run wave one');
      harness.sendEnter();
      await harness.waitForText(
        'Background jobs (5)',
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForText(
        _replyOne,
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 400);

      // ── wave two: the first bucket ages out while still live ─────────
      harness.sendText('run wave two');
      harness.sendEnter();
      await harness.waitForText(
        _olderRow,
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 400);
      final before = harness.viewportLines;
      expectComposerReserved(before, columns);

      // ── wave one's jobs settle under the camera (sleeps 5..9 s) ──────
      // The printed `· older` row is a frozen snapshot: after the FIRST
      // settle lands (four jobs still live), it must not have moved — the
      // unfrozen board would re-derive `· 4 running · 1 done` here.
      final beforeOlder = before
          .where((l) => l.contains('· older') && l.contains('(5)'))
          .toList();
      expect(beforeOlder, hasLength(1), reason: 'frame before:\n$before');
      await harness.waitForText(
        _firstSettle,
        timeout: const Duration(seconds: 30),
      );
      await harness.waitForOutput(settleMs: 300);
      final mid = harness.viewportLines;
      expectComposerReserved(mid, columns);
      expect(
        mid.where((l) => l.contains('· older') && l.contains('(5)')).toList(),
        beforeOlder,
        reason:
            'the printed `· older` row never changes counts while its '
            'jobs settle (before:\n${before.join('\n')}\nmid:\n'
            '${mid.join('\n')})',
      );

      // Full settle hands the bucket to the transcript: exactly ONE
      // terminal summary card, and the aged row leaves the live region.
      await harness.waitForText(
        _settledCardBody,
        timeout: const Duration(seconds: 30),
      );
      await harness.waitForOutput(settleMs: 300);
      final after = harness.viewportLines;
      expectComposerReserved(after, columns);
      // Wave two (six jobs) keeps running in later turns: its row
      // persists as ONE frozen `· older` snapshot at its printed counts.
      expect(
        after.where(
          (l) => l.contains('· older') && l.contains('Background jobs (5)'),
        ),
        isEmpty,
        reason:
            'the fully settled bucket leaves the live region:\n'
            '${after.join('\n')}',
      );
      expect(
        after.where((l) => l.contains(_settledCardBody)),
        hasLength(1),
        reason:
            'the settled summary drains exactly once:\n'
            '${after.join('\n')}',
      );
      expect(
        after.join('\n'),
        contains('Background jobs (6) · 6 running · 0 done · 0 lost'),
        reason:
            'wave two stays live, frozen at its printed counts:\n'
            '${after.join('\n')}',
      );

      await harness.runSlashCommand('/exit');
      await harness.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => -1,
      );
    }
  });

  test(
    'restart with live jobs shows lost, never running (268/0 impossible)',
    () async {
      final harness = await FaCliHarness.spawn(
        workingDirectory: project.path,
        extraEnv: env(),
        args: ['--session', 'pty539-restart'],
      );
      addTearDown(harness.close);
      await harness.waitForBoot();
      harness.sendText('run wave one');
      harness.sendEnter();
      await harness.waitForText(
        'Background jobs (5)',
        timeout: const Duration(seconds: 60),
      );
      // Let the registry persists drain before the crash (issue #539:
      // chained writes land the newest snapshot last — given the time).
      await harness.waitForOutput(settleMs: 600);
      // A real crash: no graceful exit, no boundary work.
      await harness.hardKill();

      final resumed = await FaCliHarness.spawn(
        workingDirectory: project.path,
        extraEnv: env(),
        args: ['--session', 'pty539-restart'],
      );
      addTearDown(resumed.close);
      await resumed.waitForText(
        'lost on restart',
        timeout: const Duration(seconds: 90),
      );
      await resumed.waitForOutput(settleMs: 700);
      final screen = resumed.screenText;

      final lostRows = [
        for (final line in screen.split('\n'))
          if (line.contains('lost on restart')) line,
      ];
      expect(
        lostRows,
        hasLength(1),
        reason: 'the resume-lost summary is ONE row:\n$screen',
      );
      expect(lostRows.single, contains('5 background tasks lost'));
      expect(
        _runningSegment.allMatches(screen),
        isEmpty,
        reason: 'a resumed frame can never claim running jobs:\n$screen',
      );
      expect(
        screen,
        isNot(contains('Background jobs (')),
        reason: 'every card is terminal — no live board rows remain:\n$screen',
      );
      expectComposerReserved(resumed.viewportLines, 80);
    },
  );
}
