/// TermiosGuard (issue #735): keeps the TUI's raw-mode input flags
/// asserted for the whole session, not just at boot.
///
/// fa clears IXON/IXOFF/ICRNL/VDISCARD once when the TUI boots
/// (`FaTuiController.sttySanitizeInput`). But the `bash` tool runs
/// children that share the session's controlling terminal — anything
/// opening `/dev/tty` (pagers, ssh, python `termios` users, a curses app
/// restoring its saved termios on exit, `stty` itself) can silently
/// re-enable `ixon`. With IXON back on, Ctrl+S (0x13) becomes the tty
/// driver's VSTOP byte: output suspends, any key resumes it (IXANY), and
/// the byte never reaches fa — steering dies mid-session.
///
/// The guard re-asserts the flag family after every foreground tool
/// phase (composed onto `Agent.afterToolCall`, the same seam
/// `attachToolPhaseLabels` uses), reports the drift it cleared (one dim
/// transcript note — it names which flags a child re-enabled), and is
/// failure-tolerant by contract: no tty, missing `stty`, or a failed
/// probe is a silent no-op that never breaks the turn.
library;

import 'dart:io';

import 'package:meta/meta.dart';

import '../agent/agent.dart';

/// Runs `stty <args>` — injectable so tests model the tty without
/// spawning a real subprocess (same seam as
/// `FaTuiController.sttySanitizeInput`'s runner).
typedef SttyRunner = Future<ProcessResult> Function(List<String> args);

/// The input-flag family fa keeps cleared for the TUI's lifetime.
/// `-ixany` is belt-and-braces: with IXANY the kernel resumes stopped
/// output on ANY byte — the issue's "pressed ↑ and it let go" signature.
const kTermiosClearArgs = ['-ixon', '-ixoff', '-icrnl', '-discard', '-ixany'];

/// Toggle flags parsed from `stty -a` for drift detection. `discard` is
/// deliberately absent: in `stty -a` output it is a CONTROL CHARACTER
/// (`discard = ^O`, always printed bare), not an input-flag toggle —
/// matching it would report false drift on every probe.
const _driftToggles = {'ixon', 'ixoff', 'icrnl', 'ixany'};

/// One [TermiosGuard.reassert] pass.
final class TermiosReassert {
  const TermiosReassert({required this.checked, this.driftedFlags = const []});

  /// Whether a real probe ran. False = silent no-op (no tty, no `stty`
  /// on PATH, or the probe failed) — never an error.
  final bool checked;

  /// The flags a child had re-enabled and this pass cleared again,
  /// e.g. `['ixon', 'ixany']`. Empty when the tty was already clean.
  final List<String> driftedFlags;

  bool get clearedDrift => driftedFlags.isNotEmpty;
}

/// The BSD/GNU device flag for `stty` (`-f` on macOS, `-F` elsewhere).
String _deviceFlag() => Platform.isMacOS ? '-f' : '-F';

/// Re-asserts the raw-mode input flags on demand.
final class TermiosGuard {
  TermiosGuard({SttyRunner? runner, bool Function()? hasTerminal})
    : _runner = runner ?? _processStty,
      _hasTerminal = hasTerminal ?? _realHasTerminal;

  static Future<ProcessResult> _processStty(List<String> args) =>
      Process.run('stty', args);

  static bool _realHasTerminal() => !Platform.isWindows && stdin.hasTerminal;

  final SttyRunner _runner;
  final bool Function() _hasTerminal;

  /// Probes `stty -a`; when any drift toggle is back on, clears the whole
  /// [kTermiosClearArgs] family and reports what drifted. Never throws.
  Future<TermiosReassert> reassert() async {
    if (!_hasTerminal()) return const TermiosReassert(checked: false);
    try {
      final report = await _runner([_deviceFlag(), '/dev/tty', '-a']);
      if (report.exitCode != 0) {
        return const TermiosReassert(checked: false);
      }
      final drift = parseTermiosDrift(report.stdout as String);
      if (drift.isEmpty) return const TermiosReassert(checked: true);
      final cleared = await _runner([
        _deviceFlag(),
        '/dev/tty',
        ...kTermiosClearArgs,
      ]);
      if (cleared.exitCode != 0) {
        return const TermiosReassert(checked: false);
      }
      return TermiosReassert(checked: true, driftedFlags: drift);
    } on Object {
      // No stty on PATH, no /dev/tty, or the probe died mid-flight —
      // leave the tty untouched and never break the turn.
      return const TermiosReassert(checked: false);
    }
  }

  /// The live `stty -a` dump for the hidden `/termios` debug command.
  /// Null when there is no tty to inspect.
  Future<String?> dumpSettings() async {
    if (!_hasTerminal()) return null;
    try {
      final report = await _runner([_deviceFlag(), '/dev/tty', '-a']);
      if (report.exitCode != 0) return null;
      return (report.stdout as String).trim();
    } on Object {
      return null;
    }
  }
}

/// Extracts the drift toggles that are ON in `stty -a`-shaped output.
/// Both BSD and GNU stty print enabled flags bare and disabled ones as
/// `-flag`; control characters (`name = ^X`) never match [_driftToggles].
@visibleForTesting
List<String> parseTermiosDrift(String sttyA) {
  final drifted = <String>[];
  for (final token in sttyA.split(RegExp(r'[\s;]+'))) {
    if (_driftToggles.contains(token)) drifted.add(token);
  }
  return drifted;
}

/// Composes [guard] onto [agent]'s after-tool hook: every foreground
/// tool phase could have run a child that touched the shared tty, so the
/// boundary is where the flags are re-asserted. [onDrift] receives the
/// drifted flags for the observability note. Same wrap discipline as
/// `attachToolPhaseLabels`: a prior `afterToolCall` keeps running after
/// the guard, and guard failures are swallowed (the hook never throws).
void attachTermiosGuard(
  Agent agent,
  TermiosGuard guard, {
  void Function(List<String> drifted)? onDrift,
}) {
  final priorAfter = agent.afterToolCall;
  agent.afterToolCall = (context, cancelToken) async {
    try {
      final result = await guard.reassert();
      if (result.clearedDrift) onDrift?.call(result.driftedFlags);
    } on Object {
      // Belt-and-braces: reassert() already swallows, but the hook
      // contract is "never breaks the turn" — keep it unconditional.
    }
    return priorAfter?.call(context, cancelToken);
  };
}
