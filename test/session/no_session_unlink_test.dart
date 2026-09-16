import 'dart:io';

import 'package:test/test.dart';

/// Issue #522 AC3 — no `unlink` on session files anywhere in the product
/// code: every destructive session-file path must route through the
/// trash+journal machinery. This sweep greps the session-layer sources
/// for unlink-shaped calls (`.remove(`, `File.delete`, `Directory.delete`)
/// and fails unless each hit is explicitly allowlisted with a marker
/// comment naming WHY an unlink is legitimate.
void main() {
  final repoRoot = Directory.current.path;

  /// Files whose `.remove(`/`.delete(` calls are swept. [allowlist] maps
  /// a lowercase line snippet (without the marker) to the justification
  /// that must appear next to it.
  final swept = <String, Map<String, String>>{
    'lib/src/session/session_repo.dart': {},
    'lib/src/session/session_storage.dart': {},
    'lib/src/session/windowed_session_storage.dart': {},
    'lib/src/session/session_chunk_reader.dart': {},
    'lib/src/session/agent_session_manager.dart': {},
    'lib/src/cli/session_commands.dart': {},
  };

  /// Unlink markers that are NOT session JSONL files — heartbeat
  /// sidecars, lease sidecars, temp files of the lease store.
  const nonSessionUnlinkOk = {'file_presence_store.dart', 'session_lease.dart'};

  test('every unlink in the session layer is allowlisted and marked', () {
    final violations = <String>[];
    for (final entry in swept.entries) {
      final file = File('$repoRoot/${entry.key}');
      expect(file.existsSync(), isTrue, reason: '${entry.key} missing');
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        // Filesystem-shaped unlinks only: a `.remove(`/`.delete(` on a
        // filesystem receiver (`_fs.`, `env.`) or a dart:io entity.
        // In-memory map/list `.remove(` calls are not file deletions;
        // the word "unlink" in prose is documentation, not a call.
        final isUnlink =
            (line.contains('.remove(') || line.contains('.delete(')) &&
            (line.contains('fs.') ||
                line.contains('_fs') ||
                line.contains('env.') ||
                line.contains('_env') ||
                line.contains('File(') ||
                line.contains('Directory('));
        if (!isUnlink) continue;
        if (line.contains('removeWhere') ||
            line.contains('removeAt') ||
            line.contains('removeLast') ||
            line.contains('.removeListener')) {
          continue; // collection/listener ops, not filesystem unlinks
        }
        // An allowed unlink must carry the marker within the three lines
        // above it (the statement can span lines): `// unlink-ok: <why>`.
        final lookback = lines.sublist(i >= 3 ? i - 3 : 0, i + 1);
        final context = lookback.join('\n');
        if (!context.contains('unlink-ok:')) {
          violations.add('${entry.key}:${i + 1}: $line.trim()');
        }
      }
    }
    expect(
      violations,
      isEmpty,
      reason:
          'session-file unlinks must route through trash+journal (issue '
          '#522); tag any legitimate unlink with a `// unlink-ok: <reason>` '
          'comment',
    );
  });

  test('heartbeat/lease sidecar stores keep their non-session unlinks', () {
    // The presence store and the lease store unlink THEIR OWN sidecar
    // files (heartbeats, `_owner.json`, acquire temp files) — never
    // session JSONL. If these files start removing `.jsonl` paths, this
    // guard fails so the change gets a second look.
    for (final name in nonSessionUnlinkOk) {
      final file = File('$repoRoot/lib/src/session/attach/$name');
      expect(file.existsSync(), isTrue);
      final unlinkLines = file
          .readAsLinesSync()
          .where((l) => l.contains('.remove('))
          .toList();
      expect(
        unlinkLines,
        isNotEmpty,
        reason: '$name lost its sidecar cleanup — sweep is stale',
      );
      for (final line in unlinkLines) {
        expect(
          line,
          isNot(contains('.jsonl')),
          reason:
              '$name must never remove session JSONL files — it '
              'manages sidecars only (issue #522 sweep). Line: $line',
        );
      }
    }
  });

  test('session deletes land in .trash via rename, not remove', () {
    final source = File(
      '$repoRoot/lib/src/session/session_repo.dart',
    ).readAsLinesSync();
    // The delete path must reference the trash dir and a rename-first
    // strategy — the sweep above already forbids bare removes.
    expect(source.any((l) => l.contains('.trash')), isTrue);
    expect(source.any((l) => l.contains('renamePath')), isTrue);
  });
}
