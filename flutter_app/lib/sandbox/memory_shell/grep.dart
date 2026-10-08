// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The portable Dart grep engine (web MemoryShell, gh-1393 WS-1): pattern
/// compilation and per-content-block matching only. The command line is
/// parsed by the SHARED parser (`grep_args.dart`/`parseGrepArgs`), so both
/// shells speak one grep dialect.
library;

/// The match options compiled from the grep flag set.
typedef GrepQuery = ({
  RegExp regex,
  bool invert,
  bool lineNumber,
  bool countOnly,
  bool filesOnly,
  bool quiet,

  /// `-m N`: stop emitting after N selected lines per file (with `-o`:
  /// N matches). Null = unbounded.
  int? maxCount,

  /// `-o`: print each match on its own line instead of the whole line.
  bool onlyMatching,
});

/// Compiles the flag set into a [RegExp] plus the per-line match options.
/// Throws [FormatException]-wrapped [ArgumentError]-free: returns the error
/// message via the record when the pattern is invalid. [maxCount] carries
/// the parsed `-m N` value (the flag set has no room for values).
typedef GrepCompiled = ({
  GrepQuery? query,
  ({String message, int exitCode})? error,
});

GrepCompiled compileGrepQuery(
  Set<String> flags,
  String pattern, {
  int? maxCount,
}) {
  final ignoreCase = flags.contains('i');
  final invert = flags.contains('v');
  final lineNumber = flags.contains('n');
  final countOnly = flags.contains('c');
  final filesOnly = flags.contains('l');
  final quiet = flags.contains('q');
  final onlyMatching = flags.contains('o');

  var source = pattern;
  if (flags.contains('F')) source = RegExp.escape(source);
  if (flags.contains('w')) source = '\\b(?:$source)\\b';
  if (flags.contains('x')) source = '^(?:$source)\$';
  final RegExp regex;
  try {
    regex = RegExp(source, caseSensitive: !ignoreCase);
  } on Object catch (e) {
    return (
      query: null,
      error: (message: 'grep: invalid pattern: $e\n', exitCode: 2),
    );
  }
  return (
    query: (
      regex: regex,
      invert: invert,
      lineNumber: lineNumber,
      countOnly: countOnly,
      filesOnly: filesOnly,
      quiet: quiet,
      maxCount: maxCount,
      onlyMatching: onlyMatching,
    ),
    error: null,
  );
}

/// Output accumulator shared by every content block of one grep run.
final class GrepAccumulator {
  final StringBuffer buffer = StringBuffer();
  var anyMatch = false;
}

/// Greps one content block into [acc] (pure): label-prefixed and
/// line-numbered matches, `-c` counts, `-l` file names, `-q` silence,
/// `-m N` max-count bounds, `-o` match-only output (gh-1393 rework —
/// the flags GNU semantics the shared parser forwards).
void grepText(String content, String? label, GrepQuery q, GrepAccumulator acc) {
  final lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  var count = 0;
  var selected = 0;
  var reportedFile = false;
  final capped = q.maxCount != null;
  lineLoop:
  for (var i = 0; i < lines.length; i++) {
    final found = q.regex.hasMatch(lines[i]);
    if (q.invert ? found : !found) continue;
    if (q.filesOnly) {
      acc.anyMatch = true;
      if (q.quiet) return;
      if (label != null && !reportedFile) {
        acc.buffer.writeln(label);
        reportedFile = true;
      }
      return;
    }
    if (q.onlyMatching && !q.invert) {
      for (final match in q.regex.allMatches(lines[i])) {
        if (match.start == match.end) continue; // GNU skips empty matches
        if (capped && selected >= q.maxCount!) break lineLoop;
        acc.anyMatch = true;
        count++;
        selected++;
        if (q.quiet) return;
        if (label != null) acc.buffer.write('$label:');
        if (q.lineNumber) acc.buffer.write('${i + 1}:');
        acc.buffer.writeln(match.group(0));
      }
      continue;
    }
    if (capped && selected >= q.maxCount!) break lineLoop;
    acc.anyMatch = true;
    count++;
    selected++;
    if (q.quiet) return;
    if (q.countOnly) continue;
    if (label != null) acc.buffer.write('$label:');
    if (q.lineNumber) acc.buffer.write('${i + 1}:');
    acc.buffer.writeln(lines[i]);
  }
  if (q.countOnly && !q.quiet && !q.filesOnly) {
    if (label != null) acc.buffer.write('$label:');
    acc.buffer.writeln(count);
  }
}
