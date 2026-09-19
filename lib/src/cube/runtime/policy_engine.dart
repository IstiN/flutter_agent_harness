/// Declarative command policy evaluation for cubes.
///
/// [CubePolicyEngine] is the convenience layer in front of the tool and
/// network policies of a [CubeSpec]: it lexically splits a shell command line
/// into the commands it would run (including subshells) and asks the cube's
/// policies whether every one of them is permitted.
///
/// This is a lexical check, not a shell parser and not confinement — the
/// kernel sandbox backends (`lib/src/cube/backends/`) are the hard boundary.
library;

import '../config/cube_spec.dart';
import '../config/fs_policy.dart';
import '../config/tool_policy.dart';

/// The outcome of a [CubePolicyEngine.checkCommand] evaluation.
final class CubePolicyDecision {
  /// A decision permitting the command.
  const CubePolicyDecision.allowed() : allowed = true, reason = null;

  /// A decision rejecting the command with a human-readable [reason].
  const CubePolicyDecision.denied(String this.reason) : allowed = false;

  /// Whether the command may run.
  final bool allowed;

  /// Why the command was rejected, or `null` when [allowed].
  final String? reason;
}

/// Evaluates a shell command line against a cube's tool and network policies.
///
/// The engine splits the line on shell operators (`|`, `||`, `&&`, `;`, `&`,
/// newlines), extracts `$( ... )` and backtick subshell segments, strips
/// leading `VAR=value` assignments, and checks every resulting command
/// against [CubeSpec.tools]. Commands that invoke `curl` or `wget` — and
/// `gh api <abs-url>` — get an additional [CubeSpec.network] check on the
/// URLs they reference.
///
/// Global destruction (`rm -rf /`) is deliberately not special-cased: the
/// tool allowlist is the mechanism — a cube that does not list `rm` never
/// runs it.
final class CubePolicyEngine {
  /// Creates an engine evaluating commands against [spec].
  ///
  /// [homeDir] resolves `~` redirection targets; [workspaceRoot] overrides
  /// `spec.filesystem.workspace` as the base for relative targets (the
  /// shell passes the real process cwd — the cube's `/workspace` is
  /// realized as the env cwd). A `~` target with an unknown [homeDir] is
  /// denied.
  const CubePolicyEngine(this.spec, {this.homeDir, this.workspaceRoot});

  /// The cube specification whose policies are enforced.
  final CubeSpec spec;

  /// The host home directory, resolving `~` redirection targets.
  final String? homeDir;

  /// The real workspace root, resolving relative redirection targets.
  final String? workspaceRoot;

  /// Checks every command the [commandLine] would run.
  ///
  /// Returns the first denial in left-to-right segment order, or
  /// [CubePolicyDecision.allowed] when every segment passes.
  CubePolicyDecision checkCommand(String commandLine) {
    for (final segment in _splitSegments(commandLine)) {
      final words = _commandWords(segment);
      if (words.isEmpty) continue;
      final toolDecision = _checkToolPolicy(words);
      if (!toolDecision.allowed) return toolDecision;
      final networkDecision = _checkNetworkPolicy(words);
      if (!networkDecision.allowed) return networkDecision;
      final redirectDecision = _checkRedirects(segment);
      if (!redirectDecision.allowed) return redirectDecision;
    }
    return const CubePolicyDecision.allowed();
  }

  /// Checks the tool policy for one command's words, keeping the deny-match
  /// and not-in-allowlist reason wordings apart.
  CubePolicyDecision _checkToolPolicy(List<String> words) {
    final command = words.first;
    final commandWords = words.take(3).join(' ');
    if (spec.tools.permits(commandWords)) {
      return const CubePolicyDecision.allowed();
    }
    // Deny-match detection without duplicating the entry matcher: probe a
    // policy carrying only the allow set — if that would permit the command,
    // the real policy refused it solely because of a deny entry.
    final allowOnly = CubeToolPolicy(allow: spec.tools.allow);
    if (allowOnly.permits(commandWords)) {
      return CubePolicyDecision.denied(
        "command '$command' denied by cube '${spec.name}'",
      );
    }
    return CubePolicyDecision.denied(
      "command '$command' not in cube '${spec.name}' allowlist",
    );
  }

  /// Checks the network policy when the command fetches URLs via curl/wget
  /// or points `gh api` at an absolute URL (issue #682, second tier — the
  /// same lexical shape as the curl/wget scan: URL operands only, not a
  /// shell parser).
  CubePolicyDecision _checkNetworkPolicy(List<String> words) {
    final operands = _networkOperands(words);
    if (operands == null) return const CubePolicyDecision.allowed();
    for (final word in operands) {
      final match = _urlPattern.firstMatch(word);
      if (match == null) continue;
      final host = match.group(2)!;
      final explicitPort = match.group(3);
      final port = explicitPort != null
          ? int.parse(explicitPort)
          : (match.group(1) == 'https' ? 443 : 80);
      if (!spec.network.permits(host, port)) {
        return CubePolicyDecision.denied(
          "network access to '$host:$port' denied by cube '${spec.name}'",
        );
      }
    }
    return const CubePolicyDecision.allowed();
  }

  /// The URL-bearing operands of the command in [words], or `null` when
  /// the command is not one the scan covers: `curl`/`wget` take URLs
  /// anywhere after the program; `gh` only its `api <abs-url>` operands.
  static Iterable<String>? _networkOperands(List<String> words) =>
      switch (words.first) {
        'curl' || 'wget' => words.skip(1),
        'gh' when words.length > 1 && words[1] == 'api' => words.skip(2),
        _ => null,
      };

  /// Checks every shell redirection target of [segment] against the
  /// filesystem policy: a write redirect (`>`, `>>`, `<>`, `&>`, `N>`) must
  /// land in a read/write path, an input redirect (`<`) must not read a
  /// denied path. This is the policy-mode floor for the trivial `>`
  /// escape — lexical, not a shell parser.
  CubePolicyDecision _checkRedirects(String segment) {
    for (final (target, writes) in _redirectTargets(segment)) {
      if (writes && _deviceSinkPattern.hasMatch(target)) continue;
      final access = _fsPolicy.accessFor(_targetPath(target), homeDir: homeDir);
      if (writes && access != CubePathAccess.readWrite) {
        return CubePolicyDecision.denied(
          "write to '$target' denied by cube '${spec.name}'",
        );
      }
      if (!writes && access == CubePathAccess.deny) {
        return CubePolicyDecision.denied(
          "read of '$target' denied by cube '${spec.name}'",
        );
      }
    }
    return const CubePolicyDecision.allowed();
  }

  /// The fs policy with the workspace root swapped to [workspaceRoot] —
  /// the cube's `/workspace` is realized as the process cwd, so paths are
  /// judged against the real root (the same swap the fs guard applies).
  CubeFsPolicy get _fsPolicy => workspaceRoot == null
      ? spec.filesystem
      : CubeFsPolicy(workspace: workspaceRoot!, mounts: spec.filesystem.mounts);

  /// Resolves a redirect target for the policy: absolute and `~` paths as
  /// written, relative against the real workspace root.
  String _targetPath(String target) {
    if (target.startsWith('/') || target.startsWith('~')) return target;
    return '${workspaceRoot ?? spec.filesystem.workspace}/$target';
  }
}

/// URL form recognized for network checks: `scheme://host[:port]/...`.
///
// ponytail: bare-host operands (`curl example.com/x`) are not URLs and are
// not checked; the network backend (unshare --net / SBPL) is the real gate.
final RegExp _urlPattern = RegExp(
  r'^([A-Za-z][A-Za-z0-9+.-]*)://([^/:?#@]+)(?::(\d+))?',
);

/// Leading `VAR=value` assignment prefix stripped before command matching.
final RegExp _assignmentPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');

/// Lexically splits [line] into the commands it would run.
///
// ponytail: quote-aware scanner, not a shell parser — quoting inside `$(`,
// process substitution and `eval` indirection are above this ceiling;
// redirection targets ARE extracted (`_redirectTargets`), kernel backends
// remain the hard boundary, this is the convenience layer.
List<String> _splitSegments(String line) => _SegmentScanner(line).scan();

/// Quote-aware segment scanner for [_splitSegments]: one [_SegmentScanner.step]
/// group per character class keeps every method's complexity small.
class _SegmentScanner {
  _SegmentScanner(this.line);

  final String line;
  final List<String> segments = <String>[];
  final StringBuffer current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var i = 0;

  List<String> scan() {
    while (i < line.length) {
      if (_stepQuoted()) continue;
      if (_stepSubshell()) continue;
      if (_stepSeparator()) continue;
      _writeChar();
    }
    _flush();
    return segments;
  }

  /// Quote toggles and characters inside quotes (verbatim).
  bool _stepQuoted() {
    final ch = line[i];
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
      _writeChar();
      return true;
    }
    if (ch == '"' && !inSingle) {
      inDouble = !inDouble;
      _writeChar();
      return true;
    }
    if (inSingle || inDouble) {
      _writeChar();
      return true;
    }
    return false;
  }

  /// Backtick / `$( … )` subshells: their contents are recursively split so
  /// operators inside are checked too.
  bool _stepSubshell() {
    final ch = line[i];
    if (ch == '`') {
      final (inner, next) = _backtickInner(line, i);
      segments.addAll(_splitSegments(inner));
      i = next;
      return true;
    }
    if (ch == r'$' && i + 1 < line.length && line[i + 1] == '(') {
      final (inner, next) = _dollarParenInner(line, i);
      segments.addAll(_splitSegments(inner));
      i = next;
      return true;
    }
    return false;
  }

  /// Command separators: `;`, newlines, and pipe/ampersand operators.
  bool _stepSeparator() {
    final ch = line[i];
    if (ch == ';' || ch == '\n' || ch == '\r') {
      _flush();
      i++;
      return true;
    }
    if (ch == '|' || ch == '&') {
      // `2>&1` and friends: `&` directly after a redirect is not a separator.
      if (ch == '&' && current.toString().trim().endsWith('>')) {
        _writeChar();
        return true;
      }
      _flush();
      i = _skipOperators(line, i);
      return true;
    }
    return false;
  }

  void _writeChar() {
    current.write(line[i]);
    i++;
  }

  void _flush() {
    final segment = current.toString().trim();
    if (segment.isNotEmpty) segments.add(segment);
    current.clear();
  }
}

/// The inside of a backticked subshell starting at [i] (a backtick) and the
/// index just past the closing backtick (end of line when unterminated).
(String, int) _backtickInner(String line, int i) {
  final close = line.indexOf('`', i + 1);
  return close == -1
      ? (line.substring(i + 1), line.length)
      : (line.substring(i + 1, close), close + 1);
}

/// The inside of a `$( … )` subshell starting at [i] (the `$`) and the index
/// just past the closing paren (end of line when unbalanced).
(String, int) _dollarParenInner(String line, int i) {
  var depth = 1;
  var j = i + 2;
  while (j < line.length && depth > 0) {
    if (line[j] == '(') depth++;
    if (line[j] == ')') depth--;
    j++;
  }
  return depth == 0
      ? (line.substring(i + 2, j - 1), j)
      : (line.substring(i + 2), line.length);
}

/// Skips a run of pipe/ampersand operator characters at [i].
int _skipOperators(String line, int i) {
  while (i < line.length && (line[i] == '|' || line[i] == '&')) {
    i++;
  }
  return i;
}

/// Splits one [segment] into words, then strips leading `VAR=value`
/// assignments, leaving the command and its arguments.
List<String> _commandWords(String segment) {
  final words = _words(segment);
  while (words.isNotEmpty && _assignmentPattern.hasMatch(words.first)) {
    words.removeAt(0);
  }
  return words;
}

/// Quote-aware whitespace split that strips quoting from each word.
List<String> _words(String segment) {
  final words = <String>[];
  final current = StringBuffer();
  var inSingle = false;
  var inDouble = false;
  var hasWord = false;
  for (var i = 0; i < segment.length; i++) {
    final ch = segment[i];
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
      hasWord = true;
      continue;
    }
    if (ch == '"' && !inSingle) {
      inDouble = !inDouble;
      hasWord = true;
      continue;
    }
    if (!inSingle && !inDouble && (ch == ' ' || ch == '\t')) {
      if (hasWord) {
        words.add(current.toString());
        current.clear();
        hasWord = false;
      }
      continue;
    }
    current.write(ch);
    hasWord = true;
  }
  if (hasWord) words.add(current.toString());
  return words;
}

/// Redirect operators recognized for path checks: `>`, `>>`, `<>`, `&>`,
/// and the fd-numbered variants (`2>`, `1>>`, …). `2>&1` parses as `2>`
/// with the fd-duplicate target `&1`, which [_fdTargetPattern] skips.
final RegExp _redirectPattern = RegExp(r'^(\d*&>|&>|\d*>>|\d*<>|\d*>|<)');

/// A file-descriptor duplicate target (`&1`, `2`) — not a path.
final RegExp _fdTargetPattern = RegExp(r'^&?\d+$');

/// Persistence-free device sinks that stay writable outside the workspace:
/// the null device and the stdio fd aliases (`/dev/stdout` → `/dev/fd/N`).
final RegExp _deviceSinkPattern = RegExp(
  r'^/dev/(?:null|stdin|stdout|stderr)$|^/dev/fd/',
);

/// Extracts the redirection targets of [segment] as `(target, writes)`
/// pairs from the quote-stripped words. `>`/`>>`/`<>`/`&>`/`N>` write,
/// `<` reads. The target may be attached (`>file`) or the following word.
///
// ponytail: only path-shaped operator words are checked; exotic forms
// (`&>>`, quoted-adjacent glue) either miss (above the ceiling) or
// resolve to a path the policy then denies — the failure direction is
// deny, never allow.
List<(String, bool)> _redirectTargets(String segment) {
  final words = _words(segment);
  final targets = <(String, bool)>[];
  for (var i = 0; i < words.length; i++) {
    final match = _redirectPattern.firstMatch(words[i]);
    if (match == null) continue;
    final op = match.group(1)!;
    var target = words[i].substring(match.end);
    if (target.isEmpty && i + 1 < words.length) target = words[++i];
    if (target.isEmpty || _fdTargetPattern.hasMatch(target)) continue;
    targets.add((target, op != '<'));
  }
  return targets;
}
