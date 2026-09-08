// Typing-latency bench for the fa TUI under a thinking-stream flood.
//
// Reproduces issue #43: while reasoning deltas stream in (the exact write
// pattern AgentCli produces — `_style.dim(delta)` per delta through
// sendOutput), measure how long a typed key takes to appear on screen.
//
// Usage: dart run scripts/tui_typing_bench.dart [flags]
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
    // Production shape: a submit echo (rule + input + trailing blank) sits
    // above the stream before the first delta lands — the flood grows the
    // LAST line, never line 0. Without this anchor the first-line identity
    // sentinel forces a rebuild per flush and the numbers stop modeling
    // the shipped REPL (issue #43 regime).
    controller.sendOutput('>> user: think hard\n');
    controller.sendOutput('\n');
    // ~200 dim-styled deltas/s, ~60 chars each — the cadence of a real
    // reasoning stream at ~12KB/s (the issue #43 regime: the tail crosses
    // the 32KB hard-split cap within seconds and keeps re-splitting).
    // growTail emits NO newlines so the last output line grows into that
    // regime.
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
    floodTimer = Timer.periodic(const Duration(milliseconds: 5), (_) {
      final buf = StringBuffer();
      for (var i = 0; i < 8; i++) {
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
    'tailThrottled=${TranscriptMarkdown.debugTailThrottled}',
  );
  exit(0);
}
