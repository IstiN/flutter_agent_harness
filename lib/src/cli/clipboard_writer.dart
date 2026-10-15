/// Pasteboard text writes for `/provider export` (gh-1606): the saved
/// Copilot token lands on the host clipboard without ever touching the
/// transcript.
///
/// Platform glue only — every platform path funnels through an injected
/// [ClipboardWriteRunner] so tests script the pasteboard instead of
/// touching a real one. The text rides STDIN, never argv: process
/// listings leak arguments, and the payload is a credential. Every path
/// is time-bounded (gh-1606 review): a wedged writer is killed and the
/// write degrades to the named `clipboard writer timed out` result
/// instead of holding the `/provider …` flow gate shut forever.
///
/// - macOS: `pbcopy`
/// - Linux: `xclip -selection clipboard`, falling back to `wl-copy`
///   (Wayland)
/// - Windows: `clip`
library;

import 'dart:async';
import 'dart:io';

import 'paste_image.dart';
import 'pasteboard_platform.dart';

export 'paste_image.dart'
    show PasteboardWriteOk, PasteboardWriteResult, PasteboardWriteUnavailable;

/// Runs a process to completion with [stdinText] written to its standard
/// input (injectable `Process` layer).
typedef ClipboardWriteRunner =
    Future<ProcessResult> Function(
      String executable,
      List<String> args,
      String stdinText,
    );

/// The default [ClipboardWriteRunner]: `Process.start`, the text piped to
/// stdin (closed, so the writer sees EOF), streams drained, exit code
/// carried back. The wait is bounded by [pasteboardProcessTimeout] — a
/// wedged writer is killed and the wait surfaces as a [TimeoutException]
/// (the write loop maps it to the named timeout result).
Future<ProcessResult> _runWithStdin(
  String executable,
  List<String> args,
  String stdinText,
) async {
  final process = await Process.start(executable, args);
  process.stdin.write(stdinText);
  await process.stdin.flush();
  await process.stdin.close();
  final wait = () async {
    await process.stderr.drain<void>();
    await process.stdout.drain<void>();
    final exitCode = await process.exitCode;
    return ProcessResult(process.pid, exitCode, null, null);
  }();
  return boundedPasteboardWait(wait, process);
}

/// Copies [text] to the platform clipboard, trying each platform path in
/// order. Never throws — every failure becomes
/// [PasteboardWriteUnavailable] with the named reason. Each path is
/// bounded by [processTimeout]: a hung pasteboard binary tries the next
/// path, and an all-paths timeout names the timeout instead of blaming
/// the tooling.
Future<PasteboardWriteResult> writeClipboardText(
  String text, {
  ClipboardWriteRunner? runner,
  String? platform,
  Duration processTimeout = pasteboardProcessTimeout,
}) async {
  final run = runner ?? _runWithStdin;
  final paths = switch (pasteboardPlatform(platform)) {
    'macos' => const [('pbcopy', <String>[])],
    'linux' => const [
      ('xclip', <String>['-selection', 'clipboard']),
      ('wl-copy', <String>[]),
    ],
    'windows' => const [('clip', <String>[])],
    _ => const <(String, List<String>)>[],
  };
  var timedOut = false;
  for (final (executable, args) in paths) {
    try {
      final result = await run(executable, args, text).timeout(processTimeout);
      if (result.exitCode == 0) return const PasteboardWriteOk();
    } on TimeoutException {
      // Try the next path, but remember the wedge for the final reason.
      timedOut = true;
    } on Object {
      // Fall through to the next path / the unavailable result.
    }
  }
  return timedOut
      ? const PasteboardWriteUnavailable('clipboard writer timed out')
      : const PasteboardWriteUnavailable(
          'no clipboard writer available (pbcopy/xclip/wl-copy/clip)',
        );
}
