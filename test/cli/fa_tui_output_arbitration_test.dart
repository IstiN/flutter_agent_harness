// Issue #2069 [GOAL] TUI output arbitration: every line printed while the
// live region (busy row + status band) is active must reach the terminal
// through ONE renderer-owned arbiter — the controller's output seam —
// never interleaved with the frame painter's own writes.
//
// The arbitration shape on the current architecture:
//   - io.write/io.writeln route through _TuiCliIO → FaTuiController
//     .sendOutput → the coalescing output buffer → OutputMsg → the
//     program's single message queue; the busy-row label swaps, job
//     board pushes, and footer repaints ride the same queue, and frames
//     render atomically (BSU/ESU when DEC 2026 is on, serialized
//     clear+redraw otherwise). The steering/watchdog/job/compaction
//     notice writers all ride it.
//   - The line-boundary rule (#2069): a newline-terminated write is a
//     COMPLETE line; when the output buffer holds an unterminated
//     streamed delta it closes that line first, so a notice never glues
//     onto the mid-word tail of streamed answer text (the "two sources
//     on one row" artifact class from the incident screenshots).
//   - Session-rotation warnings route through the CLI's io — the stderr
//     default printed raw over the live region mid-run (appendEntry
//     rotations fire while the TUI owns the terminal).
//
// Row-level proof shape: the renderer homes EVERY painted row with an
// absolute `\x1b[{row};1H` sequence, so two sources that share a row
// appear as one contiguous byte run, while sources on different rows are
// always separated by a home sequence. Asserting the ABSENCE of the
// glued literal ("…tail" + "notice…") in the raw byte stream is therefore
// exactly the "no row carries glyphs from two sources" contract — no
// ANSI-stripped reassembly needed (stripping is what fabricates fake
// adjacency across row boundaries).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:test/test.dart';

import 'agent_cli_test_support.dart';

/// Collects rendered frame bytes (dart_tui wraps this into an IOSink).
class _FrameSink implements StreamConsumer<List<int>> {
  final _bytes = BytesBuilder(copy: false);

  void add(List<int> data) => _bytes.add(data);

  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.forEach(add);
  }

  @override
  Future<void> close() async {}

  String get text => utf8.decode(_bytes.toBytes(), allowMalformed: true);
}

FaTuiCallbacks _callbacks() {
  return FaTuiCallbacks(
    onSubmit: (line, {images = const []}) async {},
    onSteer: (messages) async {},
    onModelSelected: (_) async {},
    buildSlashMenu: (_) => const [],
    buildModelMenu: (_, _) => const [],
    statusLine: () => 'test',
    prompt: 'fa> ',
  );
}

FaTuiController _controller(
  _FrameSink frames,
  StreamController<List<int>> keys, {
  bool? syncOutput,
}) {
  return FaTuiController(
    callbacks: _callbacks(),
    isExited: () => false,
    syncOutput: syncOutput,
    programHooks: TuiProgramHooks(
      input: keys.stream,
      output: frames,
      width: 100,
      height: 30,
    ),
  );
}

/// The #2069 storm shape at the model level: the arbiter's POST-boundary
/// output units, driven through the same message seam the program
/// consumes. A notice following an open delta tail arrives as the flushed
/// buffer text the fixed controller emits — boundary '\n', notice,
/// terminator ('\nnotice…\n') — never glued onto the tail. Returns the
/// final model.
FaTuiModel _stormModel(FaTuiModel model) {
  model = model.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
  for (var i = 0; i < 100; i++) {
    model =
        model.update(OutputMsg('delta chunk of streamed answer text')).$1
            as FaTuiModel;
    model =
        model
                .update(
                  OutputMsg('\nnotice — steering interrupt fired mid-run\n'),
                )
                .$1
            as FaTuiModel;
    if (i % 10 == 0) {
      model = model.update(JobBoardMsg(['job board row'])).$1 as FaTuiModel;
    }
    if (i % 25 == 0) {
      model =
          model
                  .update(
                    BusyMsg(
                      true,
                      source: 'compaction',
                      phase: 'Compacting context…',
                    ),
                  )
                  .$1
              as FaTuiModel;
    }
  }
  model =
      model
              .update(
                OutputMsg(
                  '\nwatchdog paused — over-window compaction in progress\n',
                ),
              )
              .$1
          as FaTuiModel;
  return model;
}

void main() {
  test(
    'a notice writeln never glues onto an unterminated streamed delta (AC2a)',
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final controller = _controller(frames, keys);
      // Pre-run canary: parks in the pending queue, flushes at the run
      // drain — the first paint proves the program is live (#503 shape).
      controller.sendOutput('canary-one', newline: true);
      final run = controller.run();
      try {
        await waitForIt(() => frames.text.contains('canary-one'));
        controller.sendBusy(true, source: 'run');
        // Streamed answer delta — write() semantics, line still open.
        controller.sendOutput('The refactor is nearly done, remaining work is');
        // The incident's writers, arriving mid-stream.
        controller.sendOutput(
          'steering queued — provider stalled 131 seconds, '
          'interrupting to deliver',
          newline: true,
        );
        controller.sendOutput(
          'steering delivered into rebuilt request',
          newline: true,
        );
        await waitForIt(
          () => frames.text.contains('steering delivered into rebuilt request'),
        );
        // The glued artifact — the literal pre-fix byte shape (the notice
        // concatenated onto the delta's open tail, one painted row).
        expect(
          frames.text.contains('remaining work issteering queued'),
          isFalse,
          reason: 'the notice glued onto the streamed delta tail',
        );
        // Both notices reached the glass intact.
        expect(
          frames.text.contains(
            'steering queued — provider stalled 131 seconds, '
            'interrupting to deliver',
          ),
          isTrue,
        );
        expect(
          frames.text.contains('steering delivered into rebuilt request'),
          isTrue,
        );
        // Plain write() deltas still merge (streaming shape unchanged).
        expect(frames.text.contains('The refactor is nearly done'), isTrue);
      } finally {
        keys.add([0x03]); // press 1 arms the double-press window (#830)…
        keys.add([0x03]); // …press 2 quits the TUI
        await run;
        await keys.close();
      }
    },
  );

  test(
    'busy-row relabel + watchdog notice + repaint render clean rows (AC2b)',
    () async {
      final frames = _FrameSink();
      final keys = StreamController<List<int>>();
      final controller = _controller(frames, keys);
      controller.sendOutput('canary-one', newline: true);
      final run = controller.run();
      try {
        await waitForIt(() => frames.text.contains('canary-one'));
        controller.sendBusy(true, source: 'run');
        // The incident-2 writer mix: the busy-row label transition, the
        // raw watchdog notice, and the footer repaint in flight together.
        controller.setBusyPhase('Compacting context…');
        controller.sendOutput(
          'watchdog paused — over-window compaction in progress',
          newline: true,
        );
        await waitForIt(
          () => frames.text.contains(
            'watchdog paused — over-window compaction in progress',
          ),
        );
        expect(
          frames.text.contains('Compacting context…'),
          isTrue,
          reason: 'the busy row must carry the phase label whole',
        );
        expect(
          frames.text.contains('Compacting context…watchdog'),
          isFalse,
          reason: 'the watchdog notice glued onto the busy-row label',
        );
      } finally {
        keys.add([0x03]);
        keys.add([0x03]);
        await run;
        await keys.close();
      }
    },
  );

  test('notice storm keeps every frame row single-source (AC1)', () {
    // The storm drives the same message seam the program consumes; the
    // VIEW is the frame the renderer paints, so the row contract is
    // asserted on the composed frame itself.
    final model = _stormModel(
      FaTuiModel(callbacks: _callbacks(), isExited: () => false),
    );
    final rows = model.view().content.split('\n');
    final glass = rows.join('\n');
    // Every notice lands intact, and the tail of the storm is on screen
    // (the window follows the live edge while live).
    expect(
      glass.contains('notice — steering interrupt fired mid-run'),
      isTrue,
      reason: 'the notice lines must survive the storm intact',
    );
    expect(
      glass.contains('watchdog paused — over-window compaction in progress'),
      isTrue,
      reason: 'the trailing watchdog notice must be on the glass',
    );
    // No frame row carries glyphs from two writers.
    for (final row in rows) {
      final sources = [
        if (row.contains('delta chunk')) 'delta',
        if (row.contains('notice —')) 'notice',
        if (row.contains('Compacting context…')) 'busy-label',
        if (row.contains('watchdog paused')) 'watchdog',
        if (row.contains('job board row')) 'job-board',
      ];
      expect(
        sources.toSet().length,
        lessThanOrEqualTo(1),
        reason:
            'a row merged two writers: "${row.length > 90 ? row.substring(0, 90) : row}"',
      );
    }
    // The busy row carries the phase label whole.
    expect(rows.any((row) => row.contains('Compacting context…')), isTrue);
    expect(
      rows.any((row) => row.contains('job board row')),
      isTrue,
      reason: 'job board pushes must survive the storm',
    );
  });

  test(
    'painted frames stay BSU/ESU-balanced; sync-off carries none (AC4)',
    () async {
      // Balance under the incident's shape (busy row + notices + relabel);
      // the frame-atomicity contract is the renderer's, and every painted
      // frame must open and close its synchronized-update region.
      Future<String> paint({
        required bool? syncOutput,
        required String canary,
      }) async {
        final frames = _FrameSink();
        final keys = StreamController<List<int>>();
        final controller = _controller(frames, keys, syncOutput: syncOutput);
        controller.sendOutput(canary, newline: true);
        final run = controller.run();
        try {
          await waitForIt(() => frames.text.contains(canary));
          controller.sendBusy(true, source: 'run');
          controller.sendOutput('delta tail mid-word');
          controller.sendOutput(
            'steering queued — interrupting to deliver',
            newline: true,
          );
          controller.setBusyPhase('Compacting context…');
          controller.sendOutput(
            'watchdog paused — over-window compaction in progress',
            newline: true,
          );
          await waitForIt(
            () => frames.text.contains(
              'watchdog paused — over-window compaction in progress',
            ),
          );
          return frames.text;
        } finally {
          keys.add([0x03]);
          keys.add([0x03]);
          await run;
          await keys.close();
        }
      }

      final syncOn = await paint(syncOutput: true, canary: 'canary-sync-on');
      final opens = '?2026h'.allMatches(syncOn).length;
      final closes = '?2026l'.allMatches(syncOn).length;
      expect(opens, greaterThan(0), reason: 'DEC 2026 framing must be active');
      expect(
        opens,
        equals(closes),
        reason: 'a stranded BSU defers every later paint (gh-1197 class)',
      );
      // The glue contract holds in the framed stream too.
      expect(syncOn.contains('mid-wordsteering queued'), isFalse);

      final syncOff = await paint(syncOutput: false, canary: 'canary-sync-off');
      // DECRQM capability probes (`?2026$p`) still go out at boot; the
      // FRAMING sequences must not.
      expect(syncOff.contains('?2026h'), isFalse);
      expect(syncOff.contains('?2026l'), isFalse);
      expect(
        syncOff.contains(
          'watchdog paused — over-window compaction in progress',
        ),
        isTrue,
      );
    },
  );

  test('line mode keeps the caller io unwrapped (AC5 passthrough)', () {
    final prevWarning = JsonlSessionStorage.onRotationWarning;
    try {
      AgentCliConfig config() => AgentCliConfig(
        model: testModel,
        apiKey: 'test-key',
        env: MemoryExecutionEnv(cwd: '/work'),
        sessionRoot: '/sessions',
        providerKind: 'openai-completions',
        skillsAccess: SkillsAccess.granted,
      );
      // No raw-mode terminal: even useTui stays on the caller's io.
      final noRaw = SplitChannelCliIO();
      final cliNoRaw = AgentCli(config: config(), io: noRaw, useTui: true);
      expect(cliNoRaw.io, same(noRaw));
      // Line mode explicitly: the caller io passes through unwrapped.
      final raw = FakeCliIO();
      final cliLine = AgentCli(config: config(), io: raw, useTui: false);
      expect(cliLine.io, same(raw));
    } finally {
      JsonlSessionStorage.onRotationWarning = prevWarning;
    }
  });

  test(
    'no raw stdout/print sinks anywhere in the CLI notice surface (AC3)',
    () {
      // Triple-quoted strings carry scenario/doc prose (e.g. the omp parity
      // fixture's fenced `print('hello omp parity')` snippet) — not sinks.
      final blockStrings = RegExp("'''[\\s\\S]*?'''|\"\"\"[\\s\\S]*?\"\"\"");
      final rawStdout = RegExp(r'stdout\.(write|writeln)');
      final barePrint = RegExp(r'^\s*print\(', multiLine: true);
      final offenders = <String>[];
      for (final entity in Directory('lib/src/cli').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final source = entity.readAsStringSync().replaceAll(blockStrings, '');
        if (rawStdout.hasMatch(source) || barePrint.hasMatch(source)) {
          offenders.add(entity.path);
        }
      }
      expect(
        offenders,
        isEmpty,
        reason:
            'mid-run prints must route through the CliIO arbiter (#2069) — '
            'raw sinks: $offenders',
      );
    },
  );

  test('session-rotation warnings route through the CLI notice channel', () {
    final prevWarning = JsonlSessionStorage.onRotationWarning;
    try {
      final io = FakeCliIO();
      AgentCli(
        config: AgentCliConfig(
          model: testModel,
          apiKey: 'test-key',
          env: MemoryExecutionEnv(cwd: '/work'),
          sessionRoot: '/sessions',
          providerKind: 'openai-completions',
          skillsAccess: SkillsAccess.granted,
        ),
        io: io,
        useTui: false,
      );
      JsonlSessionStorage.onRotationWarning?.call(
        'session rotation: primary.jsonl -> primary.part-1',
      );
      expect(
        io.out.toString(),
        contains('session rotation: primary.jsonl -> primary.part-1'),
        reason:
            'a mid-run rotation warning must not bypass the arbiter '
            'with a raw stderr write',
      );
    } finally {
      JsonlSessionStorage.onRotationWarning = prevWarning;
    }
  });

  // ── gh-2094: the flush drain must not lose the arbiter's tail-open
  // truth. _flushOutput() used to reset _outputTailOpen unconditionally,
  // so a newline-terminated write (settled tool card, notice) that
  // followed an unterminated write ACROSS a flush lost its boundary
  // newline and glued onto the painted mid-line tail.

  /// The grid row the renderer painted [needle]'s first occurrence on:
  /// the row of the last absolute home sequence (`ESC[row;colH`) emitted
  /// before the needle's first byte. The row-level proof shape for
  /// gh-2094 — glue means "the two texts painted on the same row", the
  /// boundary means "separate rows" — regardless of whether the second
  /// paint re-addressed the cursor or continued it.
  int? paintedRowOf(String frames, String needle) {
    final at = frames.indexOf(needle);
    if (at < 0) return null;
    final homes = RegExp(
      r'\x1b\[(\d+);(\d+)H',
    ).allMatches(frames.substring(0, at));
    if (homes.isEmpty) return null;
    return int.parse(homes.last.group(1)!);
  }

  test('gh-2094: flush between the running and settled card keeps the '
      'boundary — no glue (AC1)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = _controller(frames, keys);
    controller.sendOutput('canary-one', newline: true);
    final run = controller.run();
    try {
      await waitForIt(() => frames.text.contains('canary-one'));
      controller.sendBusy(true, source: 'run');
      // The incident shape: the running tool card is written
      // unterminated (plain write — the row expects in-place
      // continuation). The busy flip carries no buffered text (the
      // non-output flush no-ops on the empty buffer), so the card's
      // flush below is the TIMER's — the incident's trigger.
      controller.sendOutput('◐ agent_message: msg_1');
      // Waiting for the glass also proves _flushOutput() already ran:
      // the row is PAINTED mid-line before the settle arrives.
      await waitForIt(() => frames.text.contains('agent_message: msg_1'));
      // The settled card is a newline-terminated write — a COMPLETE
      // line (#2069 rule): it must open on a fresh row even though the
      // running card was already flushed out of the buffer.
      controller.sendOutput('✔ agent_message: msg_1 0s', newline: true);
      await waitForIt(() => frames.text.contains('agent_message: msg_1 0s'));
      final runRow = paintedRowOf(frames.text, '◐ agent_message: msg_1');
      final settledRow = paintedRowOf(frames.text, '✔ agent_message: msg_1 0s');
      expect(settledRow, isNotNull, reason: 'the settled card must paint');
      expect(
        settledRow,
        isNot(equals(runRow)),
        reason:
            'the settled card glued onto the flushed running card tail '
            '(rows $runRow/$settledRow) — the flush lost the tail-open '
            'truth',
      );
      // The pre-fix byte shape, when both cards share one contiguous
      // paint run — also forbidden.
      expect(
        frames.text.contains('agent_message: msg_1✔'),
        isFalse,
        reason: 'the settled card glued onto the running card tail',
      );
      expect(frames.text.contains('◐ agent_message: msg_1'), isTrue);
      expect(frames.text.contains('✔ agent_message: msg_1 0s'), isTrue);
    } finally {
      keys.add([0x03]); // press 1 arms the double-press window (#830)…
      keys.add([0x03]); // …press 2 quits the TUI
      await run;
      await keys.close();
    }
  });

  test('gh-2094: the tail flag equals the flushed-text truth after every '
      'real flush; an empty flush leaves it untouched (AC2)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = _controller(frames, keys);
    controller.sendOutput('canary-one', newline: true);
    final run = controller.run();
    try {
      await waitForIt(() => frames.text.contains('canary-one'));
      // Unterminated write → real flush → the painted tail is OPEN.
      controller.sendOutput('unterminated tail one');
      await waitForIt(() => frames.text.contains('unterminated tail one'));
      expect(
        controller.outputTailOpenForTest,
        isTrue,
        reason:
            'state-truth invariant: after a real flush the flag must '
            'equal !flushedText.endsWith("\\n") — the flushed text is '
            'unterminated, the painted tail is open',
      );
      // Terminated write → real flush → the painted tail is CLOSED.
      controller.sendOutput('complete line\n');
      await waitForIt(() => frames.text.contains('complete line'));
      expect(
        controller.outputTailOpenForTest,
        isFalse,
        reason: 'the flushed text ended with a newline — tail closed',
      );
      // Each flush re-derives truth from its own text — no drift.
      controller.sendOutput('unterminated tail two');
      await waitForIt(() => frames.text.contains('unterminated tail two'));
      expect(controller.outputTailOpenForTest, isTrue);
      // An empty-buffer flush (the timer fires after the buffer was
      // already drained) must not touch the flag — the early-return
      // ordering stays BEFORE any reset.
      controller.sendOutput(''); // arms the timer on an empty buffer
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(
        controller.outputTailOpenForTest,
        isTrue,
        reason: 'an empty flush must leave the tail flag untouched',
      );
    } finally {
      keys.add([0x03]);
      keys.add([0x03]);
      await run;
      await keys.close();
    }
  });

  test('gh-2094: plain unterminated deltas still merge into one paragraph '
      'across flushes (AC3 REG)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = _controller(frames, keys);
    controller.sendOutput('canary-one', newline: true);
    final run = controller.run();
    try {
      await waitForIt(() => frames.text.contains('canary-one'));
      // Plain write() deltas, each riding its own flush (#2069 shape —
      // streaming paragraphs must stay byte-identical to the
      // pre-gh-2094 behavior; the fix must not adopt the retracted
      // "always append '\n' on flush" alternative).
      controller.sendOutput('streamed alpha');
      await waitForIt(() => frames.text.contains('streamed alpha'));
      controller.sendOutput(' continued beta');
      await waitForIt(() => frames.text.contains(' continued beta'));
      controller.sendOutput(' continued gamma');
      await waitForIt(() => frames.text.contains(' continued gamma'));
      final alphaRow = paintedRowOf(frames.text, 'streamed alpha');
      final betaRow = paintedRowOf(frames.text, ' continued beta');
      final gammaRow = paintedRowOf(frames.text, ' continued gamma');
      expect(
        betaRow,
        equals(alphaRow),
        reason:
            'a flush must not split the streamed paragraph (rows '
            '$alphaRow/$betaRow)',
      );
      expect(
        gammaRow,
        equals(alphaRow),
        reason:
            'a flush must not split the streamed paragraph (rows '
            '$alphaRow/$gammaRow)',
      );
    } finally {
      keys.add([0x03]);
      keys.add([0x03]);
      await run;
      await keys.close();
    }
  });

  test('gh-2094: the #2069 merge golden over the emitted stream — flushed '
      'deltas concatenate, flushes never inject a newline (AC3)', () {
    // The flush drain emits OutputMsg(text) VERBATIM — never with an
    // appended terminator (the retracted "always append '\n' on flush"
    // shape would land every flushed delta on its own row). Golden: N
    // deltas, each riding its own flush emission, compose ONE
    // paragraph row.
    var model = FaTuiModel(callbacks: _callbacks(), isExited: () => false);
    model = model.update(BusyMsg(true, source: 'run')).$1 as FaTuiModel;
    for (final delta in [
      'streamed alpha',
      ' continued beta',
      ' continued gamma',
    ]) {
      model = model.update(OutputMsg(delta)).$1 as FaTuiModel;
    }
    final rows = model.view().content.split('\n');
    expect(
      rows
          .where(
            (row) =>
                row.contains('streamed alpha continued beta continued gamma'),
          )
          .length,
      1,
      reason:
          'plain unterminated deltas must merge into exactly one '
          'paragraph row across flushes (#2069)',
    );
  });

  test('gh-2094: a notice landing mid-card (after a flush) keeps its own '
      'row, the settled card the next one (AC4 REG)', () async {
    final frames = _FrameSink();
    final keys = StreamController<List<int>>();
    final controller = _controller(frames, keys);
    controller.sendOutput('canary-one', newline: true);
    final run = controller.run();
    try {
      await waitForIt(() => frames.text.contains('canary-one'));
      controller.sendBusy(true, source: 'run');
      // Running card painted mid-line (flush timer fired first —
      // waitForIt proves the flush ran).
      controller.sendOutput('◐ read_file: lib/main.dart');
      await waitForIt(() => frames.text.contains('read_file: lib/main.dart'));
      // The #2069 scenario across a flush: the notice is a
      // newline-terminated write — it must render intact on its OWN
      // row, never glued onto the painted card tail.
      controller.sendOutput(
        'notice — steering interrupt fired mid-run',
        newline: true,
      );
      await waitForIt(
        () => frames.text.contains('notice — steering interrupt fired mid-run'),
      );
      // The settled card follows on the next row — ordering preserved.
      controller.sendOutput('✔ read_file: lib/main.dart 12ms', newline: true);
      await waitForIt(
        () => frames.text.contains('read_file: lib/main.dart 12ms'),
      );
      final runRow = paintedRowOf(frames.text, '◐ read_file: lib/main.dart');
      final noticeRow = paintedRowOf(
        frames.text,
        'notice — steering interrupt fired mid-run',
      );
      final settledRow = paintedRowOf(
        frames.text,
        '✔ read_file: lib/main.dart 12ms',
      );
      expect(noticeRow, isNotNull, reason: 'the notice must paint');
      expect(settledRow, isNotNull, reason: 'the settled card must paint');
      expect(
        noticeRow,
        isNot(equals(runRow)),
        reason:
            'the notice glued onto the flushed running card tail '
            '(rows $runRow/$noticeRow)',
      );
      expect(
        settledRow,
        isNot(equals(noticeRow)),
        reason:
            'the settled card glued onto the notice row '
            '(rows $noticeRow/$settledRow)',
      );
      expect(
        frames.text.contains('lib/main.dartnotice'),
        isFalse,
        reason: 'the notice glued onto the running card tail',
      );
      expect(
        frames.text.contains('mid-run✔'),
        isFalse,
        reason: 'the settled card glued onto the notice row',
      );
    } finally {
      keys.add([0x03]);
      keys.add([0x03]);
      await run;
      await keys.close();
    }
  });
}
