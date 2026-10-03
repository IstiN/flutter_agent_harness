/// Pasteboard image reads for Ctrl+V (issue #276).
///
/// Platform glue only — the sniffing/capping rules live in `paste_image.dart`
/// (pure, which also owns the [PasteboardRead] result types). Every platform
/// path funnels through an injected [ProcessRunner] so tests script the
/// pasteboard instead of touching a real one.
///
/// - macOS: `osascript` writes `«class PNGf»` (fallback `«class JPEG»`) to a
///   temp file we then read.
/// - Linux: `xclip -selection clipboard -t image/png -o`, falling back to
///   `wl-paste --type image/png` (Wayland).
/// - Windows: PowerShell `Get-Clipboard -Format Image` saved as PNG.
/// - `FA_FAKE_PASTEBOARD=<path>` short-circuits everything and reads that
///   file — the test seam for the PTY golden tests (and handy for
///   debugging on a headless box).
library;

import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'paste_image.dart';

/// Runs a process to completion with stdout captured as RAW BYTES
/// (injectable `Process.run`). Binary mode is load-bearing: the default
/// text-mode decoding (UTF-8 on Linux) mangles pasteboard image bytes, so
/// the sniff downstream sees replacement chars instead of magic bytes.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// The default [ProcessRunner]: `Process.start` + an explicit stdout byte
/// fold — `Process.run` has no bytes mode, so the raw pipe is the only
/// lossless path. stderr is drained and discarded (exit codes carry
/// failures).
Future<ProcessResult> _runBinaryProcess(
  String executable,
  List<String> args,
) async {
  final process = await Process.start(executable, args);
  final stdout = await process.stdout.fold(
    BytesBuilder(),
    (builder, chunk) => builder..add(chunk),
  );
  await process.stderr.drain<void>();
  final exitCode = await process.exitCode;
  return ProcessResult(process.pid, exitCode, stdout.toBytes(), null);
}

/// Reads the platform pasteboard's image content, trying each platform path
/// in order. Never throws — every failure becomes [PasteboardUnavailable].
Future<PasteboardRead> readPasteboardImage({
  ProcessRunner? runner,
  Directory? tempDir,
  Map<String, String> environment = const {},
  /// Pins the platform branch so unit tests can exercise every
  /// platform path (macOS/Windows readers are unreachable on a Linux
  /// CI runner, which would push their CRAP through the roof).
  String? platform,
}) async {
  final run = runner ?? _runBinaryProcess;
  // The explicit map wins (unit tests); the real process env is the seam
  // the PTY golden tests and headless debugging actually set.
  final fake =
      environment['FA_FAKE_PASTEBOARD'] ??
      Platform.environment['FA_FAKE_PASTEBOARD'];
  if (fake != null && fake.isNotEmpty) {
    try {
      return PasteboardImage(File(fake).readAsBytesSync());
    } on Object catch (error) {
      return PasteboardUnavailable('FA_FAKE_PASTEBOARD read failed: $error');
    }
  }
  final tmp = tempDir ?? Directory.systemTemp;
  // Never throws (doc): a missing xclip/osascript/powershell surfaces as
  // a ProcessException here — turn it into the named unavailable result
  // the transcript prints as a clean note (edge E1).
  try {
    final isMacOS = platform != null
        ? platform == 'macos'
        : Platform.isMacOS;
    final isLinux = platform != null
        ? platform == 'linux'
        : Platform.isLinux;
    final isWindows = platform != null
        ? platform == 'windows'
        : Platform.isWindows;
    if (isMacOS) return await _readMacos(run, tmp);
    if (isLinux) return await _readLinux(run);
    if (isWindows) return await _readWindows(run, tmp);
  } on Object catch (error) {
    return PasteboardUnavailable('pasteboard read failed: $error');
  }
  return const PasteboardUnavailable('no pasteboard reader for this platform');
}

Future<PasteboardRead> _readMacos(ProcessRunner runner, Directory tmp) async {
  for (final (appleClass, ext) in [
    ('«class PNGf»', 'png'),
    ('«class JPEG»', 'jpg'),
  ]) {
    final target =
        '${tmp.path}/fa-clipboard-${DateTime.now().microsecondsSinceEpoch}'
        '.$ext';
    final script = [
      'set pngData to (the clipboard as $appleClass)',
      'set imgFile to (open for access POSIX file "$target" with write permission)',
      'try',
      'write pngData to imgFile',
      'close access imgFile',
      'on error errStr',
      'try',
      'close access imgFile',
      'end try',
      'error errStr',
      'end try',
    ];
    final result = await runner('osascript', [
      for (final line in script) ...['-e', line],
    ]);
    if (result.exitCode == 0) {
      try {
        final bytes = File(target).readAsBytesSync();
        // Read OK: drop the scratch file — a golden run pastes many
        // images and each would otherwise litter the temp dir.
        File(target).deleteSync();
        return PasteboardImage(bytes);
      } on Object {
        // Fall through to the next class / the unavailable path.
      }
    }
  }
  return const PasteboardUnavailable('clipboard holds no image');
}

/// Linux: `xclip -selection clipboard -t image/png -o`, falling back to
/// `wl-paste --type image/png` (Wayland). The runner hands stdout back as
/// raw bytes — image payloads are binary, and text-mode decoding would
/// mangle the magic bytes the sniff depends on (review major 2).
Future<PasteboardRead> _readLinux(ProcessRunner runner) async {
  for (final (executable, args) in [
    ('xclip', ['-selection', 'clipboard', '-t', 'image/png', '-o']),
    ('wl-paste', ['--type', 'image/png', '--no-newline']),
  ]) {
    final result = await runner(executable, args);
    final stdout = result.stdout;
    if (result.exitCode == 0 && stdout is List<int> && stdout.isNotEmpty) {
      return PasteboardImage(stdout);
    }
  }
  return const PasteboardUnavailable(
    'xclip/wl-paste unavailable or clipboard holds no image',
  );
}

Future<PasteboardRead> _readWindows(ProcessRunner runner, Directory tmp) async {
  final target =
      '${tmp.path}\\fa-clipboard-${DateTime.now().microsecondsSinceEpoch}'
      '.png';
  final script =
      'Add-Type -AssemblyName System.Windows.Forms;'
      'Add-Type -AssemblyName System.Drawing;'
      r'$img = [System.Windows.Forms.Clipboard]::GetImage();'
      'if (\$img -eq \$null) { exit 2 }'
      '\$img.Save("$target", [System.Drawing.Imaging.ImageFormat]::Png)';
  final result = await runner('powershell', ['-NoProfile', '-Command', script]);
  if (result.exitCode == 0) {
    try {
      final bytes = File(target).readAsBytesSync();
      File(target).deleteSync();
      return PasteboardImage(bytes);
    } on Object {
      // Fall through.
    }
  }
  return const PasteboardUnavailable('clipboard holds no image');
}
