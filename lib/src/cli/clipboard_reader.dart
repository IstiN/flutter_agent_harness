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

import 'paste_image.dart';

/// Runs a process to completion (injectable `Process.run`).
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// Reads the platform pasteboard's image content, trying each platform path
/// in order. Never throws — every failure becomes [PasteboardUnavailable].
Future<PasteboardRead> readPasteboardImage({
  ProcessRunner? runner,
  Directory? tempDir,
  Map<String, String> environment = const {},
}) async {
  final run = runner ?? Process.run;
  final fake = environment['FA_FAKE_PASTEBOARD'];
  if (fake != null && fake.isNotEmpty) {
    try {
      return PasteboardImage(File(fake).readAsBytesSync());
    } on Object catch (error) {
      return PasteboardUnavailable('FA_FAKE_PASTEBOARD read failed: $error');
    }
  }
  final tmp = tempDir ?? Directory.systemTemp;
  if (Platform.isMacOS) return _readMacos(run, tmp);
  if (Platform.isLinux) return _readLinux(run);
  if (Platform.isWindows) return _readWindows(run, tmp);
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
        return PasteboardImage(File(target).readAsBytesSync());
      } on Object {
        // Fall through to the next class / the unavailable path.
      }
    }
  }
  return const PasteboardUnavailable('clipboard holds no image');
}

Future<PasteboardRead> _readLinux(ProcessRunner runner) async {
  for (final (executable, args) in [
    ('xclip', ['-selection', 'clipboard', '-t', 'image/png', '-o']),
    ('wl-paste', ['--type', 'image/png', '--no-newline']),
  ]) {
    final result = await runner(executable, args);
    if (result.exitCode == 0) {
      final stdout = result.stdout;
      if (stdout is List<int> && stdout.isNotEmpty) {
        return PasteboardImage(stdout);
      }
      if (stdout is String && stdout.codeUnits.isNotEmpty) {
        // Process.run decodes text mode by default; latin-1 round-trip keeps
        // the raw bytes intact for the magic-byte sniff downstream.
        return PasteboardImage(stdout.codeUnits);
      }
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
      return PasteboardImage(File(target).readAsBytesSync());
    } on Object {
      // Fall through.
    }
  }
  return const PasteboardUnavailable('clipboard holds no image');
}
