import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// The shared Fa App Group identifier used for cross-process storage on macOS.
const String _kSharedAppGroupId = 'group.dev.fa1.shared';

/// Returns the default session storage root for this platform.
///
/// On macOS both the CLI and the sandboxed macOS app write sessions into the
/// App Group container so a session started in `fa` is visible in the Fa app
/// and vice versa. The layout underneath is cwd-encoded:
/// `<root>/<--encoded-cwd-->/<timestamp>_<sessionId>.jsonl`, so sessions
/// remain scoped to their workspace while still being reachable from any
/// launch folder.
///
/// On Linux/Windows/web the root stays `<cwd>/sessions` so tests and
/// non-sandboxed hosts are not surprised by a global directory.
String defaultSessionsRoot(String cwd) {
  if (kIsWeb) return '$cwd/sessions';
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? '';
    return '$home/Library/Group Containers/$_kSharedAppGroupId/fa/sessions';
  }
  return '$cwd/sessions';
}
