/// Critical-pattern interceptor for the `bash` tool.
///
/// Destructive shell shapes (`rm -rf /`, fork bombs, remote-fetch-then-
/// execute, disk/device writes, force-pushed history) escalate the call to a
/// prompt no matter what the approval policy says — even under yolo mode.
/// Ported from oh-my-pi's `CRITICAL_BASH_PATTERNS`
/// (`packages/coding-agent/src/tools/bash.ts`), kept intentionally tight: the
/// cost of a false negative is data loss or a compromised host, while false
/// positives remain actionable (the user can still approve the prompt).
library;

/// The canonical name of the shell tool the interceptor applies to
/// (`shellTool` in `builtin_tools.dart` registers under this name).
const bashToolName = 'bash';

/// Tool names whose `command` argument the critical patterns guard: the
/// `bash` tool and the on-device `mobile.shell` (issue #622 — the Shizuku
/// bridge executes at adb-shell privilege, so `rm -rf /`-class shapes
/// must still force a prompt there).
const criticalCommandToolNames = {'bash', 'mobile.shell'};

/// A destructive shell pattern with a human-readable label, surfaced in the
/// approval prompt's reason.
final class CriticalBashPattern {
  /// A regex-shaped entry: matches when [pattern] matches the raw command.
  CriticalBashPattern.regex(this.label, RegExp pattern)
    : _test = pattern.hasMatch;

  /// A parsed-shape entry: [test] decides with full argument awareness
  /// (used where a bare regex over-matches, e.g. the recursive-delete
  /// family — issue #460).
  CriticalBashPattern(this.label, this._test);

  /// Short description of the matched danger (e.g. `recursive delete`).
  final String label;

  final bool Function(String command) _test;

  /// Whether [command] matches this critical shape.
  bool matches(String command) => _test(command);
}

/// Patterns that force an approval prompt for any matching `bash` command.
///
/// Keep the list tight: add shapes that are virtually never legitimate in
/// automation. A prompt (not a block) is the response — the user decides.
final criticalBashPatterns = <CriticalBashPattern>[
  // Recursive destruction (issue #460): recursive means an explicit
  // -r/-R/--recursive flag cluster; root means `/`, a `/*`-style root
  // glob, `~`/`$HOME`, a drive root, or a single top-level component
  // (`/usr`). `rm -f /tmp/x` and `chmod -R 755 /var/www` never match.
  CriticalBashPattern(
    'recursive delete from a root path',
    (command) => _recursiveRootInvocation(command, 'rm'),
  ),
  CriticalBashPattern.regex(
    'sudo rm',
    RegExp(r'\bsudo\s+rm\b', caseSensitive: false),
  ),
  CriticalBashPattern(
    'recursive chmod from a root path',
    (command) => _recursiveRootInvocation(command, 'chmod'),
  ),
  CriticalBashPattern(
    'recursive chown from a root path',
    (command) => _recursiveRootInvocation(command, 'chown'),
  ),

  // Fork bomb (a few common spacings): `:(){ :|:& };:`.
  CriticalBashPattern.regex('fork bomb', RegExp(r':\(\)\s*\{\s*:\s*\|\s*:')),

  // Disk / filesystem destruction.
  CriticalBashPattern.regex(
    'write to a disk device',
    RegExp(r'>\s*/dev/sd[a-z]', caseSensitive: false),
  ),
  CriticalBashPattern.regex(
    'format filesystem',
    RegExp(r'\bmkfs(\.|\b)', caseSensitive: false),
  ),
  CriticalBashPattern.regex(
    'dd to a device',
    RegExp(r'\bdd\s+if=.+of=/dev/', caseSensitive: false),
  ),
  CriticalBashPattern.regex(
    'shred a device',
    RegExp(r'\bshred\s+/dev/', caseSensitive: false),
  ),

  // System-config destruction.
  CriticalBashPattern.regex(
    'overwrite of a system account file',
    RegExp(r'>\s*/etc/(passwd|shadow|sudoers)\b', caseSensitive: false),
  ),
  CriticalBashPattern.regex(
    'tee into a system account file',
    RegExp(
      r'\btee\s+(-a\s+)?/etc/(passwd|shadow|sudoers)\b',
      caseSensitive: false,
    ),
  ),

  // Remote-fetch-then-execute (curl/wget piped to a shell, process-subbed,
  // or evaled).
  CriticalBashPattern.regex(
    'remote fetch piped to a shell',
    // Require curl/wget and the pipe to live in the same shell command so an
    // unrelated `curl` mention (e.g. inside a commit message or a prior `&&`
    // clause) does not false-positive against a later `| bash`.
    RegExp(
      r'\b(curl|wget)\b[^|&;\n]*\|\s*(bash|sh|zsh|fish)\b',
      caseSensitive: false,
    ),
  ),
  CriticalBashPattern.regex(
    'remote fetch via process substitution',
    // `bash <(curl …)`, `source <(curl …)`, `. <(curl …)`; `.`/`source` are
    // anchored to a command boundary so `find . -name` doesn't match.
    RegExp(
      r'(^|[\s;&|(])(bash|sh|zsh|source|\.)\s+<\(\s*(curl|wget)\b',
      caseSensitive: false,
    ),
  ),
  CriticalBashPattern.regex(
    'remote fetch via eval',
    // `eval "$(curl …)"` / `eval $(curl …)`
    RegExp(r'\beval\s+"?\$\(\s*(curl|wget)\b', caseSensitive: false),
  ),
  CriticalBashPattern.regex(
    'remote fetch via eval backticks',
    RegExp(r'\beval\s+`\s*(curl|wget)\b', caseSensitive: false),
  ),

  // Process/host control. The power commands must sit at command position so
  // `npm run reboot-tests` or `echo 'shutdown the queue'` don't match.
  CriticalBashPattern.regex('kill PID 1', RegExp(r'\bkill\s+-9\s+1\b')),
  CriticalBashPattern.regex(
    'host shutdown/reboot',
    RegExp(
      r'(^|[\s;&|(])(shutdown|poweroff|reboot|halt)([\s;|&]|$)',
      caseSensitive: false,
    ),
  ),

  // Force-pushed git history (prompt, not block).
  CriticalBashPattern.regex(
    'git push --force',
    RegExp(r'\bgit\s+push\b[^|;]*\s(--force|-f)\b', caseSensitive: false),
  ),
];

/// Launchers that may precede a command without being it (issue #460 E4).
/// `timeout`-style launchers that consume an argument are not stripped.
const _commandLaunchers = {'sudo', 'nohup', 'nice', 'env', 'command', 'time'};

/// Whether [command] invokes [commandName] (`rm`, `chmod`, `chown`) with
/// BOTH an explicit recursive flag (`-r`, `-R`, a short cluster containing
/// `r`/`R`, or `--recursive`) AND a root-like target.
///
/// The command is looked up per simple-command segment (split on shell
/// operators), after stripping launchers and `FOO=bar` assignments — so
/// `cd /tmp && rm -rf /` matches while `git commit -m "rm -rf /"` and
/// `rm -f /tmp/a; ls /` do not.
///
/// ponytail: whitespace tokenizer with quote/`--` awareness, not a full
/// shell grammar — a quoted string containing operator chars would need a
/// real parser; upgrade if that shape ever false-positives.
bool _recursiveRootInvocation(String command, String commandName) {
  for (final segment in command.split(RegExp(r'\n|&&|\|\||[;|&()]'))) {
    final args = _invocationArgs(segment, commandName);
    if (args == null) continue;
    final (flags, targets) = args;
    if (flags.any(_isRecursiveFlag) && targets.any(_isRootLikePath)) {
      return true;
    }
  }
  return false;
}

/// The [commandName] invocation's `(flags, targets)` in one simple-command
/// [segment], or `null` when the segment does not invoke it (launchers and
/// `FOO=bar` assignments are skipped).
(List<String>, List<String>)? _invocationArgs(
  String segment,
  String commandName,
) {
  final words = [
    for (final word in segment.split(RegExp(r'\s+')))
      if (word.isNotEmpty) _unquote(word),
  ];
  var start = 0;
  while (start < words.length && _isLauncherOrAssignment(words[start])) {
    start++;
  }
  if (start >= words.length || words[start].toLowerCase() != commandName) {
    return null;
  }
  return _splitFlagsAndTargets(words.skip(start + 1));
}

/// Whether [word] launches a command (`sudo`, …) or assigns an env var
/// (`FOO=bar`) instead of being one.
bool _isLauncherOrAssignment(String word) =>
    _commandLaunchers.contains(word.toLowerCase()) ||
    RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(word);

/// Partitions command words after the command name into short/long flags
/// and targets; `--` makes every remaining word a target.
(List<String>, List<String>) _splitFlagsAndTargets(Iterable<String> words) {
  final flags = <String>[];
  final targets = <String>[];
  var targetsOnly = false;
  for (final word in words) {
    if (!targetsOnly && word == '--') {
      targetsOnly = true;
    } else if (!targetsOnly && word.length > 1 && word.startsWith('-')) {
      flags.add(word);
    } else {
      targets.add(word);
    }
  }
  return (flags, targets);
}

/// `-f`, `-i`, `-v` never satisfy recursion; `-rf`/`-R` clusters do (E1).
bool _isRecursiveFlag(String flag) {
  if (flag.toLowerCase() == '--recursive') return true;
  if (flag.startsWith('--')) return false;
  return flag.contains('r') || flag.contains('R');
}

/// Strips one layer of matching surrounding quotes so `rm "-rf" "/"` still
/// parses.
String _unquote(String word) {
  if (word.length >= 2 &&
      ((word.startsWith("'") && word.endsWith("'")) ||
          (word.startsWith('"') && word.endsWith('"')))) {
    return word.substring(1, word.length - 1);
  }
  return word;
}

/// Root-like deletion targets only — see [_recursiveRootInvocation].
bool _isRootLikePath(String target) {
  if (_isHomeRoot(target)) return true;
  if (RegExp(r'^[A-Za-z]:[\\/]?[*]?$').hasMatch(target)) return true;
  return _isRootAbsolute(_stripTrailingSlashes(target));
}

/// `~`, `~/`, `~/*`, `$HOME`, `${HOME}` and their `/` and `/*` suffixes.
bool _isHomeRoot(String target) {
  const home = {r'$HOME', r'${HOME}'};
  const homeChildren = {r'$HOME/', r'$HOME/*', r'${HOME}/', r'${HOME}/*'};
  if (target == '~' || target == '~/' || target == '~/*') return true;
  return home.contains(target) || homeChildren.contains(target);
}

String _stripTrailingSlashes(String path) {
  var stripped = path;
  while (stripped.length > 1 && stripped.endsWith('/')) {
    stripped = stripped.substring(0, stripped.length - 1);
  }
  return stripped;
}

/// Root-likeness of a trailing-slash-free [path] (see
/// [_recursiveRootInvocation]).
bool _isRootAbsolute(String path) {
  if (!path.startsWith('/')) return false; // relative: cwd unknown → not root
  final rest = path.substring(1);
  if (rest.isEmpty) return true; // `/` itself
  if (rest.contains('/')) return false; // nested absolute (`/tmp/x`)
  if (rest.contains(r'$')) return false; // unresolved variable (`/$VAR`, E2)
  return true; // `/*`-style root glob or top-level component (`/usr`)
}

/// Returns the label of the first [criticalBashPatterns] entry matching
/// [command], or `null` when the command matches nothing critical.
String? matchCriticalBashCommand(String command) {
  final normalized = command.trim();
  if (normalized.isEmpty) return null;
  for (final entry in criticalBashPatterns) {
    if (entry.matches(normalized)) return entry.label;
  }
  return null;
}
