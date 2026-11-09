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
}
