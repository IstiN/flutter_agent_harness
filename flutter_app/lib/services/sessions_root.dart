import 'dart:io' show Directory, File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;

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
    // Probe the group container only when it already exists or the CLI
    // is installed — otherwise this machine would never use it anyway.
    final groupDir =
        Directory(sessionsGroupDir(home)).existsSync() || isFaCliInstalled()
        ? probedSessionsGroupDir(home)
        : null;
    return groupDir ?? '$home/.fah/sessions';
  }
  return '$cwd/sessions';
}

/// Returns all candidate session roots on macOS so listing sessions discovers
/// both shared App Group sessions and fallback `~/.fah/sessions`.
List<String> allSessionRoots(String defaultRoot) {
  if (kIsWeb || !Platform.isMacOS) return [defaultRoot];
  return macSessionRootCandidates(
    home: Platform.environment['HOME'] ?? '',
    defaultRoot: defaultRoot,
    exists: (path) => Directory(path).existsSync(),
  );
}

/// The macOS App Group sessions directory for [home] (may not exist).
String sessionsGroupDir(String home) =>
    '$home/Library/Group Containers/$_kSharedAppGroupId/fa/sessions';

/// Creates (when missing) and probe-writes the macOS App Group sessions
/// directory, returning its path; null when the container is unusable —
/// the caller falls back to `~/.fah/sessions`.
String? probedSessionsGroupDir(String home) {
  final groupDir = sessionsGroupDir(home);
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
    return null;
  }
}

/// The macOS roots beyond [defaultRoot]: the App Group container and the
/// `~/.fah/sessions` fallback, each only when it exists and differs from
/// [defaultRoot]. [exists] is injected so the candidacy rule is testable
/// on every platform.
List<String> macSessionRootCandidates({
  required String home,
  required String defaultRoot,
  required bool Function(String path) exists,
}) {
  final roots = <String>{defaultRoot};
  for (final dir in [sessionsGroupDir(home), '$home/.fah/sessions']) {
    if (dir != defaultRoot && exists(dir)) {
      roots.add(dir);
    }
  }
  return roots.toList();
}

/// Checks whether `fa` CLI or its environment is installed on this macOS machine.
bool isFaCliInstalled() => faCliProbe(
  isMacOS: !kIsWeb && Platform.isMacOS,
  home: Platform.environment['HOME'] ?? '',
  pathEnv: Platform.environment['PATH'] ?? '',
  pathExists: _pathExists,
);

bool _pathExists(String path) =>
    File(path).existsSync() || Directory(path).existsSync();

/// Scriptable core of [isFaCliInstalled] (issue #701): every input — the
/// platform gate, `HOME`, `PATH` and the exists probe — is injected so the
/// whole branch matrix is unit-testable on any host, not only macOS.
/// Probe order mirrors the CLI's install surface: `~/.fah`, the fixed
/// install locations, then every `PATH` directory (`fa` or `fah`).
@visibleForTesting
bool faCliProbe({
  required bool isMacOS,
  required String home,
  required String pathEnv,
  required bool Function(String path) pathExists,
}) {
  if (!isMacOS) return false;
  if (pathExists('$home/.fah')) return true;

  final candidatePaths = [
    '$home/.local/bin/fa',
    '$home/.local/bin/fah',
    '/opt/homebrew/bin/fa',
    '/opt/homebrew/bin/fah',
    '/usr/local/bin/fa',
    '/usr/local/bin/fah',
  ];
  for (final path in candidatePaths) {
    if (pathExists(path)) return true;
  }

  for (final dir in pathEnv.split(':')) {
    if (dir.isEmpty) continue;
    if (pathExists('$dir/fa') || pathExists('$dir/fah')) {
      return true;
    }
  }

  return false;
}
