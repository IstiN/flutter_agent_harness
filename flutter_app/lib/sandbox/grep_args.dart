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
const _rgSameLetterFlags = {
  'i',
  'v',
  'w',
  'x',
  'F',
  'n',
  'c',
  'l',
  'o',
  'P',
  'a',
};

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
///
/// Decomposed per the CRAP ratchet (gh-1393): the driver walks argv, one
/// element at a time, through [_parseElement] → long options / short
/// clusters; the mutable [_GrepParse] accumulates fields exactly as the
/// original single function did, so behavior (and the exit-2-vs-1
/// contract) is unchanged — the grep_args/conformance/parity suites pin
/// it.
GrepArgs? parseGrepArgs(List<String> args) {
  final state = _GrepParse();
  for (var i = 0; i < args.length; i++) {
    final resume = _parseElement(state, args, i);
    if (resume == null) return null; // `-e` missing its value
    if (state.error != null) break;
    i = resume - 1; // the loop increment re-advances to [resume]
  }
  return _buildArgs(state);
}

/// Mutable accumulator for one [parseGrepArgs] run — the same fields the
/// original single-function parser kept as locals.
class _GrepParse {
  final flags = <String>[];
  final files = <String>[];
  final includeGlobs = <String>{};
  final excludeGlobs = <String>{};

  String? pattern;
  String? error;

  bool quiet = false;
  bool recursive = false;

  /// `-E` / `--extended-regexp`: ERE input, no BRE pass.
  bool extended = false;

  /// `--` seen: every remaining operand is positional.
  bool noMoreFlags = false;
}

/// Parses argv element [i], returning the index to RESUME at (helpers may
/// consume the element after theirs), or `null` when `-e` ran out of
/// value — the whole parse returns `null` then (historical contract).
int? _parseElement(_GrepParse state, List<String> args, int i) {
  final arg = args[i];
  if (state.noMoreFlags || !arg.startsWith('-') || arg == '-') {
    // Positional operand: the first is the pattern, the rest are files.
    if (state.pattern == null) {
      state.pattern = arg;
    } else {
      state.files.add(arg);
    }
    return i + 1;
  }
  if (arg == '--') {
    state.noMoreFlags = true;
    return i + 1;
  }
  if (arg.startsWith('--')) return _parseLongOption(state, arg, i);
  return _parseShortCluster(state, arg, args, i);
}

/// The long-option ladder, in the original check order. Unknown long
/// options fail POSIX-style loud (gh-1393 E2).
int? _parseLongOption(_GrepParse state, String arg, int i) {
  if (_quietLongFlags.contains(arg)) {
    state.quiet = true;
  } else if (_recursiveLongFlags.contains(arg)) {
    state.recursive = true;
  } else if (arg == '--extended-regexp') {
    state.extended = true;
  } else if (_acceptedNoOpLongFlags.contains(arg)) {
    // accepted no-op for the sandbox surface
  } else if (_longFlagTranslations.containsKey(arg)) {
    state.flags.addAll(_longFlagTranslations[arg]!);
  } else if (arg.startsWith('--include=')) {
    state.includeGlobs.add(arg.substring('--include='.length));
  } else if (arg.startsWith('--exclude=')) {
    state.excludeGlobs.add(arg.substring('--exclude='.length));
  } else if (arg.startsWith('--regexp=')) {
    state.pattern = arg.substring('--regexp='.length);
  } else if (arg.startsWith('--max-count=')) {
    _setMaxCount(state, arg.substring('--max-count='.length));
  } else {
    state.error = "grep: unrecognized option '$arg'\n";
  }
  return i + 1;
}

/// `--max-count=N`: forwards rg's `-m N` pair; a non-numeric count is a
/// POSIX-style error, never a silent mis-parse.
void _setMaxCount(_GrepParse state, String value) {
  if (int.tryParse(value) == null) {
    state.error = 'grep: invalid max count: $value\n';
    return;
  }
  state.flags.addAll(['-m', value]);
}

/// The short letters that take a value (from the cluster remainder or the
/// next argv element); consuming one ends the cluster.
const _valuedShortLetters = {'e', 'm', 'A', 'B', 'C'};

/// One clustered-short element (`-rl`, `-rn`, `-in` …), one letter at a
/// time. Value-taking letters ([_valuedShortLetters]) delegate to
/// [_parseValuedShortLetter] and end the cluster; the rest apply inline.
int? _parseShortCluster(
  _GrepParse state,
  String arg,
  List<String> args,
  int i,
) {
  for (var j = 1; j < arg.length; j++) {
    final letter = arg[j];
    if (_valuedShortLetters.contains(letter)) {
      return _parseValuedShortLetter(
        state,
        letter,
        arg.substring(j + 1),
        args,
        i,
      );
    }
    if (!_applySimpleShortLetter(state, letter)) {
      state.error = "grep: invalid option -- '$letter'\n";
      return i + 1;
    }
  }
  return i + 1;
}

/// `e`, `m`, `A|B|C`: the value comes from the cluster remainder when
/// attached, else the NEXT argv element (which the resume index skips).
/// Returns the resume index, or `null` when `-e` ran out of argv.
int? _parseValuedShortLetter(
  _GrepParse state,
  String letter,
  String rest,
  List<String> args,
  int i,
) {
  switch (letter) {
    case 'e':
      if (rest.isNotEmpty) {
        state.pattern = rest;
        return i + 1;
      }
      if (i + 1 >= args.length) return null;
      state.pattern = args[i + 1];
      return i + 2;
    case 'm':
      if (rest.isNotEmpty) {
        if (int.tryParse(rest) == null) {
          state.error = 'grep: invalid max count: $rest\n';
        } else {
          state.flags.add('-m$rest');
        }
        return i + 1;
      }
      state.flags.add('-m');
      if (i + 1 < args.length) {
        state.flags.add(args[i + 1]);
        return i + 2;
      }
      return i + 1;
    default: // 'A' | 'B' | 'C' — context flags, count attached or next.
      if (rest.isNotEmpty) {
        if (int.tryParse(rest) == null) {
          state.error = 'grep: invalid context length: $rest\n';
        } else {
          state.flags.addAll(['-$letter', rest]);
        }
        return i + 1;
      }
      if (i + 1 < args.length && int.tryParse(args[i + 1]) != null) {
        state.flags.addAll(['-$letter', args[i + 1]]);
        return i + 2;
      }
      state.error = "grep: option requires an argument -- '$letter'\n";
      return i + 1;
  }
}

/// The value-less short letters. Returns `false` for a letter with no
/// faithful translation — the caller records the POSIX-style error.
bool _applySimpleShortLetter(_GrepParse state, String letter) {
  switch (letter) {
    case 'h':
      // grep -h = no filename column; rg's -h is help — translate.
      state.flags.add('-I');
    case 'H':
      break; // rg labels matches by default
    case 'r' || 'R':
      state.recursive = true;
    case 'E':
      state.extended = true; // rg regex syntax is ERE-shaped already
    case 'q':
      state.quiet = true;
    case 'T' || 'd' || 's':
      break; // accepted no-ops for the sandbox surface
    case _ when _rgSameLetterFlags.contains(letter):
      state.flags.add('-$letter');
    default:
      return false;
  }
  return true;
}

/// Assembles the [GrepArgs] out of the accumulated state — the unusable
/// shape when an error was recorded (everything parsed SO FAR rides
/// along), the translated pattern otherwise.
GrepArgs _buildArgs(_GrepParse state) {
  final translatedPattern = state.pattern == null
      ? null
      : (state.flags.contains('-F') ||
                state.flags.contains('-P') ||
                state.extended
            ? state.pattern
            : translateBREToERE(state.pattern!));
  return GrepArgs(
    flags: state.flags,
    pattern: state.error != null ? state.pattern : translatedPattern,
    files: state.files,
    quiet: state.quiet,
    recursive: state.recursive,
    includeGlobs: state.includeGlobs,
    excludeGlobs: state.excludeGlobs,
    error: state.error,
  );
}

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
