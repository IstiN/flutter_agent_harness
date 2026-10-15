/// Shared pasteboard platform glue (gh-1606 review): the effective-platform
/// resolution and the bounded-subprocess wait used by BOTH pasteboard sides
/// — `clipboard_reader.dart` (Ctrl+V image/text reads, gh-1575) and
/// `clipboard_writer.dart` (`/provider export` text writes, gh-1606).
///
/// One copy, not two: the platform resolution was a byte-identical
/// duplicate in the reader and the writer and would drift (e.g. a new
/// platform arm added to one side only). dart:io — both importers are
/// IO-only libraries behind the web-safe conditional-import pattern (web
/// builds get the `*_stub.dart` variants and never see this file).
library;

import 'dart:async';
import 'dart:io';

/// The hard wall-clock bound for one pasteboard subprocess (read or
/// write): a wedged binary (a shadowed `pbcopy` script, `xclip` blocking
/// on a dead `$DISPLAY`) must not hold the caller forever — the
/// `/provider export` flow gate stays shut while its write runs, so an
/// unbounded writer would no-op every later `/provider …` flow until the
/// process restarts (gh-1606 review).
const pasteboardProcessTimeout = Duration(seconds: 5);

/// The effective platform id (`macos`/`linux`/`windows`): the explicit
/// [platform] pin wins (unit tests — the macOS/Windows paths are
/// unreachable on a Linux CI runner, which would push their CRAP through
/// the roof), else the host [Platform]. `null` = no pasteboard glue for
/// this platform.
String? pasteboardPlatform(String? platform) {
  if (platform != null) return platform;
  if (Platform.isMacOS) return 'macos';
  if (Platform.isLinux) return 'linux';
  if (Platform.isWindows) return 'windows';
  return null;
}

/// Awaits [wait] bounded by [timeout]; on expiry [process] is killed (a
/// wedged pasteboard binary must not leak one process per call either)
/// and the wait surfaces as a [TimeoutException] the caller maps to its
/// named unavailable result.
Future<T> boundedPasteboardWait<T>(
  Future<T> wait,
  Process process, {
  Duration timeout = pasteboardProcessTimeout,
}) async {
  try {
    return await wait.timeout(timeout);
  } on TimeoutException {
    process.kill();
    rethrow;
  }
}
