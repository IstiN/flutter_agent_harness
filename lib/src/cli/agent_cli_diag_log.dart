/// The diagnostic-log members of [AgentCli]: the fa.log writer
/// (`_logDiagnostic`/`_appendDiagnosticLog`), the short session id for log
/// lines (`_logSid`) and the log path resolver (`_diagnosticLogPath`).
/// Split out of `agent_cli.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension sees
/// the class's private members; the `_diagnosticLogDirEnsured` field stays
/// on the class — extensions hold no fields.
part of 'agent_cli.dart';

/// Diagnostic-log members of [AgentCli].
extension AgentCliDiagLog on AgentCli {
  /// Writes a diagnostic line to the log file (`~/.fah/logs/fa.log`).
  /// TUI/stderr stay clean — the AutoCompactor hook streams progress to
  /// the user, the log captures everything for post-mortem.
  void _logDiagnostic(String message) {
    final path = _diagnosticLogPath;
    if (path == null) return;
    unawaited(_appendDiagnosticLog(path, message));
  }

  /// Short session id for diagnostic log lines: parallel fa processes share
  /// one fa.log, so every lifecycle line names its session (post-mortem
  /// "who held the busy row" starts here).
  String get _logSid {
    final id = _session?.cachedId;
    if (id == null || id.isEmpty) return '-';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  /// Appends one timestamped [message] to [path], creating the log directory
  /// on first use. Isolated from [_logDiagnostic] so the public entry point
  /// stays small.
  Future<void> _appendDiagnosticLog(String path, String message) async {
    final line = '${DateTime.now().toIso8601String()} $message\n';
    try {
      if (!_diagnosticLogDirEnsured) {
        _diagnosticLogDirEnsured = true;
        await _env.createDir('${config.homeDir}/.fah/logs', recursive: true);
      }
      await _env.appendFile(path, line);
    } catch (_) {
      // Diagnostics must never break the CLI.
    }
  }

  /// Path of the diagnostic log file under `~/.fah/logs/fa.log`. Null
  /// when the host has no `homeDir` (web build, sandbox).
  String? get _diagnosticLogPath {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return null;
    return '$home/.fah/logs/fa.log';
  }
}
