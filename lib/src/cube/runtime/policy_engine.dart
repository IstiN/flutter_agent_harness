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
/// additional [CubeSpec.network] check on every operand naming a
/// destination: `scheme://[userinfo@]host[:port]` URLs and bare-host
/// operands (`example.com`, `example.com:8080/x`).
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

  /// Checks the network policy when the command fetches via curl/wget:
  /// every operand naming a destination (URL or bare host) must be
  /// permitted.
  CubePolicyDecision _checkNetworkPolicy(List<String> words) {
    final command = words.first;
    if (command != 'curl' && command != 'wget') {
      return const CubePolicyDecision.allowed();
    }
    for (final word in words.skip(1)) {
      final target = _networkTarget(word);
      if (target == null) continue;
      final (host, port) = target;
      if (!spec.network.permits(host, port)) {
        return CubePolicyDecision.denied(
          "network access to '$host:$port' denied by cube '${spec.name}'",
        );
      }
    }
    return const CubePolicyDecision.allowed();
  }
}

/// URL form recognized for network checks:
/// `scheme://[userinfo@]host[:port]/...`.
///
/// The userinfo prefix — everything up to the LAST `@` before the host
/// (`user`, `user:pass`, even a smuggled `allowed.com`) — is matched and
/// discarded, so `https://user:pass@evil.com` is checked against
/// `evil.com`, never against the userinfo.
final RegExp _urlPattern = RegExp(
  r'^([A-Za-z][A-Za-z0-9+.-]*)://(?:[^/?#]*@)?([^/:?#@]+)(?::(\d+))?',
);

/// Bare-host operand form (`example.com`, `example.com:8080/x`): curl and
/// wget treat a scheme-less dotted operand as an `http://` URL of that
/// host. Only applied to operands [_isHostOperand] accepts.
final RegExp _bareHostPattern = RegExp(r'^([A-Za-z0-9.-]+)(?::(\d+))?(/.*)?$');

/// Extracts the `(host, port)` a curl/wget [operand] would contact, or
/// `null` when the operand names no destination.
(String, int)? _networkTarget(String operand) {
  final url = _urlPattern.firstMatch(operand);
  if (url != null) {
    final explicitPort = url.group(3);
    return (
      url.group(2)!,
      explicitPort != null
          ? int.parse(explicitPort)
          : (url.group(1) == 'https' ? 443 : 80),
    );
  }
  if (!_isHostOperand(operand)) return null;
  final bare = _bareHostPattern.firstMatch(operand);
  if (bare == null) return null;
  final explicitPort = bare.group(2);
  return (bare.group(1)!, explicitPort != null ? int.parse(explicitPort) : 80);
}

/// Whether [operand] is a bare-host candidate: not a flag, dotted, and not
/// an obvious local path (`/abs`, `./rel`, `../rel`, `~/…`).
///
// ponytail: lexical heuristic, not a URL parser — a dotted relative name
// is indistinguishable from a single-label host and `-o out.json` gets
// `out.json` checked (fail-closed); the kernel backend (unshare --net /
// SBPL) is the real gate.
bool _isHostOperand(String operand) {
  if (operand.startsWith('-')) return false;
  if (!operand.contains('.')) return false;
  return !(operand.startsWith('/') ||
      operand.startsWith('./') ||
      operand.startsWith('../') ||
      operand.startsWith('~'));
}

/// Leading `VAR=value` assignment prefix stripped before command matching.
final RegExp _assignmentPattern = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');

/// Lexically splits [line] into the commands it would run.
///
// ponytail: quote-aware scanner, not a shell parser — redirects (`&>`,
// `<<<`), quoting inside `$(`, and `eval` indirection are above this
// ceiling; kernel backends are the hard boundary, this is the convenience
// layer.
List<String> _splitSegments(String line) {
  final segments = <String>[];
  final current = StringBuffer();
  final quotes = _QuoteState();
  var i = 0;

  void flush() {
    final segment = current.toString().trim();
    if (segment.isNotEmpty) segments.add(segment);
    current.clear();
  }

  while (i < line.length) {
    final ch = line[i];
    if (quotes.toggle(ch) || quotes.inside) {
      current.write(ch);
      i++;
      continue;
    }
    if (_startsSubshell(line, i)) {
      i = _addSubshellSegments(line, i, segments);
      continue;
    }
    if (_isSegmentBreak(ch)) {
      flush();
      i++;
      continue;
    }
    if (_isSegmentOperator(ch)) {
      if (_isRedirectFdAppend(ch, current)) {
        current.write(ch);
        i++;
        continue;
      }
      flush();
      i = _skipOperatorRun(line, i);
      continue;
    }
    current.write(ch);
    i++;
  }
  flush();
  return segments;
}

/// Quote state while scanning a command line or splitting words.
final class _QuoteState {
  var inSingle = false;
  var inDouble = false;

  /// Consumes a quote character: toggles the matching quote kind unless it
  /// is masked by the other kind being open. Returns whether [ch] was an
  /// effective quote.
  bool toggle(String ch) {
    if (ch == "'" && !inDouble) {
      inSingle = !inSingle;
      return true;
    }
    if (ch == '"' && !inSingle) {
      inDouble = !inDouble;
      return true;
    }
    return false;
  }

  /// Whether a quote kind is currently open.
  bool get inside => inSingle || inDouble;
}

/// Whether [i] starts a subshell: a backtick or a `$( ... )` group.
bool _startsSubshell(String line, int i) =>
    line[i] == '`' ||
    (line[i] == r'$' && i + 1 < line.length && line[i + 1] == '(');

/// Splits the subshell contents starting at [i] into [segments] so the
/// operators inside are checked too; returns the index just past the
/// subshell.
int _addSubshellSegments(String line, int i, List<String> segments) {
  final (inner, next) = line[i] == '`'
      ? _backtickInner(line, i)
      : _dollarParenInner(line, i);
  segments.addAll(_splitSegments(inner));
  return next;
}

/// Extracts a backticked subshell: `(contents, index just past it)`. An
/// unterminated backtick runs to end of line.
(String, int) _backtickInner(String line, int i) {
  final close = line.indexOf('`', i + 1);
  return close == -1
      ? (line.substring(i + 1), line.length)
      : (line.substring(i + 1, close), close + 1);
}

/// Extracts a `$( ... )` subshell with paren-depth matching:
/// `(contents, index just past it)`. An unterminated group runs to end of
/// line.
(String, int) _dollarParenInner(String line, int i) {
  var depth = 1;
  var j = i + 2;
  while (j < line.length && depth > 0) {
    if (line[j] == '(') depth++;
    if (line[j] == ')') depth--;
    j++;
  }
  return (
    line.substring(i + 2, depth == 0 ? j - 1 : line.length),
    depth == 0 ? j : line.length,
  );
}

/// Whether [ch] unconditionally ends the current segment.
bool _isSegmentBreak(String ch) => ch == ';' || ch == '\n' || ch == '\r';

/// Whether [ch] starts a `|`/`&` operator run.
bool _isSegmentOperator(String ch) => ch == '|' || ch == '&';

/// Whether [ch] is an `&` that belongs to a `2>&1`-style redirect rather
/// than a separator.
bool _isRedirectFdAppend(String ch, StringBuffer current) =>
    ch == '&' && current.toString().trim().endsWith('>');

/// Index just past the `|`/`&` operator run starting at [i].
int _skipOperatorRun(String line, int i) {
  while (i < line.length && _isSegmentOperator(line[i])) {
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
  final quotes = _QuoteState();
  var hasWord = false;

  void flushWord() {
    if (hasWord) {
      words.add(current.toString());
      current.clear();
      hasWord = false;
    }
  }

  for (var i = 0; i < segment.length; i++) {
    final ch = segment[i];
    if (quotes.toggle(ch)) {
      hasWord = true;
      continue;
    }
    if (!quotes.inside && (ch == ' ' || ch == '\t')) {
      flushWord();
      continue;
    }
    current.write(ch);
    hasWord = true;
  }
  flushWord();
  return words;
}
