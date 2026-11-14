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
  ///
  /// Issue #2117: every call declares a [level] (default `info`) and a
  /// [category] (default `lifecycle`); the FILE sink gate applies before
  /// any work is queued, and the rendered line carries the level tag
  /// (fa.log keeps its shape and destination beyond the level tags).
  ///
  /// gh-2097: the append rides the serialized `_diagLogChain` — a burst
  /// of diagnostics lands complete and in order, never racing itself on
  /// the same file, and exit paths drain the chain so nothing is dropped
  /// (the old unawaited fire-and-forget lost rapid bursts at process
  /// exit).
  void _logDiagnostic(
    String message, {
    LogLevel level = LogLevel.info,
    LogCategory category = LogCategory.lifecycle,
  }) {
    final path = _diagnosticLogPath;
    if (path == null) return;
    if (!config.logging.filePasses(level, category)) return;
    _diagLogChain = _diagLogChain
        .then(
          (_) => _appendDiagnosticLog(
            path,
            message,
            level: level,
            category: category,
          ),
        )
        // The appender already swallows its own errors; this keeps the
        // chain alive regardless so one failure can never drop every
        // later line with it.
        .catchError((Object _) {});
  }

  /// gh-2097: drains the diagnostic-append chain — every exit path
  /// awaits this so the process cannot die with pending lines in the
  /// chain (the last thing the process does must never be a pending
  /// log write).
  Future<void> flushDiagnosticLog() => _diagLogChain;

  /// Test seam: emit one diagnostic line exactly as production callers
  /// do (gh-2097 burst/drop coverage; the level/category ride through
  /// for the #2117 sink tests).
  @visibleForTesting
  void logDiagnosticForTest(
    String message, {
    LogLevel level = LogLevel.info,
    LogCategory category = LogCategory.lifecycle,
  }) => _logDiagnostic(message, level: level, category: category);

  /// gh-2178: wires the quarantine report onto the CLI notice channel —
  /// the same line rides fa.log at warn level (the diagnostics file
  /// keeps the forensic copy; the reporter's per-record dedupe keeps a
  /// repeated turn from spamming either surface).
  void wireQuarantineNotice(void Function(String message) onNotice) {
    SessionQuarantine.onQuarantined = (line) {
      onNotice(line);
      _logDiagnostic(line, level: LogLevel.warn);
    };
  }

  /// Short session id for diagnostic log lines: parallel fa processes share
  /// one fa.log, so every lifecycle line names its session (post-mortem
  /// "who held the busy row" starts here).
  String get _logSid {
    final id = _session?.cachedId;
    if (id == null || id.isEmpty) return '-';
    return id.length <= 8 ? id : id.substring(0, 8);
  }

  /// Appends one rendered line to [path], creating the log directory on
  /// first use. Isolated from [_logDiagnostic] so the public entry point
  /// stays small.
  ///
  /// Issue #2117: the line is REDACTED (every rendered line, every sink)
  /// and carries the level tag after the timestamp — the default file
  /// shape is today's `ISO message` with ` level` inserted; a configured
  /// `logging.format` renders the pattern instead.
  Future<void> _appendDiagnosticLog(
    String path,
    String message, {
    required LogLevel level,
    required LogCategory category,
  }) async {
    final settings = config.logging;
    final safe = config.redactionPipeline?.redact(message) ?? message;
    final line = settings.format == null
        ? '${DateTime.now().toIso8601String()} ${level.name} $safe\n'
        : '${settings.format!.render(
            LogEvent(time: DateTime.now(), elapsed: DateTime.now().difference(_loggingBoot), sid: _logSid, level: level, category: category, message: safe),
            timeFormat: settings.timeFormat,
          )}\n';
    try {
      if (!_diagnosticLogDirEnsured) {
        _diagnosticLogDirEnsured = true;
        await _env.createDir('${config.homeDir}/.fah/logs', recursive: true);
        await _rotateDiagnosticLogIfOversized(path);
      }
      await _env.appendFile(path, line);
    } catch (_) {
      // Diagnostics must never break the CLI.
    }
  }

  /// Rotates [path] to `fa.log.1` when it exceeds
  /// [AgentCli.diagnosticLogMaxBytes]. Runs once per process (first log
  /// write), so parallel fa processes can race the rename — losing a few
  /// diagnostics lines is acceptable for a post-mortem file. The rename
  /// keeps the previous log available; a backend that reports rename as
  /// unsupported (CwdOverrideEnv forwards the capability only when the
  /// delegate has it) falls back to truncating in place.
  Future<void> _rotateDiagnosticLogIfOversized(String path) async {
    final info = await _env.fileInfo(path);
    final size = info.valueOrNull?.size ?? 0;
    if (size <= AgentCli.diagnosticLogMaxBytes) return;
    final renamed = await _env.renamePath(path, '$path.1');
    if (renamed.isOk) return;
    await _env.writeFile(path, '');
  }

  /// Path of the diagnostic log file under `~/.fah/logs/fa.log`. Null
  /// when the host has no `homeDir` (web build, sandbox).
  String? get _diagnosticLogPath {
    final home = config.homeDir;
    if (home == null || home.isEmpty) return null;
    return '$home/.fah/logs/fa.log';
  }
}
