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

/// Wave one's first sleep (seconds): its jobs settle at base+1 .. base+5,
/// staggered ~1 s apart. The base keeps every job alive well past boot +
/// two scripted turns + harness polling (~10 s worst on fa-m5-class
/// runners) — with the original 5..9 s window the whole bucket could
/// settle and drain BEFORE the freeze proof's `before` capture, leaving
/// no frozen `· older` row to assert on (gh-937).
const int _waveOneSleepBase = 20;

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
            'command': 'sleep ${_waveOneSleepBase + i} && echo p539-wave1-$i',
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
    // UNIQUE per-run roots (the #936 class): the former fixed
    // /tmp/fa_539_home + /tmp/fa_539_proj paths race every concurrently
    // running copy of this suite — the 3 PTY shards share the mini pool, so
    // a sibling's setUp/tearDown recreating or deleting the fixed dir wedges
    // this copy's CLI mid-boot (the [Model] banner never arrives →
    // waitForBoot timeout) and then breaks its own tearDown
    // (PathNotFoundException). Observed on main (run 36224616919).
    // systemTemp keeps each run self-contained; the unique HOME also stops
    // session state from a crashed prior run leaking into the next.
    home = await Directory.systemTemp.createTemp('fa_539_home_');
    project = await Directory.systemTemp.createTemp('fa_539_proj_');
    // Pin the classic chrome: this suite asserts the classic grid (#539);
    // the band redesign (#805-#807) has its own surface.
    File('${home.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('tui:\n  classic: true\n');
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

  /// Board content that may never paint into the composer's reserved zone.
  final boardRow = RegExp(r'Background jobs \(|⟳ |✔ |⏵ queued|❯ ');

  /// The composer's reserved bottom rows. When a turn is live, the status
  /// row is the frame's last row with the full-width rule directly above it;
  /// when the CLI is idle the classic chrome collapses and the composer
  /// prompt row is the last row instead. Board rows may never paint into
  /// that zone in either state.
  void expectComposerReserved(List<String> viewport, int columns) {
    expect(viewport, isNotEmpty);
    var statusIdx = -1;
    for (var i = viewport.length - 1; i >= 0; i--) {
      if (viewport[i].contains('· ctx ')) {
        statusIdx = i;
        break;
      }
    }
    if (statusIdx >= 0) {
      // Live frame: below the status row only chrome (blank, rule, composer).
      for (var i = statusIdx + 1; i < viewport.length; i++) {
        expect(
          boardRow.hasMatch(viewport[i]),
          isFalse,
          reason: 'board rows never paint below the status row '
              '(row $i: "${viewport[i]}"):\n${viewport.join('\n')}',
        );
      }
      if (statusIdx == viewport.length - 1) return;
      final rule = viewport[viewport.length - 2];
      expect(
        rule,
        '─' * columns,
        reason:
            'the input zone\'s lower rule is full-width and in place:\n'
            '${viewport.join('\n')}',
      );
    } else {
      // Idle collapse: the composer prompt row is the frame's last row.
      expect(
        viewport.last.trimRight(),
        startsWith('╰─'),
        reason: 'idle chrome collapses to the composer prompt row:\n'
            '${viewport.join('\n')}',
      );
    }
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
      // The screen is the assertion contract (the frame is what freezes);
      // a raw-text match can fire before the row is even painted.
      await harness.waitForScreen(
        _olderRow,
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 400);
      final before = harness.viewportLines;
      expectComposerReserved(before, columns);

      // ── wave one's jobs settle under the camera (sleeps 21..25 s) ────
      // The printed `· older` row is a frozen snapshot: after the FIRST
      // settle lands (four jobs still live), it must not have moved — the
      // unfrozen board would re-derive `· 4 running · 1 done` here.
      // The frozen-snapshot contract (issue #539) is the row's printed
      // CONTENT — counts may never move while its jobs settle. The captured
      // line's TRAILING SPACES are VT paint residue (whatever longer line
      // last occupied that screen row, cleared or kept by a later
      // `\x1b[K`), invisible to the user and timing-dependent under the
      // concurrency=4 shards: the 120-col leg failed on a byte-identical
      // text row that merely lost its residue between the two captures
      // (run 36226403947). Assert on trimmed lines.
      List<String> olderRowsOf(List<String> frame) => frame
          .where((l) => l.contains('· older') && l.contains('(5)'))
          .map((l) => l.trimRight())
          .toList();
      final beforeOlder = olderRowsOf(before);
      expect(beforeOlder, hasLength(1), reason: 'frame before:\n$before');
      await harness.waitForText(
        _firstSettle,
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 300);
      final mid = harness.viewportLines;
      expectComposerReserved(mid, columns);
      expect(
        olderRowsOf(mid),
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
        timeout: const Duration(seconds: 60),
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

  // gh-938: this case raced the shared /tmp/fa_539_home layout — moot since
  // setUp moved both roots to unique systemTemp dirs (the #936 class fix
  // above), so the skip is dropped. 'stacked boards freeze' above stays
  // UNSKIPPED on purpose — it is the real #937 regression and must stay red
  // until ai/gh-869 is fixed.
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
