/// Pasteboard text writes for `/provider export` (gh-1606): the saved
/// Copilot token lands on the host clipboard without ever touching the
/// transcript.
///
/// Platform glue only — every platform path funnels through an injected
/// [ClipboardWriteRunner] so tests script the pasteboard instead of
/// touching a real one. The text rides STDIN, never argv: process
/// listings leak arguments, and the payload is a credential.
///
/// - macOS: `pbcopy`
/// - Linux: `xclip -selection clipboard`, falling back to `wl-copy`
///   (Wayland)
/// - Windows: `clip`
library;

import 'dart:io';

import 'paste_image.dart';

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
/// carried back.
Future<ProcessResult> _runWithStdin(
  String executable,
  List<String> args,
  String stdinText,
) async {
  final process = await Process.start(executable, args);
  process.stdin.write(stdinText);
  await process.stdin.flush();
  await process.stdin.close();
  await process.stderr.drain<void>();
  await process.stdout.drain<void>();
  final exitCode = await process.exitCode;
  return ProcessResult(process.pid, exitCode, null, null);
}

/// The effective platform id (`macos`/`linux`/`windows`): the explicit
/// [platform] pin wins (unit tests — the macOS/Windows paths are
/// unreachable on a Linux CI runner), else the host [Platform]. `null` =
/// no clipboard writer for this platform.
String? _effectivePlatform(String? platform) {
  if (platform != null) return platform;
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  return null;
}

/// Copies [text] to the platform clipboard, trying each platform path in
/// order. Never throws — every failure becomes
/// [PasteboardWriteUnavailable] with the named reason.
Future<PasteboardWriteResult> writeClipboardText(
  String text, {
  ClipboardWriteRunner? runner,
  String? platform,
}) async {
  final run = runner ?? _runWithStdin;
  final paths = switch (_effectivePlatform(platform)) {
    'macos' => const [('pbcopy', <String>[])],
    'linux' => const [
      ('xclip', <String>['-selection', 'clipboard']),
      ('wl-copy', <String>[]),
    ],
    'windows' => const [('clip', <String>[])],
    _ => const <(String, List<String>)>[],
  };
  for (final (executable, args) in paths) {
    try {
      final result = await run(executable, args, text);
      if (result.exitCode == 0) return const PasteboardWriteOk();
    } on Object {
      // Fall through to the next path / the unavailable result.
    }
  }
  return const PasteboardWriteUnavailable(
    'no clipboard writer available (pbcopy/xclip/wl-copy/clip)',
  );
}
