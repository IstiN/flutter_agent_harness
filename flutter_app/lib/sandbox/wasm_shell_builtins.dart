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
