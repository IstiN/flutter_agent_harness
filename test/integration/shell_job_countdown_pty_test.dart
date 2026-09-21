/// Terminal countdown proof for the background-job board (PR #573 review,
/// owner ask on shell_jobs.dart): simulate TEN background bash tool calls,
/// verify every one starts (`10 running` on the live board), capture
/// mid-flight screenshots while the count counts down, and prove the drain
/// to `0 running` with no live board row left. A settle-notice run (the
/// async-result flow) streams between settles — the board keeps counting
/// down across runs.
///
/// Screenshots: the PTY harness's layout-faithful screen text is written
/// to `test/integration/screenshots/30{0,1,2}_shell_job_countdown_*.txt`
/// (the `.txt`-twin precedent of the visual suite) and asserted inline, so
/// the countdown is both human-inspectable and CI-enforced.
///
/// Waits are anchored polling only (#533/#550/#557 deflake precedent) —
/// no fixed sleeps beyond the harness settle windows.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

/// Turn 1 = ten background bash jobs with sleeps staggered 3..12 s, so
/// settles land ~1 s apart and the countdown is observable across frames.
/// Turn 2 is the LAST turn: it repeats for every settle-notice run the
/// registry fires (the last-turn-repeats contract), so it must stay a
/// plain-text reply — a tool_call here would re-spawn jobs on wrap.
final _turns = [
  [
    {'text': 'launching ten background jobs for p573'},
    for (var i = 1; i <= 10; i++)
      {
        'tool_call': {
          'id': 'c1-$i',
          'name': 'bash',
          'arguments': {
            'command': 'sleep ${2 + i} && echo p573-job-$i',
            'background': true,
          },
        },
      },
  ],
  [
    {'text': 'p573 wave launched'},
  ],
];

/// The live collapsed board row: ten started, nothing settled yet.
const _allRunning = 'Background jobs (10) · 10 running · 0 done · 0 lost';

/// One settle notice per finished job (`[bash] sh-… exited(0)`); exactly
/// ten of these prove every command started AND finished.
final _settleNotice = RegExp(r'\[bash\] sh-(\S+) exited\(0\)');

/// The same row mid-drain — the countdown segment this test photographs.
final _liveBoard = RegExp(r'Background jobs \(10\) · (\d+) running');

/// Any live running count above zero — forbidden on the final frame.
final _stuckRunning = RegExp(r'[1-9]\d* running');

void main() {
  test(
    'ten background bash jobs start, count down on camera, drain to '
    '0 running (#573 review)',
    () async {
      final home = await Directory.systemTemp.createTemp('fa_573_home_');
      final project = await Directory.systemTemp.createTemp('fa_573_proj_');
      addTearDown(() => home.delete(recursive: true));
      addTearDown(() => project.delete(recursive: true));
      final turnsFile = File('${home.path}/fa_573_turns.json')
        ..writeAsStringSync(jsonEncode(_turns));

      final harness = await FaCliHarness.spawn(
        workingDirectory: project.path,
        extraEnv: {
          'HOME': home.path,
          'FA_TEST_STREAM_SCRIPT': turnsFile.path,
          'FA_PROVIDER_TYPE': 'openai',
          'FA_PROVIDER_CONFIG': jsonEncode({
            'baseUrl': 'http://127.0.0.1:9', // never dialed — the script
            'model': 'pty-scripted',
          }),
        },
        args: ['--session', 'pty573-countdown'],
        columns: 80,
        rows: 24,
      );
      addTearDown(harness.close);
      await harness.waitForBoot();

      // ── all ten START: the live board peaks at `10 running` ───────────
      harness.sendText('run the countdown');
      harness.sendEnter();
      await harness.waitForScreen(
        _allRunning,
        timeout: const Duration(seconds: 60),
      );
      await harness.waitForOutput(settleMs: 200);
      final peak = harness.viewportLines;
      expectComposerReserved(peak, 80);
      _writeShot(harness, '300_shell_job_countdown_10_running');

      // ── MID-FLIGHT SCREEN: the count strictly between 10 and 0 ────────
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      int? mid;
      while (DateTime.now().isBefore(deadline)) {
        final match = _liveBoard.firstMatch(harness.screenText);
        final count = match == null ? null : int.parse(match.group(1)!);
        if (count != null && count >= 1 && count <= 9) {
          mid = count;
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(
        mid,
        isNotNull,
        reason: 'the board must be photographed mid-countdown — every '
            'frame showed 10 or 0 running:\n${harness.screenText}',
      );
      await harness.waitForOutput(settleMs: 200);
      expectComposerReserved(harness.viewportLines, 80);
      _writeShot(harness, '301_shell_job_countdown_mid_$mid');

      // ── all ten FINISH: one settle notice per job, exactly ────────────
      final drained = await harness.waitForOutput(
        settleMs: 500,
        timeout: const Duration(seconds: 60),
      );
      // Frame repaints re-emit notices into the raw stream — the start/
      // finish proof is the set of DISTINCT settled job numbers, not the
      // raw match count. Match on the NUMBER PREFIX, never the full id:
      // a repaint can interleave cursor-move escapes mid-id (observed
      // under CI load: `sh-10-…xqo<esc>[11;29H5<esc>[11;31H exited(0)`),
      // and a fragmented re-emit would otherwise inflate the distinct-id
      // set with a corrupt entry. The number is the first token written,
      // so it survives any such fragmentation.
      final settledNumbers = _settleNotice
          .allMatches(drained)
          .map((m) => m.group(1)!.split('-').first)
          .toSet();
      expect(
        settledNumbers,
        {for (var i = 1; i <= 10; i++) '$i'},
        reason:
            'ten background bash commands must start and finish: '
            '$settledNumbers',
      );

      // ── THE DRAIN: `0 running`, one terminal card, no live row ────────
      await harness.waitForScreen(
        '0 running',
        timeout: const Duration(seconds: 30),
      );
      await harness.waitForOutput(settleMs: 300);
      final after = harness.viewportLines;
      expectComposerReserved(after, 80);
      _writeShot(harness, '302_shell_job_countdown_0_running');
      final screen = after.join('\n');
      expect(
        screen,
        contains(
          'Background jobs (10) · 0 running · 10 done · 0 lost',
        ),
        reason: 'the settled collapsed turn hands ONE terminal summary '
            'card to the transcript, drained:\n$screen',
      );
      expect(
        _stuckRunning.allMatches(screen),
        isEmpty,
        reason: 'no live job remains — the count drained to zero:\n$screen',
      );

      await harness.runSlashCommand('/exit');
      await harness.pty.exitCode.timeout(
        const Duration(seconds: 15),
        onTimeout: () => -1,
      );
    },
  );
}

/// The composer's reserved bottom rows: the full-width rule directly above
/// the status row — countdown frames never paint into the input zone.
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

/// Writes the current screen as a `.txt` screenshot twin
/// (`test/integration/screenshots/`, gitignored like the visual suite's).
void _writeShot(FaCliHarness harness, String name) {
  const dir = 'test/integration/screenshots';
  Directory(dir).createSync(recursive: true);
  File('$dir/$name.txt').writeAsStringSync(harness.screenText);
}
