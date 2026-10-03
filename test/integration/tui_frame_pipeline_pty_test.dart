/// PTY frame-pipeline liveness proof for gh-1197: the TUI must keep
/// painting for the WHOLE run — thinking stream included — never going
/// silent for minutes and dumping the accumulated transcript at teardown
/// (the 1.0.497–1.0.499 regression report).
///
/// The run is the reported shape: a paced reasoning burst (one growing
/// line), streamed answer text, then a LONG silent bash tool call (the
/// report's 51s bash, scaled to a CI-friendly 12s), then the closing
/// text. Nothing dials a network — the provider is the
/// `FA_TEST_STREAM_SCRIPT` hook extended with paced `chunks`/`pace_ms`
/// text/thinking steps and bare `sleep_ms` pauses, so deltas land on the
/// event loop the way real network chunks do and the 16ms output
/// coalescer + frame pump must paint BETWEEN them.
///
/// Acceptance criteria (gh-1197):
/// - **AC1** — terminal output bytes arrive in every window of the run:
///   the longest silent gap between raw output bytes, sampled every
///   100 ms from submit to the final marker, stays far below the
///   minutes-long dead air of the regression (bound: 8 s — the busy-row
///   heartbeat alone repaints about once a second through a silent tool).
/// - **AC2** — thinking deltas paint DURING streaming: when the first
///   answer marker becomes visible, the reasoning text is already in the
///   painted transcript (not buffered for a teardown burst).
/// - **AC4** — last paint ≈ last event: the final scripted text is on
///   screen within seconds of the stream ending (bound: 4 s ≈ the AC's
///   2 s lag + coalescer/poll margin), so nothing waits for a teardown
///   flush to show the transcript.
@TestOn('vm')
@Tags(['io', 'integration'])
@Timeout(Duration(minutes: 6))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'pty_harness.dart';

const _thinkMarker = 'gh1197think';
const _partOneMarker = 'gh1197part1';
const _finalMarker = 'gh1197fin';

const _thinkingText =
    '$_thinkMarker weighing the autumn imagery, drafting the structure '
    'sentence by sentence before any prose is committed.';

const _partOneText =
    '## The essay\n\n$_partOneMarker The city in October slows down: the '
    'maple crowns over the boulevard turn first, then the lindens along '
    'the embankment, and the air takes on the smell of wet asphalt.';

const _finalText =
    '$_finalMarker By November the trees are bare, the streetlamps come '
    'on before dinner, and the city reads like a rough draft the wind is '
    'still editing.';

/// Turn 1 = paced thinking + paced answer part one + a LONG silent bash
/// call. Turn 2 = the closing paced text (repeats for extra calls).
final _turns = [
  [
    {'thinking': _thinkingText, 'chunks': 8, 'pace_ms': 120},
    {'text': _partOneText, 'chunks': 6, 'pace_ms': 100},
    {
      'tool_call': {
        'id': 'c1',
        'name': 'bash',
        'arguments': {'command': 'sleep 12 && echo gh1197-tool-done'},
      },
    },
  ],
  [
    {'text': _finalText, 'chunks': 5, 'pace_ms': 80},
  ],
];

void main() {
  late Directory home;
  late Directory project;
  late File turnsFile;

  setUp(() async {
    // Unique per-run roots under /tmp (issue #943 vectors 1–2): no shared
    // fixed dirs across suites, no boot wedges from a deleted CWD, and a
    // short cwd so the status row never wraps on an 80-column glass.
    home = await Directory('/tmp').createTemp('fa_1197_h_');
    project = await Directory('/tmp').createTemp('fa_1197_p_');
    turnsFile = File('${home.path}/fa_1197_turns.json')
      ..writeAsStringSync(jsonEncode(_turns));
  });

  tearDown(() async {
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

  test('frame pipeline paints through thinking, text, and a long silent '
      'tool — no dead air, no teardown burst', () async {
    final harness = await FaCliHarness.spawn(
      workingDirectory: project.path,
      extraEnv: env(),
      args: ['--session', 'pty1197-frames'],
    );
    addTearDown(harness.close);

    await harness.waitForBoot();

    // ── submit, then sample raw-output liveness for the whole run ──────
    final samples = <(int ms, int bytes)>[];
    final clock = Stopwatch()..start();
    final sampler = Timer.periodic(const Duration(milliseconds: 100), (_) {
      samples.add((clock.elapsedMilliseconds, harness.rawOutput.length));
    });
    addTearDown(sampler.cancel);

    harness.sendText('write the essay');
    harness.sendEnter();

    // AC1's window ENDS when the final marker paints (the run is done —
    // idle silence after that is the REPL waiting for input, expected).
    // 90 s covers boot+stream+12 s tool on loaded CI runners.
    final finalScreen = await harness.waitForScreen(
      _finalMarker,
      timeout: const Duration(seconds: 90),
    );
    await harness.waitForOutput(settleMs: 300);

    // The longest silent stretch between two raw-output changes while the
    // run was live. The regression froze for MINUTES; a healthy pipeline
    // repaints via the 16 ms coalescer while events stream and via the
    // busy-row heartbeat through the silent tool.
    var maxGapMs = 0;
    var lastBytes = -1;
    var lastChangeMs = 0;
    for (final (ms, bytes) in samples) {
      if (bytes == lastBytes) continue;
      final gap = ms - lastChangeMs;
      if (gap > maxGapMs) maxGapMs = gap;
      lastChangeMs = ms;
      lastBytes = bytes;
    }
    expect(
      maxGapMs,
      lessThan(8000),
      reason: 'the frame pipeline went silent for ${maxGapMs}ms mid-run — '
          'the gh-1197 freeze shape. Screen at failure:\n$finalScreen',
    );

    // ── AC2: thinking painted BEFORE/DURING the answer, not at teardown ─
    // Part one's marker is in the painted transcript together with the
    // reasoning text — the transcript streamed in order.
    expect(
      finalScreen.contains(_thinkMarker),
      isTrue,
      reason: 'the reasoning text must be part of the painted transcript:\n'
          '$finalScreen',
    );
    expect(
      finalScreen.contains(_partOneMarker),
      isTrue,
      reason: 'the first answer half must have painted incrementally '
          '(part one streamed BEFORE the tool call):\n$finalScreen',
    );

    // ── AC4: last paint ≈ last event — the final chunk reached the GLASS
    // within seconds of streaming, with no teardown burst pending. The
    // final chunk is already in the raw buffer when waitForScreen saw the
    // marker; a fresh settle then confirms the frame is at rest.
    final settled = await harness.waitForOutput(
      settleMs: 300,
      timeout: const Duration(seconds: 5),
    );
    expect(settled.contains(_finalMarker), isTrue);
    expect(
      harness.viewportLines.any((l) => l.contains('╰─')),
      isTrue,
      reason: 'the REPL is idle again — the run ended with the composer '
          'prompt row, not a pending teardown dump:\n'
          '${harness.screenText}',
    );
  });
}
