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

/// A destructive shell pattern with a human-readable label, surfaced in the
/// approval prompt's reason.
final class CriticalBashPattern {
  const CriticalBashPattern(this.label, this.pattern);

  /// Short description of the matched danger (e.g. `recursive delete`).
  final String label;

  /// The pattern tested against the raw command string.
  final RegExp pattern;
}

/// Patterns that force an approval prompt for any matching `bash` command.
///
/// Keep the list tight: add shapes that are virtually never legitimate in
/// automation. A prompt (not a block) is the response — the user decides.
final criticalBashPatterns = <CriticalBashPattern>[
  // Recursive destruction. Absolute-path targets are flagged even below /
  // (e.g. `rm -rf /tmp/x`): a false positive there is cheaper than a missed
  // `rm -rf /`.
  CriticalBashPattern(
    'recursive delete from a root path',
    // rm -rf /, rm -fr /, rm -r /, rm -f /…
    RegExp(r'\brm\s+-[a-z]*[rf][a-z]*\s+/', caseSensitive: false),
  ),
  CriticalBashPattern(
    'sudo rm',
    RegExp(r'\bsudo\s+rm\b', caseSensitive: false),
  ),
  CriticalBashPattern(
    'recursive chmod from a root path',
    // chmod -R 777 /
    RegExp(r'\bchmod\s+-R\s+[0-7]+\s+/', caseSensitive: false),
  ),
  CriticalBashPattern(
    'recursive chmod (symbolic) from a root path',
    // chmod -R u+x /, chmod -R u+rwx,o+w /etc
    RegExp(r'\bchmod\s+-R\s+[ugoa+\-=rwxXst,]+\s+/'),
  ),
  CriticalBashPattern(
    'recursive chown from a root path',
    RegExp(r'\bchown\s+-R\s+\S+\s+/', caseSensitive: false),
  ),

  // Fork bomb (a few common spacings): `:(){ :|:& };:`.
  CriticalBashPattern('fork bomb', RegExp(r':\(\)\s*\{\s*:\s*\|\s*:')),

  // Disk / filesystem destruction.
  CriticalBashPattern(
    'write to a disk device',
    RegExp(r'>\s*/dev/sd[a-z]', caseSensitive: false),
  ),
  CriticalBashPattern(
    'format filesystem',
    RegExp(r'\bmkfs(\.|\b)', caseSensitive: false),
  ),
  CriticalBashPattern(
    'dd to a device',
    RegExp(r'\bdd\s+if=.+of=/dev/', caseSensitive: false),
  ),
  CriticalBashPattern(
    'shred a device',
    RegExp(r'\bshred\s+/dev/', caseSensitive: false),
  ),

  // System-config destruction.
  CriticalBashPattern(
    'overwrite of a system account file',
    RegExp(r'>\s*/etc/(passwd|shadow|sudoers)\b', caseSensitive: false),
  ),
  CriticalBashPattern(
    'tee into a system account file',
    RegExp(
      r'\btee\s+(-a\s+)?/etc/(passwd|shadow|sudoers)\b',
      caseSensitive: false,
    ),
  ),

  // Remote-fetch-then-execute (curl/wget piped to a shell, process-subbed,
  // or evaled).
  CriticalBashPattern(
    'remote fetch piped to a shell',
    RegExp(
      r'\b(curl|wget)\b[^|]*\|\s*(bash|sh|zsh|fish)\b',
      caseSensitive: false,
    ),
  ),
  CriticalBashPattern(
    'remote fetch via process substitution',
    // `bash <(curl …)`, `source <(curl …)`, `. <(curl …)`; `.`/`source` are
    // anchored to a command boundary so `find . -name` doesn't match.
    RegExp(
      r'(^|[\s;&|(])(bash|sh|zsh|source|\.)\s+<\(\s*(curl|wget)\b',
      caseSensitive: false,
    ),
  ),
  CriticalBashPattern(
    'remote fetch via eval',
    // `eval "$(curl …)"` / `eval $(curl …)`
    RegExp(r'\beval\s+"?\$\(\s*(curl|wget)\b', caseSensitive: false),
  ),
  CriticalBashPattern(
    'remote fetch via eval backticks',
    RegExp(r'\beval\s+`\s*(curl|wget)\b', caseSensitive: false),
  ),

  // Process/host control. The power commands must sit at command position so
  // `npm run reboot-tests` or `echo 'shutdown the queue'` don't match.
  CriticalBashPattern('kill PID 1', RegExp(r'\bkill\s+-9\s+1\b')),
  CriticalBashPattern(
    'host shutdown/reboot',
    RegExp(
      r'(^|[\s;&|(])(shutdown|poweroff|reboot|halt)([\s;|&]|$)',
      caseSensitive: false,
    ),
  ),

  // Force-pushed git history (prompt, not block).
  CriticalBashPattern(
    'git push --force',
    RegExp(r'\bgit\s+push\b[^|;]*\s(--force|-f)\b', caseSensitive: false),
  ),
];

/// Returns the label of the first [criticalBashPatterns] entry matching
/// [command], or `null` when the command matches nothing critical.
String? matchCriticalBashCommand(String command) {
  final normalized = command.trim();
  if (normalized.isEmpty) return null;
  for (final entry in criticalBashPatterns) {
    if (entry.pattern.hasMatch(normalized)) return entry.label;
  }
  return null;
}
