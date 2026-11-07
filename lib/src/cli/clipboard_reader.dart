/// Pasteboard image reads for Ctrl+V (issue #276).
///
/// Platform glue only — the sniffing/capping rules live in `paste_image.dart`
/// (pure, which also owns the [PasteboardRead] result types). Every platform
/// path funnels through an injected [ProcessRunner] so tests script the
/// pasteboard instead of touching a real one.
///
/// - macOS: the native `fa-clip` helper (gh-2040, Swift/AppKit source in
///   `tools/fa-clip/fa-clip.swift`, shipped beside the fa binary) reads the
///   pasteboard through `NSPasteboard.general.data(forType:)` — a plain
///   pasteboard read that sends no Apple Events, so the TCC
///   `SystemPolicyAppData` consent class («access data from other apps»)
///   that the old AppleScript transport raised can never fire. The helper
///   answers ONE flavor per call (`fa-clip png|jpeg|tiff`; exit 0 = bytes
///   on stdout, exit 2 = flavor absent) and this side keeps the flavor
///   ladder PNG → JPEG → TIFF: a TIFF-only pasteboard (Preview, most
///   browsers, gh-1575) converts to PNG with `sips -s format png`. The
///   helper is resolved relative to the fa executable, never PATH —
///   a missing/broken helper degrades to the named unavailable path (AC5).
/// - Linux: `xclip -selection clipboard -t image/png -o`, falling back to
///   `wl-paste --type image/png` (Wayland).
/// - Windows: PowerShell `Get-Clipboard -Format Image` saved as PNG.
/// - `readPasteboardText` reads the clipboard's plain text
///   (`pbpaste` / `xclip`+`wl-paste` / PowerShell `Get-Clipboard`) — the
///   Ctrl+V text fallback when the image probe misses (gh-1575). macOS text
///   deliberately STAYS on `pbpaste` (gh-2040 AC4, documented split):
///   `pbpaste` reads the pasteboard through the system pasteboard server
///   and delivers no Apple Events either — it is already prompt-free, so
///   moving it onto the helper would grow the helper's surface (a text
///   flavor + UTF-8 contract) for zero consent benefit.
/// - `FA_FAKE_PASTEBOARD=<path>` short-circuits the IMAGE read: that file
///   is returned as-is — the test seam for the PTY golden tests (and handy
///   for debugging on a headless box). The TEXT read has no fake seam —
///   it consults only the real platform pasteboard (script it with the
///   injected [ProcessRunner]).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show BytesBuilder;

import 'paste_image.dart';
import 'pasteboard_platform.dart';

/// Runs a process to completion with stdout captured as RAW BYTES
/// (injectable `Process.run`). Binary mode is load-bearing: the default
/// text-mode decoding (UTF-8 on Linux) mangles pasteboard image bytes, so
/// the sniff downstream sees replacement chars instead of magic bytes.
typedef ProcessRunner =
    Future<ProcessResult> Function(String executable, List<String> args);

/// The default [ProcessRunner]: `Process.start` + an explicit stdout byte
/// fold — `Process.run` has no bytes mode, so the raw pipe is the only
/// lossless path. stderr is drained and discarded (exit codes carry
/// failures). The wait is bounded by [pasteboardProcessTimeout] (gh-1606
/// review): a wedged reader is killed and the wait surfaces as a
/// [TimeoutException] — the dispatchers map it into the named
/// unavailable result like any other read failure.
Future<ProcessResult> _runBinaryProcess(
  String executable,
  List<String> args,
) async {
  final process = await Process.start(executable, args);
  final wait = () async {
    final stdout = await process.stdout.fold(
      BytesBuilder(),
      (builder, chunk) => builder..add(chunk),
    );
    await process.stderr.drain<void>();
    final exitCode = await process.exitCode;
    return ProcessResult(process.pid, exitCode, stdout.toBytes(), null);
  }();
  return boundedPasteboardWait(wait, process);
}

/// The `FA_FAKE_PASTEBOARD` seam: reads the pinned file. `null` = no fake
/// configured (the caller falls through to the platform readers).
PasteboardRead? _readFakePasteboard(String? fake) {
  if (fake == null || fake.isEmpty) return null;
  try {
    return PasteboardImage(File(fake).readAsBytesSync());
  } on Object catch (error) {
    return PasteboardUnavailable('FA_FAKE_PASTEBOARD read failed: $error');
  }
}

/// Dispatches to the platform reader. Never throws (doc): a missing
/// xclip/fa-clip/powershell surfaces as a ProcessException here — turn
/// it into the named unavailable result the transcript prints as a clean
/// note (edge E1).
Future<PasteboardRead> _readPlatform(
  ProcessRunner run,
  Directory tmp,
  String? platform,
  String helperPath,
) async {
  try {
    switch (pasteboardPlatform(platform)) {
      case 'macos':
        return await _readMacos(run, tmp, helperPath);
      case 'linux':
        return await _readLinux(run);
      case 'windows':
        return await _readWindows(run, tmp);
    }
  } on Object catch (error) {
    return PasteboardUnavailable('pasteboard read failed: $error');
  }
  return const PasteboardUnavailable('no pasteboard reader for this platform');
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

  /// Pins the macOS `fa-clip` helper location (gh-2040): the production
  /// value resolves beside the fa executable ([faClipHelperPath]); tests
  /// pass a scripted path so the helper protocol is pinned on the same
  /// [ProcessRunner] seam as every other platform.
  String? helperPath,
}) async {
  final run = runner ?? _runBinaryProcess;
  // The explicit map wins (unit tests); the real process env is the seam
  // the PTY golden tests and headless debugging actually set.
  final fake = _readFakePasteboard(
    environment['FA_FAKE_PASTEBOARD'] ??
        Platform.environment['FA_FAKE_PASTEBOARD'],
  );
  if (fake != null) return fake;
  return _readPlatform(
    run,
    tempDir ?? Directory.systemTemp,
    platform,
    helperPath ?? faClipHelperPath(),
  );
}

/// The production `fa-clip` location: beside the running fa executable.
/// Never a PATH lookup — the binary ships its helper as one unit, and a
/// stray `fa-clip` on PATH is exactly the partial-update shape AC5 degrades
/// on (gh-2040).
String faClipHelperPath() {
  final exeDir = File(Platform.resolvedExecutable).parent.path;
  return '$exeDir${Platform.pathSeparator}fa-clip';
}

Future<PasteboardRead> _readMacos(
  ProcessRunner runner,
  Directory tmp,
  String helperPath,
) async {
  // A missing helper is a transport failure with its own one-line
  // diagnostic (gh-2040 border case: name the transport, never a bare
  // «no image»): partial updates, uninstall-side installs and dev runs
  // without the helper all land here and degrade per AC5.
  if (!File(helperPath).existsSync()) {
    return PasteboardUnavailable(
      'fa-clip helper not found at $helperPath — reinstall fa so the '
      'native pasteboard helper sits beside the binary',
    );
  }
  for (final flavor in const ['png', 'jpeg']) {
    final bytes = await _faClipFlavorBytes(runner, helperPath, flavor);
    if (bytes != null) return PasteboardImage(bytes);
  }
  // gh-1575: TIFF-only pasteboards (an image copied from Preview or a
  // browser) hold neither PNG nor JPEG — probe the tiff flavor and convert
  // to PNG with sips (ships with macOS). A failed conversion keeps the
  // unavailable fall-through: no silent garbage bytes ever become a chip.
  final tiff = await _faClipFlavorBytes(runner, helperPath, 'tiff');
  if (tiff != null) {
    final png = await _convertTiffToPng(runner, tmp, tiff);
    if (png != null) return PasteboardImage(png);
  }
  return const PasteboardUnavailable('clipboard holds no image');
}

/// One `fa-clip <flavor>` probe (gh-2040): the flavor's bytes when the
/// pasteboard holds it (exit 0), null when the flavor is absent (exit 2 —
/// the ladder falls through), a named transport failure otherwise. A
/// crashed/quarantined/wrong-ABI helper (any other exit code) throws the
/// StateError the platform dispatch renders as `pasteboard read failed: …`
/// — the same named-unavailable path a broken backend takes on every other
/// platform (AC5), never a hang and never silent garbage bytes.
Future<List<int>?> _faClipFlavorBytes(
  ProcessRunner runner,
  String helperPath,
  String flavor,
) async {
  final result = await runner(helperPath, [flavor]);
  final stdout = result.stdout;
  if (result.exitCode == 0 && stdout is List<int> && stdout.isNotEmpty) {
    return stdout;
  }
  if (result.exitCode == 0 || result.exitCode == 2) return null;
  final stderr = result.stderr;
  final detail = stderr is List<int>
      ? utf8.decode(stderr, allowMalformed: true).trim()
      : '$stderr'.trim();
  throw StateError(
    'fa-clip $flavor failed (exit ${result.exitCode})'
    '${detail.isEmpty ? '' : ': $detail'}',
  );
}

/// Converts TIFF [bytes] to PNG via `sips -s format png <in> --out <out>`;
/// the PNG bytes, or null when anything in the pipeline failed. Both
/// scratch files are cleaned up on every path.
Future<List<int>?> _convertTiffToPng(
  ProcessRunner runner,
  Directory tmp,
  List<int> bytes,
) async {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final tiffPath = '${tmp.path}/fa-clipboard-$stamp.tiff';
  final pngPath = '${tmp.path}/fa-clipboard-$stamp.png';
  try {
    File(tiffPath).writeAsBytesSync(bytes);
    final result = await runner('sips', [
      '-s',
      'format',
      'png',
      tiffPath,
      '--out',
      pngPath,
    ]);
    if (result.exitCode != 0) return null;
    return File(pngPath).readAsBytesSync();
  } on Object {
    return null;
  } finally {
    for (final path in [tiffPath, pngPath]) {
      try {
        final file = File(path);
        if (file.existsSync()) file.deleteSync();
      } on Object {
        // Best-effort cleanup — never mask the real outcome.
      }
    }
  }
}

/// Reads the platform pasteboard's TEXT content (gh-1575): `pbpaste`
/// (macOS), `xclip -selection clipboard -o` with a `wl-paste` fallback
/// (Linux), PowerShell `Get-Clipboard` (Windows). Never throws — every
/// failure becomes [PasteboardUnavailable]. Empty stdout counts as no
/// text: an empty paste must never reach the composer.
///
/// gh-2040 AC4 (documented split): macOS text stays on `pbpaste` — it
/// reads the pasteboard through the system pasteboard server, delivers no
/// Apple Events, and is already prompt-free, so the fa-clip helper stays
/// image-only instead of growing a text flavor + UTF-8 contract for zero
/// consent benefit.
Future<PasteboardRead> readPasteboardText({
  ProcessRunner? runner,

  /// Pins the platform branch so unit tests can exercise every platform
  /// path (same seam as [readPasteboardImage]).
  String? platform,
}) async {
  final run = runner ?? _runBinaryProcess;
  try {
    switch (pasteboardPlatform(platform)) {
      case 'macos':
        return _textFromStdout(await run('pbpaste', const []));
      case 'linux':
        return await _readLinuxText(run);
      case 'windows':
        return await _readWindowsText(run);
    }
  } on Object catch (error) {
    return PasteboardUnavailable('pasteboard text read failed: $error');
  }
  return const PasteboardUnavailable('no pasteboard reader for this platform');
}

/// Decodes a text backend's stdout as UTF-8 (malformed bytes degrade to
/// replacement chars — never a throw); empty output = no text.
PasteboardRead _textFromStdout(ProcessResult result) {
  if (result.exitCode != 0) {
    return const PasteboardUnavailable('clipboard holds no text');
  }
  final stdout = result.stdout;
  final bytes = stdout is List<int> ? stdout : utf8.encode('$stdout');
  final text = utf8.decode(bytes, allowMalformed: true);
  if (text.isEmpty) {
    return const PasteboardUnavailable('clipboard holds no text');
  }
  return PasteboardText(text);
}

Future<PasteboardRead> _readLinuxText(ProcessRunner runner) async {
  // Type-pinned like the image path (gh-1575 review): unpinned wl-paste
  // pastes the FIRST MIME the source offers — for an image-only clipboard
  // the raw image bytes would reach the composer as "text". Pinned, both
  // backends fail cleanly and the named reason prints instead.
  for (final (executable, args) in [
    (
      'xclip',
      ['-selection', 'clipboard', '-t', 'text/plain;charset=utf-8', '-o'],
    ),
    ('wl-paste', ['--type', 'text/plain;charset=utf-8', '--no-newline']),
  ]) {
    final read = _textFromStdout(await runner(executable, args));
    if (read is PasteboardText) return read;
  }
  return const PasteboardUnavailable(
    'xclip/wl-paste unavailable or clipboard holds no text',
  );
}

Future<PasteboardRead> _readWindowsText(ProcessRunner runner) async {
  // Pin the console encoding (gh-1575 review): Windows PowerShell 5.1
  // writes redirected stdout in the OEM code page, so a UTF-8 decode of
  // an unpinned read mojibakes every non-ASCII character.
  final read = _textFromStdout(
    await runner('powershell', [
      '-NoProfile',
      '-Command',
      '[Console]::OutputEncoding=[System.Text.Encoding]::UTF8; Get-Clipboard',
    ]),
  );
  if (read is! PasteboardText) return read;
  // PowerShell's output formatter appends exactly one newline to the
  // captured stream — the clipboard text itself never carries it — and
  // formats every embedded line break as `\r\n`; normalize to `\n` (the
  // composer inserts verbatim, no `\r` normalization downstream).
  var text = read.text;
  if (text.endsWith('\r\n')) {
    text = text.substring(0, text.length - 2);
  } else if (text.endsWith('\n')) {
    text = text.substring(0, text.length - 1);
  }
  text = text.replaceAll('\r\n', '\n');
  if (text.isEmpty) {
    return const PasteboardUnavailable('clipboard holds no text');
  }
  return PasteboardText(text);
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
  final image = result.exitCode == 0 ? _readSavedPng(target) : null;
  return image ?? const PasteboardUnavailable('clipboard holds no image');
}

/// Reads and deletes the PowerShell-saved PNG; null when missing or broken
/// (the caller reports plain unavailability either way).
PasteboardRead? _readSavedPng(String target) {
  try {
    final bytes = File(target).readAsBytesSync();
    File(target).deleteSync();
    return PasteboardImage(bytes);
  } on Object {
    // Fall through.
    return null;
  }
}
