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

/// The first wave's collapsed live summary row (gh-1446 signal format:
/// the running count behind the modern glyph, no done/lost noise — the
/// `· older` provenance marker stays, frozen at first print, #539).
final _olderRow = RegExp(
  r'[◐○⬤\W] Background jobs \(5\) · older',
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
    // Issue #943 (vector 1): unique per-RUN roots. The old hardcoded
    // /tmp/fa_539_home + /tmp/fa_539_proj were shared by every copy of
    // this suite — one run's tearDown deleting them under another's live
    // CLI wedges the boot ([Model] never arrives) and then breaks its own
    // teardown (PathNotFoundException). Observed on main (run 36224616919).
    //
    // Under /tmp, NOT Directory.systemTemp: on the mac minis systemTemp
    // resolves to a ~77-char /private/var/folders/... path, and the status
    // row renders `<cwd> · ctx N% ...` clipped at the glass — the long cwd
    // eats the `· ctx ` marker expectComposerReserved() sniffs, so a live
    // frame misclassifies as idle (run 36232635161, the 80-col leg). The
    // resolved /tmp path (/private/tmp/fa_539_XXXXXX) keeps the marker
    // inside the glass; /tmp already was this suite's platform contract.
    home = await Directory('/tmp').createTemp('fa_539_h_');
    project = await Directory('/tmp').createTemp('fa_539_p_');
    // Pin the classic chrome: this suite asserts the classic grid (#539);
    // the band redesign (#805-#807) has its own surface.
    File('${home.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('tui:\n  classic: true\n');
    turnsFile = File('${home.path}/fa_539_turns.json')
      ..writeAsStringSync(jsonEncode(_turns));
  });

  tearDown(() async {
    // Failure-safe cleanup (issue #943): the run's own verdict must never
    // hinge on whether a straggler ext process still holds a root — a
    // unique-per-run root can only leave /tmp residue, never poison the
    // next run.
    for (final dir in [home, project]) {
      try {
        dir.deleteSync(recursive: true);
      } on FileSystemException {
        // Straggler holds it; /tmp reclaims the unique dir.
      }
    }
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
      // Compared as CONTENT frames (gh-982): raw viewport equality also
      // compares xterm buffer-cell materialization, which the two dart_tui
      // paint paths leave differently depending on frame history — the
      // macOS/fa-m5 flake failed raw equality on byte-identical counts.
      final beforeOlder = frameContentLines(before)
          .where((l) => l.contains('· older') && l.contains('(5)'))
          .map((l) => l.trimRight())
          .toList();
      expect(beforeOlder, hasLength(1), reason: 'frame before:\n$before');
      await harness.waitForText(
        _firstSettle,
        timeout: const Duration(seconds: 60),
      );
      // Fixed beat, not a quiet-gap wait (issue #1250): each settle notice
      // steers a wrap turn, so the raw stream stays noisy across the whole
      // drain on a loaded runner — waitForOutput's 2x-settleMs quiet
      // detector only fired AFTER the last settle, and `mid` caught the
      // by-design fully-drained frame (frozen row gone) instead of the
      // mid-drain one (3 distinct-SHA gate reds). A fixed 300 ms beat is
      // not enough either (gh-1250 CI frames): the settle HARVESTER batches
      // — a starved poll prints all five `exited(0)` notices in one burst,
      // so no post-first-notice beat can land mid-drain. The sampleable
      // contract is the INVARIANT, not the intermediate state: if the
      // `· older` row is still on screen it must be byte-identical (a
      // re-derived board would show `· 4 running · 1 done`); if the whole
      // batch drained between camera samples the AFTER asserts below
      // (exactly one terminal card, row leaves the live region) still
      // police the transition.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      final mid = harness.viewportLines;
      expectComposerReserved(mid, columns);
      final midOlder = frameContentLines(mid)
          .where((l) => l.contains('· older') && l.contains('(5)'))
          .map((l) => l.trimRight())
          .toList();
      // Absent = the whole batch drained between camera samples — legal
      // only as the fully-drained frame: the harvester hands the bucket
      // to the transcript in ONE transition, so the settled card must
      // already be painted (a row that vanished without the card is a
      // wedge). Present = byte-identical, never re-derived.
      if (midOlder.isNotEmpty) {
        expect(
          midOlder,
          beforeOlder,
          reason:
              'a printed `· older` row never changes counts while its '
              'jobs settle (before:\n${before.join('\n')}\nmid:\n'
              '${mid.join('\n')})',
        );
      } else {
        expect(
          mid.join('\n'),
          contains(_settledCardBody),
          reason:
              'row gone at MID is only legal as a fully-drained frame:\n'
              '${mid.join('\n')}',
        );
      }

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
        contains('Background jobs (6)'),
        reason:
            'wave two stays live, frozen at its printed counts (gh-1446 '
            'signal format — no count suffix when nothing is lost):\n'
            '${after.join('\n')}',
      );
      // gh-1446 AC2: the live line NEVER carries count words.
      expect(
        after.join('\n'),
        isNot(contains('running ·')),
        reason: 'the live board line names no `running` segment',
      );

      await harness.runSlashCommand('/exit');
      await harness.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => -1,
      );
    }
  });

  // gh-938: only this case races the shared /tmp/fa_539_home layout.
  // 'stacked boards freeze' above was QUARANTINED under gh-982 and is
  // re-enabled: the macOS/fa-m5 flake was the raw viewport equality
  // comparing xterm buffer-cell materialization across the dart_tui
  // paint paths (fixed via frameContentLines), not a board regression.
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
    // Issue #943: re-enabled — the /tmp/fa_539_* race it died of is gone
    // (unique per-run roots + failure-safe cleanup above). The OTHER
    // scenario ('stacked boards freeze', #937) is re-enabled too, via the
    // gh-982 fix (frameContentLines) on top of the same unique roots.
  );
}
