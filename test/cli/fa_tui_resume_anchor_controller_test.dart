// Issue #827 × #503 × #446 wave-14: a RESUMED session's first glass must
// keep the boot chrome AND the replayed tail together. The boot anchors
// the follow window at the restored transcript's start (markReplayAnchor
// before the reconciliation summary + replay writes): the banner above
// rides the fold under the `^ N lines above fold - PgUp` indicator instead
// of pushing the replayed tail's head (the bg-job tool rows) off the
// glass — the wave-14 AC1 regression (the resumed transcript started at
// the task row; the `bash: sleep 2 …` rows were cut).
//
// The first LIVE submit re-arms the turn boundary at its own echo and
// dissolves the boot anchor; any user scroll dissolves it too.
//
// Real controller + real program loop over an in-memory frame sink — no
// PTY, no IO (the PTY suites need a host tty).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show TuiProgramHooks, stripAnsi;
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final chunk in stream) {
      add(chunk);
    }
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

FaTuiCallbacks _callbacks() => FaTuiCallbacks(
  onSubmit: (_, {images = const []}) async {},
  onModelSelected: (_) async {},
  buildSlashMenu: (_) => const [],
  buildModelMenu: (_, _) => const [],
  statusLine: () => 'test',
  prompt: 'fa> ',
);

/// The resumed boot's io sequence (agent_cli_repl_boot.dart order): the
/// banner block, THEN markReplayAnchor, THEN the #503 reconciliation
/// summary, the restored-session header, and the replayed #446-shaped
/// transcript (user echo box, markdown plan, both bash tool rows, the bg
/// settlement notice, the task row, both replies). The settled board card
/// is a FRAME region row (the hub panel), not history.
const _banner = [
  '◆ v1.0.494',
  'esc interrupt · ctrl+c clear · double ctrl+c exit · / commands · ! bash',
  'Press /help to show full commands and resources.',
  '',
  '[Context]',
  '  /tmp/fa_tui_503_x/proj',
  '',
  '[Model]',
  '  mock-model (test-api)',
  '  endpoint: https://example.test',
  '',
  '[Session]',
  '  pty446',
];

const _summary =
    '✗ 1 background task lost on restart '
    '(process gone, no exit reported): sh-1-stale503';

// No blank spacers: the restored region must fit the smallest resumed
// glass (vh 18 at 100x40 on this harness) — the anchor can only keep the
// head when the region FITS; overflow still bottom-rides (by design, the
// tail outranks the head) and the CI fixture overflowed by exactly this.
const _replay = [
  '─── restored session: pty446 (9 messages)',
  '╭─',
  '│ run the pinned probes for four forty six',
  '╰─',
  '>_Fa ## Plan',
  '- run **pinned** probes',
  '1. first step',
  '2. second step',
  '✓ bash · echo pinned-render-1 —',
  '✓ bash · sleep 2 && echo bg-pinned-render —',
  '│ ⚙ background task bash sh-1-ab12 · exited(0) · bg-pinned-render',
  '✓ task · PTY equivalence probe; reply with the single word ok —',
  '>_Fa ok',
  '>_Fa done — the probes settled',
];

final _hint = RegExp(r'\^ (\d+) lines? above fold - PgUp');

int? _hintN(String screen) {
  for (final row in screen.split('\n')) {
    final m = _hint.firstMatch(row);
    if (m != null) return int.parse(m.group(1)!);
  }
  return null;
}

/// Feeds the boot through the controller exactly like the pre-run drain:
/// banner writes, the anchor mark, then the summary + replay + board.
Future<String> _resumedScreen({
  int width = 80,
  int height = 24,
  Future<void> Function(
    FaTuiController,
    StreamController<List<int>>,
    _FrameSink,
  )?
  afterBoot,
}) async {
  final frames = _FrameSink();
  final keys = StreamController<List<int>>();
  final controller = FaTuiController(
    callbacks: _callbacks(),
    isExited: () => false,
    programHooks: TuiProgramHooks(
      input: keys.stream,
      output: frames,
      width: width,
      height: height,
    ),
  );
  for (final line in _banner) {
    controller.sendOutput(line, newline: true);
  }
  // agent_cli_repl_boot.dart: the anchor goes down BEFORE the summary.
  controller.markReplayAnchor();
  controller.sendOutput(_summary, newline: true);
  for (final line in _replay) {
    controller.sendOutput(line, newline: true);
  }
  final run = controller.run();
  await waitForIt(() => frames.text.contains('probes settled'));
  await afterBoot?.call(controller, keys, frames);
  final screen = stripAnsi(frames.text);
  keys.add([0x03]); // press 1 arms the double-press window (#830)
  keys.add([0x03]); // press 2 quits the TUI
  await run;
  await keys.close();
  return screen;
}

void main() {
  for (final (width, height) in [(80, 24), (100, 40)]) {
    test('resumed boot at $width x $height keeps the summary and the WHOLE '
        'replayed tail on the first glass (wave-14 AC1)', () async {
      final screen = await _resumedScreen(width: width, height: height);
      expect(
        screen,
        contains('lost on restart'),
        reason: 'the #503 summary must stay on the first resumed glass',
      );
      for (final row in [
        'restored session: pty446',
        'run the pinned probes',
        'echo pinned-render-1',
        'sleep 2 && echo bg-pinned-render',
        'PTY equivalence probe',
        'done — the probes settled',
      ]) {
        expect(
          screen,
          contains(row),
          reason: 'the replayed tail must not lose its head ($row)',
        );
      }
      // gh-1446 AC1: the streaming fold row is TEXTLESS — the reserved
      // row renders as a plain dim rule, so no row count ever reaches
      // the glass (a rule row cannot leak row counts to shoulder-
      // surfers). Reachability stays pinned at model level in the fold
      // suite (the 13 boot chrome rows fold above and PgUp returns).
      expect(
        _hintN(screen),
        isNull,
        reason: 'no `^ N lines above fold` text survives on the glass',
      );
      expect(
        RegExp('─{$width}').hasMatch(screen),
        isTrue,
        reason:
            'the reserved row renders as the textless dim rule '
            '(the frame stream places it with cursor addressing, so the '
            'probe matches a dash RUN, not a newline-aligned row)',
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('the first LIVE submit dissolves the boot anchor — the window rides '
      'the bottom (#1348)', () async {
    final screen = await _resumedScreen(
      afterBoot: (controller, keys, frames) async {
        keys.add('next turn'.codeUnits);
        keys.add([0x0d]);
        await waitForIt(() => frames.text.contains('next turn'));
      },
    );
    expect(
      screen,
      contains('next turn'),
      reason: 'the new echo is on the glass',
    );
    // The boot anchor dissolved and the window returned to the live edge:
    // the echo sits at the bottom above the composer and the early replay
    // rows fold above it (#1348). frames.text accumulates every glass, so
    // scope to the post-submit frames (everything after the last
    // boot-tail paint).
    final afterSubmit = screen.substring(screen.lastIndexOf('probes settled'));
    expect(
      afterSubmit,
      contains('next turn'),
      reason: 'the new echo is on the post-submit glass',
    );
    expect(
      afterSubmit,
      isNot(contains('run the pinned probes')),
      reason: 'the boot anchor dissolved — the live edge owns the window',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a boot whose transcript fits the glass NEVER folds the banner '
      '(CI round-2 regression: the queue-lag anchor parked the window at '
      'the transcript end and [Model] never reached the glass)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
      programHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 80,
        height: 24,
      ),
    );
    for (final line in _banner) {
      controller.sendOutput(line, newline: true);
    }
    // agent_cli_repl_boot.dart calls markReplayAnchor on EVERY boot —
    // resumed or not. The carried count (13) names the row AFTER the
    // banner; with the banner + nothing else fitting the glass the
    // window must stay at offset 0.
    controller.markReplayAnchor();
    controller.sendOutput(_summary, newline: true);
    final run = controller.run();
    await waitForIt(() => frames.text.contains('lost on restart'));
    final screen = stripAnsi(frames.text);
    expect(
      screen,
      contains('[Model]'),
      reason:
          'the banner paints when everything fits (waitForBoot '
          'sentinel — its absence timed out every PTY suite)',
    );
    expect(
      _hintN(screen),
      isNull,
      reason: 'nothing may fold while the transcript fits the glass',
    );
    keys.add([0x03]);
    keys.add([0x03]);
    await run;
    await keys.close();
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a marathon transcript still rides the bottom — the tail outranks '
      'the boot region when the two cannot share the glass', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = FaTuiController(
      callbacks: _callbacks(),
      isExited: () => false,
      programHooks: TuiProgramHooks(
        input: keys.stream,
        output: frames,
        width: 80,
        height: 24,
      ),
    );
    controller.sendOutput('boot brand row', newline: true);
    controller.markReplayAnchor();
    controller.sendOutput(_summary, newline: true);
    controller.sendOutput(
      '─── restored session: big (2 messages)',
      newline: true,
    );
    for (var i = 0; i < 60; i++) {
      controller.sendOutput('marathon row $i', newline: true);
    }
    final run = controller.run();
    await waitForIt(() => frames.text.contains('marathon row 59'));
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final screen = stripAnsi(frames.text);
    expect(
      screen,
      contains('marathon row 59'),
      reason: 'the tail is the final paint',
    );
    // Bottom-riding: the newest vh-1 rows fill the glass (row 41+ visible,
    // the head folded under the indicator).
    expect(
      screen,
      contains('marathon row 45'),
      reason: 'the bottom ride keeps the deepest tail rows',
    );
    expect(
      screen,
      isNot(contains('marathon row 10 ')),
      reason: 'the head rides the fold on a marathon transcript',
    );
    keys.add([0x03]);
    keys.add([0x03]);
    await run;
    await keys.close();
  }, timeout: const Timeout(Duration(seconds: 60)));
}
