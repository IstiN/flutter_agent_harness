// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// The POSIX-ish `grep` command line, parsed ONCE for both sandbox shells
/// (gh-1393 WS-1): the WASI shell forwards the result to `rg` (the rg
/// fallback layer), the web MemoryShell runs its Dart grep over it. One
/// parser kills the drift class — the old per-shell parsers diverged on
/// clustered short flags (`-rl`), `--include=`, `--`, and BRE alternation
/// (`\|`), which is exactly the field evidence this card fixes.
library;

/// Parsed `grep` argv: rg-forwardable flags, pattern, and file operands.
final class GrepArgs {
  /// Creates the parse result.
  const GrepArgs({
    required this.flags,
    required this.pattern,
    required this.files,
    required this.quiet,
    this.recursive = false,
    this.includeGlobs = const {},
    this.excludeGlobs = const {},
    this.error,
  });

  /// Flags forwarded to `rg` verbatim (`-i`, `-v`, `-w`, `-x`, `-F`, `-n`,
  /// `-c`, `-l`, `-o`, `-P`, `-a`, `-I`, context flags with their counts,
  /// `-m[ N]`, translated `-g GLOB` include/exclude filters).
  final List<String> flags;

  /// The pattern (positional or `-e`), BRE alternation/grouping translated
  /// to ERE for the regex engines, or `null` when none was given.
  final String? pattern;

  /// File operands after the pattern (`-` = stdin).
  final List<String> files;

  /// `-q`/`--quiet`/`--silent` was given.
  final bool quiet;

  /// `-r`/`-R`/`--recursive` was given: directory operands are walked.
  final bool recursive;

  /// `--include=GLOB`: during recursion only files whose BASENAME matches
  /// a glob are searched.
  final Set<String> includeGlobs;

  /// `--exclude=GLOB`: during recursion files whose basename matches are
  /// skipped.
  final Set<String> excludeGlobs;

  /// A POSIX-style one-line error for options with no faithful translation
  /// (`grep: invalid option -- 'z'`); the caller renders it with exit code
  /// 2 instead of silently diverging (gh-1393 E2).
  final String? error;

  /// Whether the argv parsed into something executable.
  bool get isUsable => error == null;
}

/// Single-letter flags forwarded to rg under the same letter.
const _rgSameLetterFlags = {'i', 'v', 'w', 'x', 'F', 'n', 'c', 'l', 'o', 'P', 'a'};

/// Long flags → the rg-forwardable token(s) they translate to.
const _longFlagTranslations = <String, List<String>>{
  '--ignore-case': ['-i'],
  '--invert-match': ['-v'],
  '--word-regexp': ['-w'],
  '--line-regexp': ['-x'],
  '--fixed-strings': ['-F'],
  '--count': ['-c'],
  '--files-with-matches': ['-l'],
  '--files-without-match': ['-L'],
  '--line-number': ['-n'],
  '--only-matching': ['-o'],
};

const _quietLongFlags = {'--quiet', '--silent'};
const _recursiveLongFlags = {'-r', '-R', '--recursive'};
const _acceptedNoOpLongFlags = {'--extended-regexp', '--dereference-recursive'};

/// Parses `grep` argv the way GNU grep does for the sandbox subset.
///
/// Returns `null` when `-e` is missing its value (grep exits 2 for that;
/// the historical contract of this function). Clustered short flags
/// (`-rl`, `-rn`, `-in`) split per letter; `--` ends option parsing;
/// `--include=`/`--exclude=` translate to rg `-g` filters; an option with
/// no faithful translation yields [GrepArgs.error] (POSIX-style, exit 2)
/// instead of silently mis-parsing (the old fall-through turned `--include`
/// and even `-rl` into the PATTERN).
GrepArgs? parseGrepArgs(List<String> args) {
  final flags = <String>[];
  final includeGlobs = <String>{};
  final excludeGlobs = <String>{};
  String? pattern;
  final files = <String>[];
  var quiet = false;
  var recursive = false;
  var noMoreFlags = false;
  String? error;

  String fail(String message) {
    error = message;
    return message;
  }

  for (var i = 0; i < args.length; i++) {
    if (error != null) break;
    final arg = args[i];
    if (noMoreFlags || !arg.startsWith('-') || arg == '-') {
      // Positional operand: the first is the pattern, the rest are files.
      if (pattern == null) {
        pattern = arg;
      } else {
        files.add(arg);
      }
      continue;
    }
    if (arg == '--') {
      noMoreFlags = true;
      continue;
    }
    if (arg == '-e') {
      if (i + 1 >= args.length) return null;
      pattern = args[++i];
      continue;
    }
    if (_quietLongFlags.contains(arg)) {
      quiet = true;
      continue;
    }
    if (_recursiveLongFlags.contains(arg)) {
      recursive = true;
      continue;
    }
    if (_acceptedNoOpLongFlags.contains(arg)) continue;
    if (_longFlagTranslations.containsKey(arg)) {
      flags.addAll(_longFlagTranslations[arg]!);
      continue;
    }
    if (arg.startsWith('--include=')) {
      includeGlobs.add(arg.substring('--include='.length));
      continue;
    }
    if (arg.startsWith('--exclude=')) {
      excludeGlobs.add(arg.substring('--exclude='.length));
      continue;
    }
    if (arg.startsWith('--regexp=')) {
      pattern = arg.substring('--regexp='.length);
      continue;
    }
    if (arg.startsWith('--max-count=')) {
      final value = arg.substring('--max-count='.length);
      if (int.tryParse(value) == null) {
        return _unusable(
          flags,
          pattern,
          files,
          quiet,
          recursive,
          includeGlobs,
          excludeGlobs,
          fail('grep: invalid max count: $value\n'),
        );
      }
      flags.addAll(['-m', value]);
      continue;
    }
    if (arg.startsWith('--')) {
      // Unknown long option: POSIX-style loud failure (gh-1393 E2).
      return _unusable(
        flags,
        pattern,
        files,
        quiet,
        recursive,
        includeGlobs,
        excludeGlobs,
        fail("grep: unrecognized option '$arg'\n"),
      );
    }
    // Clustered short flags: `-rl`, `-rn`, `-in` … one letter at a time.
    for (var j = 1; j < arg.length; j++) {
      final letter = arg[j];
      final rest = arg.substring(j + 1);
      switch (letter) {
        case 'e':
          if (rest.isNotEmpty) {
            pattern = rest;
          } else {
            if (i + 1 >= args.length) return null;
            pattern = args[++i];
          }
          j = arg.length; // the remainder was consumed as the pattern
        case 'm':
          if (rest.isNotEmpty) {
            if (int.tryParse(rest) == null) {
              error = fail('grep: invalid max count: $rest\n');
            } else {
              flags.add('-m$rest');
            }
          } else {
            flags.add('-m');
            if (i + 1 < args.length) flags.add(args[++i]);
          }
          j = arg.length;
        case 'A' || 'B' || 'C':
          if (rest.isNotEmpty) {
            if (int.tryParse(rest) == null) {
              error = fail('grep: invalid context length: $rest\n');
            } else {
              flags.addAll(['-$letter', rest]);
            }
          } else if (i + 1 < args.length && int.tryParse(args[i + 1]) != null) {
            flags.addAll(['-$letter', args[++i]]);
          } else {
            error = fail("grep: option requires an argument -- '$letter'\n");
          }
          j = arg.length;
        case 'h':
          // grep -h = no filename column; rg's -h is help — translate.
          flags.add('-I');
        case 'H':
          break; // rg labels matches by default
        case 'r' || 'R':
          recursive = true;
        case 'E':
          break; // rg regex syntax is ERE-shaped already
        case 'q':
          quiet = true;
        case 'T' || 'd' || 's':
          break; // accepted no-ops for the sandbox surface
        case _ when _rgSameLetterFlags.contains(letter):
          flags.add('-$letter');
        default:
          error = fail("grep: invalid option -- '$letter'\n");
      }
      if (error != null) break;
    }
  }
  if (error != null) {
    return _unusable(
      flags,
      pattern,
      files,
      quiet,
      recursive,
      includeGlobs,
      excludeGlobs,
      error,
    );
  }
  final translatedPattern = pattern == null
      ? null
      : (flags.contains('-F') || flags.contains('-P')
            ? pattern
            : translateBREToERE(pattern));
  return GrepArgs(
    flags: flags,
    pattern: translatedPattern,
    files: files,
    quiet: quiet,
    recursive: recursive,
    includeGlobs: includeGlobs,
    excludeGlobs: excludeGlobs,
  );
}

GrepArgs _unusable(
  List<String> flags,
  String? pattern,
  List<String> files,
  bool quiet,
  bool recursive,
  Set<String> includeGlobs,
  Set<String> excludeGlobs,
  String? error,
) => GrepArgs(
  flags: flags,
  pattern: pattern,
  files: files,
  quiet: quiet,
  recursive: recursive,
  includeGlobs: includeGlobs,
  excludeGlobs: excludeGlobs,
  error: error,
);

/// Translates the BRE-only metacharacters (`\|`, `\(`, `\)`, `\{`, `\}`) to
/// their ERE shapes so rg and Dart RegExp both see alternation, groups and
/// intervals (grep's default dialect). `\\` stays a literal backslash;
/// `-F`/`-P` patterns skip this entirely (fixed strings / PCRE pass
/// verbatim); any other escape passes through untouched (back-references
/// `\1`, word boundaries `\<`… keep their escaped spelling).
String translateBREToERE(String pattern) {
  if (!pattern.contains('\\')) return pattern;
  final buffer = StringBuffer();
  var changed = false;
  var i = 0;
  while (i < pattern.length) {
    final char = pattern[i];
    if (char == r'\' && i + 1 < pattern.length) {
      final next = pattern[i + 1];
      if (next == r'\') {
        buffer.write(r'\\');
        i += 2;
        continue;
      }
      const breMetachars = {'|', '(', ')', '{', '}'};
      if (breMetachars.contains(next)) {
        buffer.write(next);
        changed = true;
        i += 2;
        continue;
      }
      buffer
        ..writeCharCode(char.codeUnitAt(0))
        ..writeCharCode(next.codeUnitAt(0));
      i += 2;
      continue;
    }
    buffer.write(char);
    i++;
  }
  return changed ? buffer.toString() : pattern;
}
