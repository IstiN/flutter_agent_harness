import 'dart:io' show Directory, File, Platform;

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
    final groupDir =
        '$home/Library/Group Containers/$_kSharedAppGroupId/fa/sessions';
    final groupDirExists = Directory(groupDir).existsSync();
    if (!groupDirExists && !isFaCliInstalled()) {
      return '$home/.fah/sessions';
    }
    try {
      final dir = Directory(groupDir);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
      final probe = File(
        '$groupDir/.probe_${DateTime.now().microsecondsSinceEpoch}',
      );
      probe.writeAsStringSync('');
      probe.deleteSync();
      return groupDir;
    } catch (_) {
      return '$home/.fah/sessions';
    }
  }
  return '$cwd/sessions';
}

/// Returns all candidate session roots on macOS so listing sessions discovers
/// both shared App Group sessions and fallback `~/.fah/sessions`.
List<String> allSessionRoots(String defaultRoot) {
  if (kIsWeb || !Platform.isMacOS) return [defaultRoot];
  final home = Platform.environment['HOME'] ?? '';
  final groupDir =
      '$home/Library/Group Containers/$_kSharedAppGroupId/fa/sessions';
  final fallbackDir = '$home/.fah/sessions';
  final roots = <String>{defaultRoot};
  if (groupDir != defaultRoot && Directory(groupDir).existsSync()) {
    roots.add(groupDir);
  }
  if (fallbackDir != defaultRoot && Directory(fallbackDir).existsSync()) {
    roots.add(fallbackDir);
  }
  return roots.toList();
}

/// Checks whether `fa` CLI or its environment is installed on this macOS machine.
bool isFaCliInstalled() {
  if (kIsWeb || !Platform.isMacOS) return false;
  final home = Platform.environment['HOME'] ?? '';
  if (Directory('$home/.fah').existsSync()) return true;

  final candidatePaths = [
    '$home/.local/bin/fa',
    '$home/.local/bin/fah',
    '/opt/homebrew/bin/fa',
    '/opt/homebrew/bin/fah',
    '/usr/local/bin/fa',
    '/usr/local/bin/fah',
  ];
  for (final path in candidatePaths) {
    if (File(path).existsSync()) return true;
  }

  final envPath = Platform.environment['PATH'] ?? '';
  for (final dir in envPath.split(':')) {
    if (dir.isEmpty) continue;
    if (File('$dir/fa').existsSync() || File('$dir/fah').existsSync()) {
      return true;
    }
  }

  return false;
}
