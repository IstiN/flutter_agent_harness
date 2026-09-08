// Typing-latency bench for the fa TUI under a thinking-stream flood.
//
// Reproduces issue #43: while reasoning deltas stream in (the exact write
// pattern AgentCli produces — `_style.dim(delta)` per delta through
// sendOutput), measure how long a typed key takes to appear on screen.
//
// Usage: dart run tool/tui_typing_bench.dart [flags]
//   --flood           stream thinking deltas at ~100/s (default off)
//   --grow-tail       flood WITHOUT newlines: one tail line grows to the
//                     32KB hard-split cap and keeps re-flowing (the real
//                     minutes-long-paragraph shape)
//   --seconds N       run duration (default 15)
//   --width/--height  pinned terminal size (default 120x40)
//
// Echo latency is measured from the FA_TUI_TRACE JSONL (stdin→paint pairs,
// same microsecond clock): pass FA_TUI_TRACE=<path> and post-process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_tui/dart_tui.dart';
import 'package:flutter_agent_harness/src/cli/fa_tui.dart';
import 'package:flutter_agent_harness/src/cli/tui_repl.dart';
import 'package:flutter_agent_harness/src/cli/ansi_markdown.dart';

/// Consumes rendered frame bytes; counts volume only.
final class _FrameSink implements StreamConsumer<List<int>> {
  _FrameSink(this.onChunk);

  final void Function(List<int> chunk) onChunk;
  StreamSubscription<List<int>>? _sub;

  @override
  Future<void> addStream(Stream<List<int>> stream) {
    _sub = stream.listen(onChunk, onError: (Object _) {});
    return Future<void>.value();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> close() async {
    await _sub?.cancel();
  }
}

void main(List<String> args) async {
  final flood = args.contains('--flood') || args.contains('--grow-tail');
  final growTail = args.contains('--grow-tail');
  final secondsIdx = args.indexOf('--seconds');
  final seconds = secondsIdx >= 0 ? int.parse(args[secondsIdx + 1]) : 15;
  final widthIdx = args.indexOf('--width');
  final heightIdx = args.indexOf('--height');
  final width = widthIdx >= 0 ? int.parse(args[widthIdx + 1]) : 120;
  final height = heightIdx >= 0 ? int.parse(args[heightIdx + 1]) : 40;

  var frameBytes = 0;
  var chunkCount = 0;
  final sink = _FrameSink((chunk) {
    chunkCount++;
    frameBytes += chunk.length;
  });
  final input = StreamController<List<int>>();

  var statusCalls = 0;
  final controller = FaTuiController(
    callbacks: FaTuiCallbacks(
      onSubmit: (_) async {},
      onModelSelected: (_) async {},
      buildSlashMenu: (_) => const [],
      buildModelMenu: (_) => const [],
      statusLine: () {
        statusCalls++;
        return '/tmp/bench · ctx 12% (20k/160k) · 15k tok · turn 3 · '
            'catalog/glm-5.3-flash';
      },
      prompt: 'fa> ',
    ),
    isExited: () => false,
    programHooks: TuiProgramHooks(
      input: input.stream,
      output: sink,
      width: width,
      height: height,
    ),
  );

  final runFuture = controller.run();
  // Let the first frames render.
  await Future<void>.delayed(const Duration(milliseconds: 200));
  controller.sendBusy(true);

  Timer? floodTimer;
  if (flood) {
    // ~100 dim-styled deltas/s, ~48 chars each — the shape of a long
    // reasoning stream (minutes-long thinking). growTail emits NO newlines
    // so the last output line grows into the 32KB hard-split regime.
    const words = [
      'analysis',
      'therefore',
      'however',
      'consider',
      'the',
      'signal',
      'path',
      'requires',
      'careful',
      'treatment',
      'of',
      'edge',
      'cases',
      'before',
      'committing',
      'to',
      'a',
      'final',
      'answer',
      'form',
    ];
    var w = 0;
    var charsSinceNewline = 0;
    floodTimer = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final buf = StringBuffer();
      for (var i = 0; i < 4; i++) {
        buf.write('${words[w++ % words.length]} ');
      }
      var text = buf.toString();
      if (!growTail) {
        charsSinceNewline += text.length;
        if (charsSinceNewline > 400) {
          text = '$text\n';
          charsSinceNewline = 0;
        }
      }
      controller.sendOutput('\x1b[2m$text\x1b[0m');
    });
  }

  // Typing: one key every 150ms (plain ASCII runes).
  final stopAt = DateTime.now().add(Duration(seconds: seconds));
  var keyIdx = 0;
  final keys = 'abcdefghijklmnopqrstuvwxyz0123456789';
  final typing = Timer.periodic(const Duration(milliseconds: 150), (_) {
    if (DateTime.now().isAfter(stopAt)) return;
    input.add(utf8.encode(keys[keyIdx % keys.length]));
    keyIdx++;
  });

  await Future<void>.delayed(Duration(seconds: seconds));
  typing.cancel();
  floodTimer?.cancel();
  controller.sendBusy(false);
  await Future<void>.delayed(const Duration(milliseconds: 300));
  await input.close();
  await runFuture.timeout(const Duration(seconds: 5), onTimeout: () {});

  stdout.writeln(
    'mode=${growTail ? 'grow-tail' : (flood ? 'flood' : 'control')} '
    '${width}x$height keys=$keyIdx chunks=$chunkCount '
    'bytes=$frameBytes statusCalls=$statusCalls',
  );
  stdout.writeln(
    'fmt: rebuilds=${TranscriptMarkdown.debugFullRebuilds} '
    'resumed=${TranscriptMarkdown.debugResumedPasses} '
    'linesFormatted=${TranscriptMarkdown.debugLinesFormatted} '
    'tailThrottled=${TranscriptMarkdown.debugTailThrottled} '
    'rbFails: w=${TranscriptMarkdown.dbgRollbackWidth} '
    'thr=${TranscriptMarkdown.dbgRollbackThrough} '
    'bnd=${TranscriptMarkdown.dbgRollbackBoundary} '
    'first=${TranscriptMarkdown.dbgRollbackFirst} '
    'prefix=${TranscriptMarkdown.dbgRollbackPrefix}',
  );
  exit(0);
}
