// Key-echo latency probe for the fa TUI (headless).
//
// Reproduces "typing lags while a run streams": seeds a large transcript,
// streams output at a high delta rate (sendOutput per tick, like the CLI's
// per-delta path does — the controller coalesces), sends keys mid-stream,
// and measures the key -> first-paint-after-key latency (what the user
// perceives as echo lag).
//
// Run:
//   dart run tool/key_latency_probe.dart [--lines N] [--seconds S]
// Prints p50/p95/max echo latency in ms + effective paint rate.

import 'dart:async';
import 'dart:io';

import 'package:flutter_agent_harness/src/cli/tui_repl.dart'
    show TuiProgramHooks;
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/compaction/token_estimation.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/types.dart';

int _intArg(List<String> args, String name, int dflt) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return dflt;
  return int.tryParse(args[i + 1]) ?? dflt;
}

String _strArg(List<String> args, String name, String dflt) {
  final i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return dflt;
  return args[i + 1];
}

/// Timestamps every chunk the renderer writes (each chunk = one paint)
/// and sums its byte length — paint COUNT alone hides full-viewport
/// repaints that drown the terminal in bytes.
final class _PaintTap implements StreamConsumer<List<int>> {
  _PaintTap(this.onTap);
  final void Function(int bytes) onTap;

  @override
  Future addStream(Stream<List<int>> stream, {bool cancelOnError = true}) {
    final sub = stream.listen((chunk) => onTap(chunk.length));
    return sub.asFuture<void>();
  }

  @override
  Future close() async {}
}

Future<void> main(List<String> args) async {
  final lines = _intArg(args, '--lines', 4000);
  final seconds = _intArg(args, '--seconds', 3);
  final status = _strArg(args, '--status', 'memo'); // const | memo | full
  final burstLines = _intArg(args, '--burst', 0);
  final sw = Stopwatch()..start();

  // Synthetic agent context for the status scenarios: ~235k tokens of
  // settled messages (the user's oversized session).
  final messages = List<Message>.generate(
    700,
    (i) => UserMessage.text('x' * 1300), // ~325 tokens each -> ~227k total
  );
  final settled = SettledContextEstimate();
  var fullCalls = 0;

  String Function() statusLine;
  switch (status) {
    case 'const':
      statusLine = () =>
          '/probe · ctx 42% (84k/200k) · 84ktok · \$0.0000 · turn 7';
    case 'full': // 0.1.218 behavior: streamLen in the key -> miss per frame
      statusLine = () {
        fullCalls++;
        return 'ctx '
            '${estimateContextTokens(messages).tokens}'
            ' · \$0.0000 · turn 7';
      };
    default: // 0.1.219 behavior: memo keyed on identity+length only
      statusLine = () => 'ctx ${settled.settled(messages)} · \$0.0000 · turn 7';
  }

  final input = StreamController<List<int>>();
  final paintUs = <int>[];
  final paintBytes = <int>[];
  var streamStartUs = 0;
  var streamBytes = 0;
  final hooks = TuiProgramHooks(
    input: input.stream,
    output: _PaintTap((bytes) {
      final now = sw.elapsedMicroseconds;
      paintUs.add(now);
      paintBytes.add(bytes);
      if (streamStartUs > 0) streamBytes += bytes;
    }),
  );

  final controller = FaTuiController(
    callbacks: FaTuiCallbacks(
      onSubmit: (_) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_) => const [],
      statusLine: statusLine,
      prompt: 'fa> ',
    ),
    isExited: () => false,
    programHooks: hooks,
  );

  unawaited(controller.run());
  await Future<void>.delayed(const Duration(milliseconds: 300));
  final bootPaints = paintUs.length;

  // Seed a large mixed transcript (like a long session replay).
  for (var i = 0; i < lines; i++) {
    controller.sendOutput(
      'line $i: Lorem ipsum dolor sit amet, `code` and **bold** tail 中文\n',
      newline: true,
    );
  }
  controller.sendBusy(true);
  await Future<void>.delayed(const Duration(milliseconds: 400));

  // Stream (500 deltas/s, realistic burst) + keys (10/s) for the window.
  final keyUs = <int>[];
  streamStartUs = sw.elapsedMicroseconds;
  final streamTimer = Timer.periodic(const Duration(milliseconds: 2), (_) {
    controller.sendOutput(' streaming chunk ✨ with some more text,');
  });
  final keyTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
    keyUs.add(sw.elapsedMicroseconds);
    input.add('a'.codeUnits);
  });
  // Burst flushes: big tool outputs (file reads, logs) land as one chunk,
  // like a coalescer flush of a whole bash result.
  Timer? burstTimer;
  if (burstLines > 0) {
    burstTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      final buffer = StringBuffer();
      for (var i = 0; i < burstLines; i++) {
        buffer.write('burst $i: tool output line with `code` and tail 中文\n');
      }
      controller.sendOutput(buffer.toString());
    });
  }
  await Future<void>.delayed(Duration(seconds: seconds));
  streamTimer.cancel();
  keyTimer.cancel();
  burstTimer?.cancel();
  await Future<void>.delayed(const Duration(milliseconds: 300));

  // For each key: latency to the first paint strictly after it.
  final latenciesMs = <double>[];
  var paintIdx = 0;
  for (final k in keyUs) {
    while (paintIdx < paintUs.length && paintUs[paintIdx] <= k) {
      paintIdx++;
    }
    if (paintIdx < paintUs.length) {
      latenciesMs.add((paintUs[paintIdx] - k) / 1000);
    }
  }
  latenciesMs.sort();

  String pct(double q) {
    if (latenciesMs.isEmpty) return 'n/a';
    final i = (latenciesMs.length * q).floor().clamp(0, latenciesMs.length - 1);
    return '${latenciesMs[i].toStringAsFixed(1)}ms';
  }

  final windowS = seconds + 0.4;
  print('boot_paints=$bootPaints seeded_lines=$lines keys=${keyUs.length}');
  print(
    'paints_total=${paintUs.length} paint_rate=${(paintUs.length / windowS).toStringAsFixed(1)}/s status=$status full_calls=$fullCalls',
  );
  final streamWindowPaints = paintUs.where((t) => t >= streamStartUs).length;
  final streamPaintBytes = <int>[];
  for (var i = 0; i < paintUs.length; i++) {
    if (paintUs[i] >= streamStartUs) streamPaintBytes.add(paintBytes[i]);
  }
  streamPaintBytes.sort();
  if (streamPaintBytes.isNotEmpty) {
    print(
      'stream_window: paints=$streamWindowPaints bytes/s=${(streamBytes / windowS / 1024).toStringAsFixed(1)}KiB '
      'bytes/paint p50=${streamPaintBytes[streamPaintBytes.length ~/ 2]} p95=${streamPaintBytes[(streamPaintBytes.length * 0.95).floor()]} max=${streamPaintBytes.last}',
    );
  }
  print('echo_latency p50=${pct(0.5)} p95=${pct(0.95)} max=${pct(1.0)}');

  exit(0);
}
