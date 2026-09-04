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
/// against [CubeSpec.tools]. Commands that invoke `curl` or `wget` get an
/// additional [CubeSpec.network] check on the URLs they reference.
///
/// Global destruction (`rm -rf /`) is deliberately not special-cased: the
/// tool allowlist is the mechanism — a cube that does not list `rm` never
/// runs it.
final class CubePolicyEngine {
  /// Creates an engine evaluating commands against [spec].
  const CubePolicyEngine(this.spec);

  /// The cube specification whose policies are enforced.
  final CubeSpec spec;

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

  /// Checks the network policy when the command fetches URLs via curl/wget.
  CubePolicyDecision _checkNetworkPolicy(List<String> words) {
    final command = words.first;
    if (command != 'curl' && command != 'wget') {
      return const CubePolicyDecision.allowed();
    }
    for (final word in words.skip(1)) {
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
// ponytail: quote-aware scanner, not a shell parser — redirects (`&>`,
// `<<<`), quoting inside `$(`, and `eval` indirection are above this
// ceiling; kernel backends are the hard boundary, this is the convenience
// layer.
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
