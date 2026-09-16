// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The parsed `grep` command line: flag set, pattern, and input files.
typedef GrepInvocation = ({
  Set<String> flags,
  String? pattern,
  List<String> files,
  ({String message, int exitCode})? error,
});

/// Parses the `grep`/`rg` argument list (pure).
GrepInvocation parseGrepArgs(List<String> args) {
  final flags = <String>{};
  String? pattern;
  final files = <String>[];
  var noMoreFlags = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--' && !noMoreFlags) {
      noMoreFlags = true;
      continue;
    }
    if (!noMoreFlags && arg == '-e') {
      if (i + 1 >= args.length) {
        return (
          flags: flags,
          pattern: pattern,
          files: files,
          error: (
            message: 'grep: option requires an argument -- e\n',
            exitCode: 2,
          ),
        );
      }
      pattern = args[++i];
      continue;
    }
    if (!noMoreFlags && arg.startsWith('-') && arg.length > 1) {
      flags.addAll(arg.substring(1).split(''));
      continue;
    }
    if (pattern == null) {
      pattern = arg;
    } else {
      files.add(arg);
    }
  }

  if (pattern == null) {
    return (
      flags: flags,
      pattern: null,
      files: files,
      error: (message: 'grep: missing pattern\n', exitCode: 2),
    );
  }
  return (flags: flags, pattern: pattern, files: files, error: null);
}

/// The match options compiled from the grep flag set.
typedef GrepQuery = ({
  RegExp regex,
  bool invert,
  bool lineNumber,
  bool countOnly,
  bool filesOnly,
  bool quiet,
});

/// Compiles the flag set into a [RegExp] plus the per-line match options.
/// Throws [FormatException]-wrapped [ArgumentError]-free: returns the error
/// message via the record when the pattern is invalid.
typedef GrepCompiled = ({
  GrepQuery? query,
  ({String message, int exitCode})? error,
});

GrepCompiled compileGrepQuery(Set<String> flags, String pattern) {
  final ignoreCase = flags.contains('i');
  final invert = flags.contains('v');
  final lineNumber = flags.contains('n');
  final countOnly = flags.contains('c');
  final filesOnly = flags.contains('l');
  final quiet = flags.contains('q');

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
/// line-numbered matches, `-c` counts, `-l` file names, `-q` silence.
void grepText(String content, String? label, GrepQuery q, GrepAccumulator acc) {
  final lines = content.split('\n');
  if (lines.isNotEmpty && lines.last.isEmpty) lines.removeLast();
  var count = 0;
  var reportedFile = false;
  for (var i = 0; i < lines.length; i++) {
    final found = q.regex.hasMatch(lines[i]);
    if (q.invert ? found : !found) continue;
    acc.anyMatch = true;
    count++;
    if (q.quiet) return;
    if (q.filesOnly) {
      if (label != null && !reportedFile) {
        acc.buffer.writeln(label);
        reportedFile = true;
      }
      return;
    }
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
