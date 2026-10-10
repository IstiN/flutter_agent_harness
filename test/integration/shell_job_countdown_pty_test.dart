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
// 8 min, not 5: the stage ceilings sum to ~7 min in the everything-times-
// out path (gh-1337 review) — at 5 the generic per-test abort would eat
// waitForRaw's diagnostic-rich TimeoutException (screen + raw tail) in
// exactly the slow-runner hang case this suite is hardened against.
@Timeout(Duration(minutes: 8))
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

/// The live collapsed board row at peak (gh-1446 signal format: the
/// parens carry the RUNNING count — no done/lost noise on the live line).
const _allRunning = 'Background jobs (10)';

/// One settle notice per finished job (`[bash] sh-… exited(code)`); exactly
/// ten of these prove every command started AND finished — the proof set
/// lives in the harness as [shellJobSettleNotice] / `settledJobNumbers`
/// (top-level, unit-provable without a PTY). Reused as the mid-countdown
/// poll: the live parens count DECREMENTS as jobs settle (gh-1446 — the
/// live line counts running jobs only).
final _liveBoard = RegExp(r'Background jobs \((\d+)\)');

/// Any live running count above zero — forbidden on the final frame.
final _stuckRunning = RegExp(r'[1-9]\d* running');

void main() {
  test('ten background bash jobs start, count down on camera, drain to '
      '0 running (#573 review)', () async {
    // Unique SHORT dirs (the #936/#938 class — fixed /tmp paths race
    // concurrent suite copies on the shared minis). The classic
    // status-row tail ('· ctx', ' · turn ') is truncated by long macOS
    // temp paths, so the roots stay under /tmp.
    final home = Directory('/tmp').createTempSync('fa573h');
    final project = Directory('/tmp').createTempSync('fa573p');
    addTearDown(() => home.delete(recursive: true));
    addTearDown(() => project.delete(recursive: true));
    // Pin the classic chrome: this suite asserts the pre-#805 classic
    // grid; the band redesign (#805-#807) has its own surface. The
    // provider comes from env vars only, so the pin is a tiny config.
    File('${home.path}/.fah/config.yaml')
      ..createSync(recursive: true)
      ..writeAsStringSync('tui:\n  classic: true\n');
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
      reason:
          'the board must be photographed mid-countdown — every '
          'frame showed 10 or 0 running:\n${harness.screenText}',
    );
    await harness.waitForOutput(settleMs: 200);
    expectComposerReserved(harness.viewportLines, 80);
    _writeShot(harness, '301_shell_job_countdown_mid_$mid');

    // ── all ten FINISH: one settle notice per job, exactly ────────────
    // gh-1337 (CI v1.0.520): this was a silence settle —
    // `waitForOutput(settleMs: 500)` returns once ~1 s of raw-stream
    // quiet passes. But this scenario staggers its sleeps exactly 1 s
    // apart (3..12 s), so the gaps BETWEEN settle notices sit right on
    // that threshold; one stretched gap on a loaded runner (job 7 → 8)
    // returned mid-drain with the tail jobs unlanded and the capture
    // held only {1..7}. The wait is now anchored on the proof data
    // itself — all ten DISTINCT settle numbers present in the raw
    // buffer — with a generous ceiling for slow runners; expiry throws
    // with diagnostics instead of silently truncating. (Supersedes the
    // gh-1357 drain-screen anchor defused from PR #1325.)
    final drained = await harness.waitForRaw(
      (raw) => settledJobNumbers(raw).length == 10,
      what: 'all ten distinct shell-job settle notices in raw output',
      timeout: const Duration(seconds: 120),
    );
    // Frame repaints re-emit notices into the raw stream — the start/
    // finish proof is the set of DISTINCT settled job numbers, not the
    // raw match count (fragmented-id tolerance lives inside
    // settledJobNumbers).
    final settledNumbers = settledJobNumbers(drained);
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
      contains('Background jobs (10) · 0 running · 10 done · 0 lost'),
      reason:
          'the settled collapsed turn hands ONE terminal summary '
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
  });
}

/// The composer's reserved bottom rows. When a turn is live, the status
/// row is the frame's last row with the full-width rule directly above it;
/// when the CLI is idle the classic chrome collapses and the composer
/// prompt row is the last row instead. Nothing foreign may paint into
/// that zone in either state (contract aligned with the #539 suite).
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
    // Live frame: the full-width rule sits directly above the composer.
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
      reason:
          'idle chrome collapses to the composer prompt row:\n'
          '${viewport.join('\n')}',
    );
  }
}

/// Writes the current screen as a `.txt` screenshot twin
/// (`test/integration/screenshots/`, gitignored like the visual suite's).
void _writeShot(FaCliHarness harness, String name) {
  const dir = 'test/integration/screenshots';
  Directory(dir).createSync(recursive: true);
  File('$dir/$name.txt').writeAsStringSync(harness.screenText);
}
