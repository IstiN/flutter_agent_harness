/// The console-log members of [AgentCli] (issue #2117): the console sink
/// gate (`_consolePasses`), the gated console emit (`_logConsole`), and
/// the `/log` slash command.
///
/// Split out of `agent_cli.dart` to keep that file under the repo's
/// 2800-line size gate. Same library (a `part of`), so the extension
/// sees the class's private members.
part of 'agent_cli.dart';

/// Console-log members of [AgentCli].
extension AgentCliLogging on AgentCli {
  /// Whether a console line at [level]/[category] renders right now.
  ///
  /// - Interactive: the live `/log` override, else the resolved console
  ///   level, decides (default `warn`).
  /// - Headless: UNFILTERED unless the user made the level explicit
  ///   (`--log-level`/`FA_LOG_LEVEL`, or a live `/log`) — the pinned
  ///   contract that keeps HEP/stream-json/wire-serve/plain-run stdout
  ///   byte-identical at defaults.
  bool _consolePasses(LogLevel level, LogCategory category) {
    final settings = config.logging;
    final live = _liveConsoleLevel;
    if (_headlessMode && !settings.consoleExplicit && live == null) {
      return true;
    }
    return logLinePasses(
      live ?? settings.consoleLevel,
      level,
      category,
      keysFloor: settings.keysFloor,
    );
  }

  /// Emits one gated console log line (issue #2117): redaction ALWAYS
  /// applies (every rendered line, every sink), a configured
  /// `logging.format` decorates the line, the message shape stays the
  /// raw one otherwise (byte-stable with today's dim notes), and the
  /// write rides `io.writeln` — the one output arbiter (#2069/#2094).
  void _logConsole(LogLevel level, LogCategory category, String message) {
    if (!_consolePasses(level, category)) return;
    final settings = config.logging;
    final safe = config.redactionPipeline?.redact(message) ?? message;
    final rendered = settings.format == null
        ? safe
        : settings.format!.render(
            LogEvent(
              time: DateTime.now(),
              elapsed: DateTime.now().difference(_loggingBoot),
              sid: _logSid,
              level: level,
              category: category,
              message: safe,
            ),
            timeFormat: settings.timeFormat,
          );
    io.writeln(_style.dim(rendered));
  }

  /// Test seam: emit one console log line exactly as production callers
  /// do (the sink's gate/redact/format path, issue #2117 AC3).
  @visibleForTesting
  void logConsoleForTest(LogLevel level, LogCategory category, String message) {
    _logConsole(level, category, message);
  }

  /// `/log [level]` (issue #2117 AC4): the live console dial. Bare
  /// `/log` prints the current level; a valid level switches the console
  /// sink immediately (subsequent lines); an invalid one answers with
  /// the same loud vocabulary error the flag and env use — never a
  /// silent fallthrough.
  void _handleLogCommand(String rest) {
    final current = _liveConsoleLevel ?? config.logging.consoleLevel;
    final arg = rest.trim();
    if (arg.isEmpty) {
      io.writeln(
        'log: console level ${current.name} '
        '(off|error|warn|info|debug|trace — live, no restart)',
      );
      return;
    }
    try {
      final level = LogLevel.parse(arg, label: '/log');
      _liveConsoleLevel = level;
      io.writeln('log: console level ${level.name} (was ${current.name})');
    } on ConfigException catch (error) {
      io.writeln(error.message);
    }
  }
}
