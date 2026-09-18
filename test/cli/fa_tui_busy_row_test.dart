// Fixed-cell busy-row layout (issue #365): digit growth at a power-of-ten
// second, the 180 s quiet-threshold crossing and mid-run phase swaps must
// never move a column outside the changing cell — the row is laid out in
// fixed zones and padded to the terminal width like the status row.
//
// Busy-row cell map (ANSI stripped): spinner [0,1), space, label zone
// [2,26) (24 cells), space, elapsed field [27,33) (6 cells), then the
// suffix zone from 34 ('· <source>' first, '· quiet Nm' last).
library;

import 'dart:async';

import 'package:dart_tui/dart_tui.dart';

import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_prompt.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart' show MenuItem;
import 'package:flutter_agent_harness/src/tools/ask_tool.dart';
import 'package:test/test.dart';

void main() {
  // ANSI SGR/CSI sequences carry zero cells; stripping them keeps every
  // visible character at its true column.
  final ansi = RegExp(r'\x1b\[[0-9;?]*[A-Za-z]');

  const labelEnd = 26; // spinner + space + 24-cell label zone
  const elapsedStart = 27;
  const elapsedEnd = 33;
  const hintCol = 34; // '· <source>' starts here whenever a source exists

  FaTuiCallbacks callbacks() => FaTuiCallbacks(
    onSubmit: (_, {images = const []}) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => '',
    prompt: '',
  );

  /// A busy model frozen at [elapsed] seconds (with [quiet] seconds of
  /// silence) — deterministic frames without waiting on real time.
  FaTuiModel modelAt(
    int elapsed, {
    String source = 'run',
    int quiet = 0,
    String phase = '',
  }) {
    var model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 80,
    );
    model = model.update(BusyMsg(true, source: source)).$1 as FaTuiModel;
    final now = DateTime.now().millisecondsSinceEpoch;
    return model.copyWith(
      busyStartedAtMs: now - elapsed * 1000,
      busyLastEventMs: now - quiet * 1000,
      busyPhase: phase,
    );
  }

  /// The busy row with escapes stripped — each character sits at its true
  /// terminal column.
  String busyRowOf(FaTuiModel model, {String marker = '· run'}) => model
      .view()
      .content
      .split('\n')
      .map((line) => line.replaceAll(ansi, ''))
      .firstWhere((line) => line.contains(marker));

  test('AC1 UT-stable-width: digit growth never moves label or hints', () {
    final rows = [
      for (final s in [9, 10, 99, 100, 999, 1000]) busyRowOf(modelAt(s)),
    ];
    // Prefix through the label zone is byte-identical across variants.
    expect(
      rows.every(
        (row) =>
            row.substring(0, labelEnd) == rows.first.substring(0, labelEnd),
      ),
      isTrue,
    );
    // The timer grows strictly inside its six cells.
    expect(rows.map((r) => r.substring(elapsedStart, elapsedEnd)).toList(), [
      '    9s',
      '   10s',
      '   99s',
      '  100s',
      '  999s',
      ' 1000s',
    ]);
    // The trailing hint zone keeps its column.
    expect(
      rows.every(
        (row) => row.substring(hintCol) == rows.first.substring(hintCol),
      ),
      isTrue,
    );
  });

  test('AC1: the quiet suffix never moves the provenance hint', () {
    final without = busyRowOf(modelAt(978));
    final withQuiet = busyRowOf(modelAt(978, quiet: 240));
    expect(without, isNot(contains('quiet')));
    expect(withQuiet, contains('quiet 4m'));
    // Everything through the provenance hint is byte-identical.
    final commonEnd = withQuiet.indexOf('· quiet');
    expect(without.substring(0, commonEnd), withQuiet.substring(0, commonEnd));
    expect(without.length, withQuiet.length); // both padded to the width
  });

  test('AC2 UT-quiet-boundary: threshold crossing and a mid-ask delta '
      'change only the quiet zone', () {
    final before = busyRowOf(modelAt(978, quiet: 179));
    final at = busyRowOf(modelAt(978, quiet: 180));
    final afterDelta = busyRowOf(modelAt(978, quiet: 0));
    expect(before, isNot(contains('quiet')));
    expect(at, contains('· quiet 3m'));
    expect(afterDelta, isNot(contains('quiet')));
    // Spinner + label zone + elapsed field are identical in all three.
    final head = at.substring(0, elapsedEnd);
    for (final row in [before, afterDelta]) {
      expect(row.substring(0, elapsedEnd), head);
    }
  });

  test('E2: a mid-run phase swap never shifts the timer or the hints', () {
    final working = busyRowOf(modelAt(978));
    final ask = busyRowOf(modelAt(978, phase: 'Running ask..'));
    expect(ask, contains('Running ask..'));
    // The swap lives inside the label zone only.
    expect(working.substring(0, 2), ask.substring(0, 2));
    expect(working.substring(elapsedStart), ask.substring(elapsedStart));
    // An overlong label ellipsizes INSIDE the zone.
    final long = busyRowOf(
      modelAt(978, phase: 'Compacting context… 999999 tokens'),
    );
    expect(long.substring(elapsedStart), working.substring(elapsedStart));
    expect(long.substring(2, labelEnd), endsWith('…'));
    expect(long.length, working.length);
  });

  test('E3: hours degrade inside the fixed field; unset clocks read 0s', () {
    String fieldAt(int seconds) =>
        busyRowOf(modelAt(seconds)).substring(elapsedStart, elapsedEnd);
    expect(fieldAt(3599), ' 3599s');
    expect(fieldAt(3600), ' 1h00m');
    expect(fieldAt(3661), ' 1h01m');
    expect(fieldAt(359999), '99h59m');
    expect(fieldAt(360000), '  99h+'); // clamped: the field never overflows
    final noClock = modelAt(
      978,
    ).copyWith(busyStartedAtMs: -1, busyLastEventMs: -1);
    expect(busyRowOf(noClock).substring(elapsedStart, elapsedEnd), '    0s');
  });

  test('issue #539 AC4: the auto-compact badge rides the fixed label zone '
      'at 80/120/200 and the hour timer never shifts it', () {
    const badge = 'Working… [auto-compacted · continuing]';
    for (final width in [80, 120, 200]) {
      FaTuiModel resized(FaTuiModel model) =>
          model.update(WindowSizeMsg(width, 30)).$1 as FaTuiModel;
      final withBadge = busyRowOf(resized(modelAt(3722, phase: badge)));
      final without = busyRowOf(resized(modelAt(3722)));
      // The badge clips INSIDE the 24-cell label zone: everything from the
      // elapsed field on keeps its exact column at every width.
      expect(
        withBadge.substring(elapsedStart),
        without.substring(elapsedStart),
        reason: 'width $width: ${withBadge.length} cells',
      );
      expect(withBadge.length, width, reason: 'width $width');
      expect(
        withBadge.substring(2, labelEnd),
        contains('[auto-compact'),
        reason: 'width $width: the badge is visible in the label zone',
      );
      // The 1h+ timer degrades inside its six cells with the badge up.
      expect(
        busyRowOf(
          modelAt(3722, phase: badge),
        ).substring(elapsedStart, elapsedEnd),
        ' 1h02m',
      );
    }
  });

  test('E1: a mid-run resize keeps the alignment rules', () {
    var model = modelAt(978);
    model = model.update(WindowSizeMsg(120, 30)).$1 as FaTuiModel;
    final row = busyRowOf(model);
    expect(row.length, 120);
    expect(row.indexOf('· run'), hintCol);
    expect(row.substring(elapsedStart, elapsedEnd), '  978s');
  });

  test('AC3 IT-prompt-open: consecutive frames never move a column '
      'outside the fixed elapsed field', () {
    var model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 80,
    );
    model = model.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    model =
        model
                .update(
                  OpenPromptMsg(
                    const AskPromptSpec(
                      header: 'Ask',
                      question: 'Pick one:',
                      index: 0,
                      total: 1,
                      options: [
                        AskOption(label: 'a'),
                        AskOption(label: 'b'),
                      ],
                    ),
                    Completer<TuiPromptAnswer?>(),
                  ),
                )
                .$1
            as FaTuiModel;
    expect(model.prompt, isNotNull);

    // Fake tick pump: the ask stays open across the power-of-ten seconds.
    final now = DateTime.now().millisecondsSinceEpoch;
    final rows = <String>[];
    for (final s in [0, 9, 10, 11, 99, 100, 978, 999, 1000]) {
      model = model.copyWith(busyStartedAtMs: now - s * 1000);
      model = model.update(SpinnerTickMsg()).$1 as FaTuiModel;
      rows.add(busyRowOf(model));
    }
    // Every frame paints exactly termWidth cells: the tail is overwritten
    // in place and any parked cursor column is stable.
    for (final row in rows) {
      expect(row.length, 80);
    }
    // The provenance hint keeps its column across every frame.
    expect(rows.map((r) => r.indexOf('· run')).toSet().length, 1);
    // The elapsed field grows strictly inside its six cells.
    expect(rows.first.substring(elapsedStart, elapsedEnd), '    0s');
    expect(rows.last.substring(elapsedStart, elapsedEnd), ' 1000s');
  });

  test('the host-picker waiting row is padded to the width too', () {
    var model = modelAt(978);
    model =
        model
                .update(
                  OpenPickerMsg('wizard:x', 'Pick one', const [
                    MenuItem(key: 'a', label: 'A'),
                  ]),
                )
                .$1
            as FaTuiModel;
    final row = model
        .view()
        .content
        .split('\n')
        .map((l) => l.replaceAll(ansi, ''))
        .firstWhere((l) => l.contains('waiting for your selection'));
    expect(row.length, 80);
  });

  test('the prompt mode busy row shows Waiting for input', () {
    var model = modelAt(978);
    model = model.copyWith(
      prompt: TuiPromptState(SecretPromptSpec(name: 'KEY', reason: 'r')),
    );
    final row = model
        .view()
        .content
        .split('\n')
        .map((l) => l.replaceAll(ansi, ''))
        .firstWhere((l) => l.contains('Waiting for input'));
    expect(row.length, 80);
  });

  test('prompt mode view crops to glass when lines exceed terminal height', () {
    final model = FaTuiModel(
      callbacks: callbacks(),
      isExited: () => false,
      termWidth: 80,
      termHeight: 15,
    ).copyWith(
      jobBoardLines: List.generate(20, (i) => 'job-$i test'),
      prompt: TuiPromptState(SecretPromptSpec(name: 'KEY', reason: 'r')),
    );
    final lines = model.view().content.split('\n');
    expect(lines.length, lessThanOrEqualTo(15));
  });

  test('the queued overlay paints scheduled rows, clipped job lines and '
      'waiting rows while idle-waiting', () {
    final now = DateTime.now().millisecondsSinceEpoch;
    final model =
        FaTuiModel(
          callbacks: callbacks(),
          isExited: () => false,
          termWidth: 80,
        ).copyWith(
          scheduledCount: 2,
          scheduledNextDueMs: now + 60000,
          jobBoardLines: List.generate(3, (i) => 'job-$i ${'x' * 120}'),
          waitingJobs: List.generate(2, (i) => 'sleep $i'),
          waitingTimers: const [(dueMs: 1, preview: 'check CI')],
        );
    final plain = model
        .view()
        .content
        .split('\n')
        .map((l) => l.replaceAll(ansi, ''))
        .toList();
    expect(
      plain.where((l) => l.contains('2 scheduled')),
      isNotEmpty,
      reason: 'the scheduled row sits on top of the working row',
    );
    expect(plain.where((l) => l.contains('job-0')), isNotEmpty);
    final clipped = plain.firstWhere((l) => l.contains('job-0'));
    expect(
      clipped.length,
      lessThanOrEqualTo(80),
      reason: 'long job lines are clipped to the live width',
    );
    expect(
      plain.where((l) => l.contains('⏳ waiting')),
      isNotEmpty,
      reason: 'the waiting row follows the queue rows',
    );
  });

  test('issue #514: the stall push flips the row to Stalled… and back '
      'without touching the elapsed window or the quiet clock', () {
    final wedged = modelAt(473, quiet: 200);
    final stalled = wedged.update(const RunStalledMsg(true)).$1 as FaTuiModel;
    final row = busyRowOf(stalled, marker: 'Stalled…');
    expect(row, contains('Stalled…'));
    // The elapsed window survives the relabel — a stall is a STATE on the
    // same bracket, not a restart of it.
    expect(row.substring(elapsedStart, elapsedEnd), '  473s');
    // The push is busy bookkeeping: it must NOT refresh the quiet clock
    // (the stall keeps deepening while the row says Stalled…).
    final quietSeconds =
        (DateTime.now().millisecondsSinceEpoch - stalled.busyLastEventMs) ~/
        1000;
    expect(quietSeconds, greaterThanOrEqualTo(200));
    // The classifier clearing returns the live label.
    final awake = stalled.update(const RunStalledMsg(false)).$1 as FaTuiModel;
    expect(busyRowOf(awake), contains('Working…'));
    expect(awake.runStalled, isFalse);
  });

  test('issue #514: the busy→idle bracket always starts unstalled', () {
    final stalled =
        modelAt(10).update(const RunStalledMsg(true)).$1 as FaTuiModel;
    expect(stalled.runStalled, isTrue);
    final idle =
        stalled.update(const BusyMsg(false, source: 'run')).$1 as FaTuiModel;
    expect(idle.runStalled, isFalse);
    final next =
        idle.update(const BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    expect(next.runStalled, isFalse);
  });
}
