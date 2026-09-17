// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

import 'dart:convert';

import 'package:fa/sandbox/shell_parser.dart';

/// Pure, shell-semantics helpers extracted from [WasiSandboxShell] so the
/// CRAP descent (#475) can unit test them without loading WASM cores.
///
/// Every function here is synchronous, allocation-only, and side-effect
/// free; the WASM shell owns the I/O around them. Behavior is IDENTICAL to
/// the inline code it replaced.

/// Parsed `grep` argv: pass-through flags, pattern, and file operands.
final class GrepArgs {
  /// Creates the parse result.
  const GrepArgs({
    required this.flags,
    required this.pattern,
    required this.files,
    required this.quiet,
  });

  /// Flags forwarded to `rg` verbatim (`-i`, `-v`, `-w`, `-x`, `-F`, `-n`,
  /// `-c`, `-l`, `-m[ N]`).
  final List<String> flags;

  /// The pattern (positional or `-e`), or `null` when none was given.
  final String? pattern;

  /// File operands after the pattern.
  final List<String> files;

  /// `-q`/`--quiet`/`--silent` was given.
  final bool quiet;
}

const _grepQuietFlags = {'-q', '--quiet', '--silent'};
const _grepIgnoredFlags = {'--', '-r', '-R', '-E'};
const _grepPassThroughFlags = {'-i', '-v', '-w', '-x', '-F', '-n', '-c', '-l'};

/// Parses `grep` argv the way busybox grep does for the sandbox subset.
///
/// Returns `null` when `-e` is missing its value (grep exits 2 for that).
/// `-r`/`-R`/`-E` are accepted and ignored — `rg` already searches
/// recursively and uses regex syntax by default.
GrepArgs? parseGrepArgs(List<String> args) {
  final flags = <String>[];
  String? pattern;
  final files = <String>[];
  var quiet = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-e') {
      if (i + 1 >= args.length) return null;
      pattern = args[++i];
      continue;
    }
    if (_grepQuietFlags.contains(arg)) {
      quiet = true;
      continue;
    }
    if (_grepIgnoredFlags.contains(arg)) continue;
    if (_grepPassThroughFlags.contains(arg)) {
      flags.add(arg);
      continue;
    }
    if (arg.startsWith('-m')) {
      flags.add(arg);
      if (arg == '-m' && i + 1 < args.length) {
        flags.add(args[++i]);
      }
      continue;
    }
    if (pattern == null) {
      pattern = arg;
    } else {
      files.add(arg);
    }
  }
  return GrepArgs(flags: flags, pattern: pattern, files: files, quiet: quiet);
}

/// Redirect targets resolved for one pipeline stage.
final class StageRedirects {
  /// Creates the resolved targets.
  const StageRedirects({
    required this.stdoutFile,
    required this.stderrFile,
    required this.stdinFile,
    required this.appendStdout,
    required this.appendStderr,
  });

  /// `> file` / `>> file` target for stdout, or `null`.
  final String? stdoutFile;

  /// `2> file` / `2>> file` target for stderr, or `null`.
  final String? stderrFile;

  /// `< file` stdin source, or `null`.
  final String? stdinFile;

  /// Stdout target opened for append (`>>`).
  final bool appendStdout;

  /// Stderr target opened for append (`2>>`).
  final bool appendStderr;
}

/// Resolves a stage's redirect list into targets.
///
/// Replicates the original precedence exactly: fd 0 read wins first, then
/// `fd == 1 || fd == -1`, then `fd == 2 || fd == -1` — so `&>` (fd -1
/// write) lands on stdout only, and a later redirect for the same stream
/// overwrites an earlier one.
StageRedirects collectStageRedirects(List<Redirect> redirects) {
  String? stdoutFile;
  String? stderrFile;
  String? stdinFile;
  var appendStdout = false;
  var appendStderr = false;

  for (final redirect in redirects) {
    if (redirect.fd == 0 && redirect.kind == RedirectKind.read) {
      stdinFile = redirect.target;
    } else if (redirect.fd == 1 || redirect.fd == -1) {
      if (redirect.kind == RedirectKind.write) {
        stdoutFile = redirect.target;
        appendStdout = false;
      } else if (redirect.kind == RedirectKind.append) {
        stdoutFile = redirect.target;
        appendStdout = true;
      }
    } else if (redirect.fd == 2 || redirect.fd == -1) {
      if (redirect.kind == RedirectKind.write) {
        stderrFile = redirect.target;
        appendStderr = false;
      } else if (redirect.kind == RedirectKind.append) {
        stderrFile = redirect.target;
        appendStderr = true;
      }
    }
  }
  return StageRedirects(
    stdoutFile: stdoutFile,
    stderrFile: stderrFile,
    stdinFile: stdinFile,
    appendStdout: appendStdout,
    appendStderr: appendStderr,
  );
}

/// Matches SIGPIPE stderr noise only: bare `Broken pipe` or the
/// `<tool>: <stream>: Broken pipe` shape busybox tools emit. Deliberately
/// does NOT match python tracebacks (`BrokenPipeError: [Errno 32] ...`).
final RegExp _sigpipeNoise = RegExp(
  r'^(Broken pipe|[\w./-]+: (?:stdout|stderr): Broken pipe)$',
);

bool _isSigpipeNoise(String line) => _sigpipeNoise.hasMatch(line.trim());

/// Strips WASI SIGPIPE noise lines from captured stderr (issue #337 AC5).
///
/// Only the bare `<tool>: stdout: Broken pipe` shape is removed; a python
/// `BrokenPipeError: [Errno 32] Broken pipe` traceback stays. Returns the
/// input bytes untouched when no noise line is present.
List<int> stripSigpipeNoise(List<int> stderrBytes) {
  final text = utf8.decode(stderrBytes, allowMalformed: true);
  final lines = text.split('\n');
  final hasNoise = lines.any(_isSigpipeNoise);
  if (!hasNoise) return stderrBytes;
  return utf8.encode(lines.where((l) => !_isSigpipeNoise(l)).join('\n'));
}

/// Evaluates a `test` binary operator ([op]) between string operands.
///
/// Returns `null` for an unsupported operator so the caller can raise the
/// shell's `unsupported binary operator` error. Numeric comparisons parse
/// both sides as ints and propagate FormatException on garbage.
bool? evalTestBinaryOp(String op, String left, String right) {
  switch (op) {
    case '=':
      return left == right;
    case '!=':
      return left != right;
    case '-eq':
      return int.parse(left) == int.parse(right);
    case '-ne':
      return int.parse(left) != int.parse(right);
    case '-lt':
      return int.parse(left) < int.parse(right);
    case '-le':
      return int.parse(left) <= int.parse(right);
    case '-gt':
      return int.parse(left) > int.parse(right);
    case '-ge':
      return int.parse(left) >= int.parse(right);
    default:
      return null;
  }
}

/// Declarative flag table for a builtin argv family: boolean [flags],
/// [valueFlags] consuming the next token, everything else positional or
/// skipped (issue #559).
final class FlagSpec {
  /// Creates a spec; both sets default to empty.
  const FlagSpec({this.flags = const {}, this.valueFlags = const {}});

  /// Boolean flags the builtin understands.
  final Set<String> flags;

  /// Flags whose value is the next argv token.
  final Set<String> valueFlags;
}

/// Scan result: which flags toggled, what values were captured, and the
/// positional operands in order. Unknown dash-args are skipped (the frozen
/// du/tac behavior).
final class ScannedArgs {
  const ScannedArgs({
    required this.flags,
    required this.values,
    required this.positional,
  });

  /// Toggled boolean flags.
  final Set<String> flags;

  /// Captured `valueFlag -> value` pairs.
  final Map<String, String> values;

  /// Non-dash operands in argv order.
  final List<String> positional;

  /// True when [flag] (short or long form) was toggled.
  bool has(String flag) => flags.contains(flag);
}

/// Generic spec-driven argv scanner shared by the flag-taking builtins
/// (issue #559): dash-args matching [FlagSpec.flags] toggle, those matching
/// [FlagSpec.valueFlags] consume the following token, unknown dash-args are
/// ignored, non-dash args collect as positionals.
ScannedArgs scanFlags(Iterable<String> args, FlagSpec spec) {
  final flags = <String>{};
  final values = <String, String>{};
  final positional = <String>[];
  final it = args.iterator;
  while (it.moveNext()) {
    final arg = it.current;
    if (!arg.startsWith('-')) {
      positional.add(arg);
      continue;
    }
    if (spec.flags.contains(arg)) {
      flags.add(arg);
      continue;
    }
    if (spec.valueFlags.contains(arg) && it.moveNext()) {
      values[arg] = it.current;
    }
  }
  return ScannedArgs(flags: flags, values: values, positional: positional);
}

/// Parsed `du` argv (issue #559).
final class DuArgs {
  const DuArgs({
    required this.human,
    required this.summarize,
    required this.paths,
  });

  /// `-h`/`--human-readable` was given.
  final bool human;

  /// `-s`/`--summarize` was given.
  final bool summarize;

  /// Operand paths; `.` when none were given.
  final List<String> paths;
}

const _duFlagSpec = FlagSpec(
  flags: {'-h', '--human-readable', '-s', '--summarize'},
);

/// Parses `du` argv: the human/summarize flags plus operand paths.
DuArgs parseDuArgs(List<String> args) {
  final scanned = scanFlags(args, _duFlagSpec);
  return DuArgs(
    human: scanned.has('-h') || scanned.has('--human-readable'),
    summarize: scanned.has('-s') || scanned.has('--summarize'),
    paths: scanned.positional.isEmpty ? const ['.'] : scanned.positional,
  );
}

/// Sizes [bytes] for `du` output: K-rounded 1024 blocks, or the human
/// B/K/M/G/T ladder with one decimal below 10 (issue #559).
String formatDuSize(int bytes, {required bool human}) {
  if (!human) return '${(bytes + 1023) ~/ 1024}';
  const units = ['B', 'K', 'M', 'G', 'T'];
  var size = bytes.toDouble();
  var unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  final text = size >= 10 || unit == 0
      ? size.round().toString()
      : size.toStringAsFixed(1);
  return '$text${units[unit]}';
}

/// Reverses the lines of [content] the way `tac` does: a trailing newline
/// survives as the record separator of the last (now first) line, and
/// empty input stays empty (issue #559).
String reverseLines(String content) {
  final hadTrailingNewline = content.endsWith('\n');
  final lines = content.split('\n');
  if (hadTrailingNewline) lines.removeLast();
  final reversed = lines.reversed.join('\n');
  return hadTrailingNewline || reversed.isNotEmpty ? '$reversed\n' : reversed;
}

/// POSIX character classes understood by the sandbox `tr` (issue #559).
const _trCharClasses = <String, String>{
  '[:lower:]': 'abcdefghijklmnopqrstuvwxyz',
  '[:upper:]': 'ABCDEFGHIJKLMNOPQRSTUVWXYZ',
  '[:digit:]': '0123456789',
  '[:alnum:]': 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789',
  '[:space:]': ' \t\n\r\f\v',
};

/// Expands POSIX character classes (`[:lower:]`) and ranges (`a-z`) used by
/// the `tr` builtin (issue #559).
List<String> expandTrSet(String set) {
  final result = <String>[];
  var i = 0;
  while (i < set.length) {
    String? matchedClass;
    for (final cls in _trCharClasses.keys) {
      if (set.startsWith(cls, i)) {
        matchedClass = cls;
        break;
      }
    }
    if (matchedClass != null) {
      result.addAll(_trCharClasses[matchedClass]!.split(''));
      i += matchedClass.length;
      continue;
    }
    if (i + 2 < set.length && set[i + 1] == '-') {
      for (var c = set.codeUnitAt(i); c <= set.codeUnitAt(i + 2); c++) {
        result.add(String.fromCharCode(c));
      }
      i += 3;
      continue;
    }
    result.add(set[i]);
    i++;
  }
  return result;
}

/// Parsed `tr` argv. [set1] may be null only for the malformed argv the
/// validator reports; any non-`-d` token becomes a set, exactly like the
/// frozen builtin (issue #559).
final class TrInvocation {
  const TrInvocation({
    required this.delete,
    required this.set1,
    required this.set2,
  });

  /// `-d` was given.
  final bool delete;

  /// First set operand.
  final String? set1;

  /// Second set operand (null for delete mode).
  final String? set2;
}

/// Parses `tr` argv: `-d` toggles delete mode, the remaining tokens fill
/// set1 then set2 in order (issue #559).
TrInvocation parseTrArgs(List<String> args) {
  var delete = false;
  String? set1;
  String? set2;
  for (final arg in args) {
    if (arg == '-d') {
      delete = true;
    } else if (set1 == null) {
      set1 = arg;
    } else {
      set2 ??= arg;
    }
  }
  return TrInvocation(delete: delete, set1: set1, set2: set2);
}

/// Validates a parsed [invocation]; returns the GNU-shaped error message or
/// null when the invocation is executable (issue #559).
String? validateTrInvocation(TrInvocation invocation) {
  if (invocation.set1 == null) return 'tr: missing operand';
  if (!invocation.delete && invocation.set2 == null) {
    return 'tr: missing operand after "${invocation.set1}"';
  }
  return null;
}

/// Applies a validated [invocation] to [input]: translate set1 to set2
/// (the last set2 char extends for the tail), or delete set1 characters
/// (issue #559).
String applyTr(String input, TrInvocation invocation) {
  final set1 = expandTrSet(invocation.set1!);
  if (invocation.delete) {
    final chars = set1.toSet();
    return input.split('').where((c) => !chars.contains(c)).join();
  }
  final set2 = expandTrSet(invocation.set2!);
  final map = <String, String>{};
  for (var i = 0; i < set1.length; i++) {
    map[set1[i]] = i < set2.length ? set2[i] : set2.last;
  }
  return input.split('').map((c) => map.containsKey(c) ? map[c]! : c).join();
}

/// Parsed `xargs` argv: the `-I` placeholder (or null) and the index of
/// the command token (issue #559).
final class XargsPlan {
  const XargsPlan({required this.placeholder, required this.commandIndex});

  /// `-I` placeholder string, or null for plain append mode.
  final String? placeholder;

  /// Index of the command token in the original argv.
  final int commandIndex;
}

const _xargsDefaultPlaceholder = '{}';

/// Parses `xargs` argv (issue #559): `-I` takes an attached value
/// (`-I{}`), else the next token, defaulting to `{}`; any other dash-arg is
/// skipped; the first positional token is the command.
XargsPlan parseXargsArgs(List<String> args) {
  String? placeholder;
  var commandIndex = 0;
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg.startsWith('-I')) {
      placeholder = arg.length > 2
          ? arg.substring(2)
          : (i + 1 < args.length ? args[++i] : null);
      if (placeholder == null || placeholder.isEmpty) {
        placeholder = _xargsDefaultPlaceholder;
      }
      commandIndex = i + 1;
      continue;
    }
    if (arg.startsWith('-')) {
      commandIndex = i + 1;
      continue;
    }
    commandIndex = i;
    break;
  }
  return XargsPlan(placeholder: placeholder, commandIndex: commandIndex);
}

/// Plans the concrete `xargs` invocations (issue #559): one per input line
/// with the placeholder substituted in append mode, or a single invocation
/// with all lines appended.
List<List<String>> xargsInvocations(
  List<String> initialArgs,
  List<String> lines,
  String? placeholder,
) {
  if (placeholder == null) {
    return [
      [...initialArgs, ...lines],
    ];
  }
  return [
    for (final line in lines)
      [for (final a in initialArgs) a.replaceAll(placeholder, line)],
  ];
}

/// Validates `test`/`[` argv; returns the GNU-shaped error message (the
/// caller appends the trailing newline) or null (issue #559).
String? validateTestInvocation(String command, List<String> rawArgs) {
  if (command == '[' && (rawArgs.isEmpty || rawArgs.last != ']')) {
    return '[[: missing `]]';
  }
  if (rawArgs.isEmpty) return 'test: missing expression';
  return null;
}

/// Error thrown by [TestEvaluator] for malformed `test` expressions.
final class TestExpressionError implements Exception {
  TestExpressionError(this.message);

  /// Human-readable reason (no command prefix).
  final String message;
}

/// Unary `test` operators taking a path operand; `-z`/`-n` take strings
/// and are handled separately.
const _testFileOps = {'-e', '-f', '-d', '-s'};

/// Minimal evaluator for POSIX `test`/`[` expressions (issue #559; moved
/// from the WASM shell and split per token class).
final class TestEvaluator {
  TestEvaluator({
    required this.fileExists,
    required this.dirExists,
    required this.fileSize,
  });

  final Future<bool> Function(String path) fileExists;
  final Future<bool> Function(String path) dirExists;
  final Future<int> Function(String path) fileSize;

  late List<String> _args;
  int _pos = 0;

  /// Evaluates [args] as a full `test` expression.
  Future<bool> evaluate(List<String> args) async {
    _args = args;
    _pos = 0;
    return _parseOr();
  }

  String? get _peek => _pos < _args.length ? _args[_pos] : null;

  String _advance() {
    final token = _args[_pos];
    _pos++;
    return token;
  }

  Future<bool> _parseOr() async {
    var result = await _parseAnd();
    while (_peek == '-o') {
      _advance();
      result = result || await _parseAnd();
    }
    return result;
  }

  Future<bool> _parseAnd() async {
    var result = await _parseUnary();
    while (_peek == '-a') {
      _advance();
      result = result && await _parseUnary();
    }
    return result;
  }

  Future<bool> _parseUnary() async {
    if (_peek == '!') {
      _advance();
      return !(await _parseUnary());
    }
    return _parsePrimary();
  }

  Future<bool> _parsePrimary() async {
    final token = _advance();
    if (token == '(') return _parseParenGroup();
    if (token.startsWith('-')) return _parseUnaryPrimary(token);
    return _parseBinaryComparison(token);
  }

  Future<bool> _parseParenGroup() async {
    final result = await _parseOr();
    if (_peek != ')') throw TestExpressionError('missing `)`');
    _advance();
    return result;
  }

  Future<bool> _parseUnaryPrimary(String op) async {
    if (op == '-z') return _advance().isEmpty;
    if (op == '-n') return _advance().isNotEmpty;
    final path = _advance();
    if (!_testFileOps.contains(op)) {
      throw TestExpressionError('unsupported unary operator: $op');
    }
    final exists = await fileExists(path);
    return switch (op) {
      '-e' => exists,
      '-f' => exists && !await dirExists(path),
      '-d' => await dirExists(path),
      _ => exists && await fileSize(path) > 0,
    };
  }

  Future<bool> _parseBinaryComparison(String left) async {
    final op = _advance();
    final right = _advance();
    final result = evalTestBinaryOp(op, left, right);
    if (result == null) {
      throw TestExpressionError('unsupported binary operator: $op');
    }
    return result;
  }
}
