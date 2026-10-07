// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'package:flutter_agent_harness/src/utils/glob_match.dart';

/// Pathname (glob) expansion for the sandbox shells (gh-1393 WS-1).
///
/// Pure logic over an injected directory lister, so both the WASI shell
/// (host fs) and the web MemoryShell (in-memory fs) drive the same walker —
/// one conformance table covers both. POSIX semantics: an unquoted word
/// containing `*` or `?` expands to the matching paths sorted
/// lexicographically; when nothing matches, the literal word passes
/// through (bash default, no `nullglob`) — a glob is NEVER a parse error
/// and never an execution error by itself.

/// One directory entry handed to the walker by the shell's fs.
final class GlobEntry {
  /// Creates an entry.
  const GlobEntry(this.name, {this.isDir = false});

  /// Entry name (no directory part).
  final String name;

  /// Whether the entry is a directory (glob segments descend into these).
  final bool isDir;
}

/// Lists [path] (a sandbox-absolute directory) for the walker; `null` when
/// the path is not a directory (or not readable).
typedef GlobDirList = Future<List<GlobEntry>?> Function(String path);

/// Whether [word] is a glob candidate (unquoted `*`/`?` present).
bool isGlobWord(String word) => word.contains('*') || word.contains('?');

/// Expands one glob [pattern] against [cwd] (both sandbox paths, `/`-separated).
///
/// Returns the matched paths in bash's output shape — relative to [cwd]
/// when the pattern was relative, absolute when it started with `/` —
/// sorted lexicographically, or `null` when nothing matched (the caller
/// keeps the literal word). Hidden entries (leading `.`) only match a
/// segment whose own pattern starts with `.` (bash dotglob off). `**`
/// crosses directory levels (zero or more, depth-capped); `*`/`?` never
/// cross `/`.
Future<List<String>?> expandGlobPattern(
  String pattern,
  String cwd,
  GlobDirList listDir,
) async {
  if (!isGlobWord(pattern)) return null;
  final absolute = pattern.startsWith('/');
  final body = absolute ? pattern.substring(1) : pattern;
  final segments = body.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return null;

  // Working set: candidate paths matched so far, always ABSOLUTE sandbox
  // paths (relative patterns are rooted at [cwd] and re-relativized on the
  // way out). A trailing true flag says the candidate is a directory
  // listing root for the NEXT segment.
  var candidates = <_Candidate>[_Candidate(cwd)];
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    final last = i == segments.length - 1;
    final next = <_Candidate>[];
    if (segment == '**') {
      for (final candidate in candidates) {
        // `**` matches zero or more directory levels (globstar): keep the
        // candidate itself plus every descendant directory — and, when it
        // is the last segment, every file too (bash `dir/**` lists the
        // whole subtree).
        next.add(_Candidate(candidate.path, dir: true, keep: true));
        await _descend(
          next,
          candidate.path,
          listDir,
          _globstarDepthCap,
          includeFiles: last,
        );
      }
    } else if (isGlobWord(segment)) {
      final matcher = globToRegExp(segment);
      final matchDot = segment.startsWith('.');
      for (final candidate in candidates) {
        final entries = await listDir(candidate.path);
        if (entries == null) continue;
        for (final entry in entries) {
          if (!matchDot && entry.name.startsWith('.')) continue;
          if (!matcher.hasMatch(entry.name)) continue;
          final path = _join(candidate.path, entry.name);
          next.add(_Candidate(path, dir: entry.isDir, keep: !last));
        }
      }
    } else {
      // Literal segment: candidates extend; existence is verified lazily —
      // a listing of the parent must contain the name (bash only emits
      // existing paths).
      for (final candidate in candidates) {
        if (last) {
          final parent = candidate.path.isEmpty ? '/' : candidate.path;
          final entries = await listDir(parent);
          if (entries == null || !entries.any((e) => e.name == segment)) {
            continue;
          }
        }
        next.add(_Candidate(_join(candidate.path, segment), keep: !last));
      }
    }
    candidates = next;
    if (candidates.isEmpty) return null;
  }

  final matches =
      candidates
          .where((c) => c.path.isNotEmpty && c.path != '/')
          .map((c) {
            var path = c.path;
            if (!absolute) {
              // Output in the pattern's shape: relative matches are relative to
              // [cwd] (bash emits `apps/x/app.json`, not the absolute path).
              final prefix = cwd == '/' ? '/' : '$cwd/';
              if (path.startsWith(prefix)) path = path.substring(prefix.length);
            }
            return path;
          })
          .toSet()
          .toList()
        ..sort();
  return matches.isEmpty ? null : matches;
}

/// `**` recursion cap: enough for any real workspace, bounded enough that
/// a symlink loop cannot spin the walker.
const _globstarDepthCap = 24;

/// One matched-or-candidate path during the segment walk.
class _Candidate {
  _Candidate(this.path, {this.dir = false, this.keep = false});

  /// Absolute sandbox path ('' is the relative-pattern root, i.e. cwd).
  final String path;
  final bool dir;

  /// Survives even when not a final match (an intermediate `**` level).
  final bool keep;
}

String _join(String base, String name) {
  if (base.isEmpty || base == '/') return '/$name';
  return '$base/$name';
}

/// Collects [out] with every entry under [dir] (depth-first, depth-capped);
/// directories always descend, and with [includeFiles] plain files are
/// added too (trailing `**`). Best-effort: unreadable dirs are skipped;
/// hidden dirs are traversed (globstar semantics — a leading `.` hides a
/// name from `*` patterns, not from traversal).
Future<void> _descend(
  List<_Candidate> out,
  String dir,
  GlobDirList listDir,
  int depth, {
  required bool includeFiles,
}) async {
  if (depth <= 0) return;
  final entries = await listDir(dir);
  if (entries == null) return;
  for (final entry in entries) {
    if (entry.name == '.' || entry.name == '..') continue;
    final path = _join(dir, entry.name);
    if (entry.isDir) {
      out.add(_Candidate(path, dir: true, keep: true));
      await _descend(out, path, listDir, depth - 1, includeFiles: true);
    } else if (includeFiles) {
      out.add(_Candidate(path));
    }
  }
}
