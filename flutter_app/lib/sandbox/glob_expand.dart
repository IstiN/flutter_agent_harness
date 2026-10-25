// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Pathname (glob) expansion for the sandbox shells (gh-1393 WS-1).
///
/// Pure logic over an injected directory lister, so both the WASI shell
/// (host fs) and the web MemoryShell (in-memory fs) drive the same walker —
/// one conformance table covers both. POSIX semantics: an unquoted word
/// containing `*`, `?` or `[` expands to the matching paths sorted
/// lexicographically; when nothing matches, the literal word passes
/// through (bash default, no `nullglob`) — a glob is NEVER a parse error
/// and never an execution error by itself.
///
/// Shipped surface (rework round 3): `*`, `**`, `?` and bracket classes
/// `[...]`/`[!...]`/`[^...]` with ranges. Brace expansion (`{a,b}`) is NOT
/// part of this surface — `shell_parser` reports it as a loud parse error
/// (never a silent divergence).
library;

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

/// Whether [word] is a glob candidate (unquoted `*`/`?`/bracket present).
bool isGlobWord(String word) =>
    word.contains('*') || word.contains('?') || word.contains('[');

/// Expands one glob [pattern] against [cwd] (both sandbox paths, `/`-separated).
///
/// Returns the matched paths in bash's output shape — relative to [cwd]
/// when the pattern was relative, absolute when it started with `/` —
/// sorted lexicographically, or `null` when nothing matched (the caller
/// keeps the literal word). Hidden entries (leading `.`) only match a
/// segment whose own pattern starts with `.` (bash dotglob off). `**`
/// crosses directory levels (zero or more, depth-capped); `*`/`?` never
/// cross `/`.
///
/// The per-segment arms live in the `_expand*Segment` helpers below; the
/// loop only routes (gh-1848 CRAP descent).
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
    final List<_Candidate> next;
    if (segment == '**') {
      next = await _expandGlobstarSegment(candidates, last, listDir);
    } else if (isGlobWord(segment)) {
      next = await _expandWildcardSegment(candidates, segment, last, listDir);
    } else {
      next = await _expandLiteralSegment(candidates, segment, last, listDir);
    }
    candidates = next;
    if (candidates.isEmpty) return null;
  }
  return _formatMatches(candidates, cwd, absolute);
}

/// The `**` segment: keep every candidate (zero levels crossed) plus
/// every descendant directory — and, when it is the last segment, every
/// file too (bash `dir/**` lists the whole subtree).
Future<List<_Candidate>> _expandGlobstarSegment(
  List<_Candidate> candidates,
  bool last,
  GlobDirList listDir,
) async {
  final next = <_Candidate>[];
  for (final candidate in candidates) {
    next.add(_Candidate(candidate.path, dir: true, keep: true));
    await _descend(
      next,
      candidate.path,
      listDir,
      _globstarDepthCap,
      includeFiles: last,
    );
  }
  return next;
}

/// A wildcard segment (`*`/`?`/brackets): list each candidate directory
/// and keep the entries the segment matcher accepts.
Future<List<_Candidate>> _expandWildcardSegment(
  List<_Candidate> candidates,
  String segment,
  bool last,
  GlobDirList listDir,
) async {
  final matcher = _segmentToRegExp(segment);
  final matchDot = segment.startsWith('.');
  final next = <_Candidate>[];
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
  return next;
}

/// A literal segment: candidates extend; existence is verified lazily —
/// a listing of the parent must contain the name (bash only emits
/// existing paths).
Future<List<_Candidate>> _expandLiteralSegment(
  List<_Candidate> candidates,
  String segment,
  bool last,
  GlobDirList listDir,
) async {
  final next = <_Candidate>[];
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
  return next;
}

/// Output in the pattern's shape: relative matches are relative to [cwd]
/// (bash emits `apps/x/app.json`, not the absolute path); sorted
/// lexicographically; `null` when nothing matched.
List<String>? _formatMatches(
  List<_Candidate> candidates,
  String cwd,
  bool absolute,
) {
  final matches =
      candidates.where((c) => c.path.isNotEmpty && c.path != '/').map((c) {
        var path = c.path;
        if (!absolute) {
          final prefix = cwd == '/' ? '/' : '$cwd/';
          if (path.startsWith(prefix)) path = path.substring(prefix.length);
        }
        return path;
      }).toList()..sort();
  return matches.isEmpty ? null : matches;
}

/// `**` recursion cap: enough for any real workspace, bounded enough that
/// a symlink loop cannot spin the walker.
const _globstarDepthCap = 24;

/// Segment-level glob → anchored [RegExp] (gh-1393 rework). `*` matches
/// any run of non-`/` (so `**` inside a segment degrades to it — segments
/// never cross `/`), `?` one non-`/` char, and `[...]`/`[!...]`/`[^...]`
/// bracket classes with ranges. Local to the expansion walker — the core
/// `glob_match.dart` stays skill-activation-only (its doc contract
/// promises "never need character classes", so it is not widened here).
RegExp _segmentToRegExp(String segment) {
  final buffer = StringBuffer('^');
  var i = 0;
  while (i < segment.length) {
    final char = segment[i];
    if (char == '*') {
      buffer.write('[^/]*');
      i++;
    } else if (char == '?') {
      buffer.write('[^/]');
      i++;
    } else if (char == '[') {
      final klass = _bracketClass(segment, i);
      if (klass == null) {
        // Bash: a bracket that never closes is a literal `[`.
        buffer.write(RegExp.escape(char));
        i++;
      } else {
        buffer.write(klass.regex);
        i = klass.next;
      }
    } else {
      buffer.write(RegExp.escape(char));
      i++;
    }
  }
  buffer.write(r'$');
  final RegExp compiled;
  try {
    compiled = RegExp(buffer.toString());
  } on Object {
    // Bash's malformed-bracket rule: an invalid class (out-of-order range
    // like `[%q-%s]` in a stat format word) is not a valid pattern — the
    // word stays literal. A never-matching regex makes the walker report
    // "no match", which is exactly that passthrough.
    return RegExp(r'(?!)');
  }
  return compiled;
}

/// One compiled bracket expression: the regex class body (with `/`
/// excluded for negated classes — segments never cross `/`) and the index
/// AFTER the closing `]`.
final class _BracketClass {
  const _BracketClass(this.regex, this.next, {required this.negated});

  final String regex;
  final int next;
  final bool negated;
}

/// Whether the bracket expression opening at [i] starts with a `!`/`^`
/// negation; returns the index of the first member and the flag.
(int, bool) _bracketNegation(String segment, int i) {
  if (i < segment.length && (segment[i] == '!' || segment[i] == '^')) {
    return (i + 1, true);
  }
  return (i, false);
}

/// The compiled regex class body: a `^` prefix and a `/` exclusion when
/// negated (segments never cross `/`).
String _bracketRegex(String body, bool negated) =>
    '[${negated ? '^' : ''}$body${negated ? '/' : ''}]';

/// Whether [i] opens a backslash escape pair in [segment].
bool _bracketEscaped(String segment, int i) =>
    segment[i] == r'\' && i + 1 < segment.length;

/// Appends one bracket-class member at [i] to [body]: an escaped char
/// joins the class literally (bash fnmatch rule), `x-y` spans a range,
/// anything else is escaped verbatim. Returns the next index.
int _bracketMember(String segment, int i, StringBuffer body) {
  final char = segment[i];
  if (_bracketEscaped(segment, i)) {
    body.write(RegExp.escape(segment[i + 1]));
    return i + 2;
  }
  if (i + 2 < segment.length &&
      segment[i + 1] == '-' &&
      segment[i + 2] != ']') {
    body
      ..write(RegExp.escape(char))
      ..write('-')
      ..write(RegExp.escape(segment[i + 2]));
    return i + 3;
  }
  body.write(RegExp.escape(char));
  return i + 1;
}

/// Compiles the bracket expression whose `[` sits at [start] in
/// [segment], or `null` when it never closes (the caller emits a literal
/// `[`). Bash rules: a leading `!`/`^` negates; a `]` in first position
/// is a literal class member; `x-y` spans a range; an unterminated
/// expression is not a class at all.
_BracketClass? _bracketClass(String segment, int start) {
  final (i, negated) = _bracketNegation(segment, start + 1);
  final body = StringBuffer();
  var first = true;
  var j = i;
  while (j < segment.length) {
    final char = segment[j];
    if (char == ']' && !first) {
      // A negated class must not match `/` either.
      return _BracketClass(
        _bracketRegex('$body', negated),
        j + 1,
        negated: negated,
      );
    }
    first = false;
    j = _bracketMember(segment, j, body);
  }
  return null;
}

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
