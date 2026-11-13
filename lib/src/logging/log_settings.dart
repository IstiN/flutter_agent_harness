/// Log settings: the parsed `logging:` config section, the five-source
/// precedence resolution, and the per-sink gating (issue #2117).
///
/// Precedence for the CONSOLE level: `--log-level` flag > `FA_LOG_LEVEL`
/// env > project `.fah/config.yaml` `logging:` > `~/.fah/config.yaml`
/// `logging:` > default (`warn`, interactive). Headless stdout is PINNED
/// byte-identical: the level filter governs the interactive console
/// only; headless opts into filtering solely via the flag or the env —
/// a config-only level never filters machine-consumed output.
///
/// Pure Dart: no `dart:io`.
library;

import '../exceptions.dart';
import 'log_level.dart';
import 'log_pattern.dart';

export 'log_level.dart' show LogCategory, LogLevel;
export 'log_pattern.dart'
    show LogEvent, LogPattern, defaultLogTimeFormat, formatLogTime;

/// The parsed `logging:` section of a config file (strict like every
/// section — see `parseLoggingSection` in `cli_config.dart`).
final class LoggingConfig {
  /// Creates a logging section value; null fields mean "not set" and
  /// fall through the precedence chain.
  const LoggingConfig({this.console, this.file, this.format, this.timeFormat});

  /// `logging.console` — the interactive console level.
  final LogLevel? console;

  /// `logging.file` — the fa.log level.
  final LogLevel? file;

  /// `logging.format` — the line pattern for both sinks; absent keeps
  /// the current shapes (file: ISO + level tag; console: raw message).
  final String? format;

  /// `logging.timeFormat` — the `{time}` rendering.
  final String? timeFormat;

  /// Emits the section for `saveCliConfig` round-trips; '' when nothing
  /// is set (defaults are never written — the file stays minimal).
  String toYaml() {
    final buffer = StringBuffer()
      ..write(console == null ? '' : '  console: ${console!.name}\n')
      ..write(file == null ? '' : '  file: ${file!.name}\n')
      ..write(format == null ? '' : "  format: '$format'\n")
      ..write(timeFormat == null ? '' : "  timeFormat: '$timeFormat'\n");
    return buffer.isEmpty ? '' : 'logging:\n$buffer';
  }
}

/// The fully resolved log settings an [AgentCli]-class host runs with.
final class ResolvedLogSettings {
  /// Creates resolved settings; the defaults are the GOAL's pinned
  /// interactive contract — console `warn`, file `debug`, no pattern.
  const ResolvedLogSettings({
    this.consoleLevel = LogLevel.warn,
    this.consoleExplicit = false,
    this.fileLevel = LogLevel.debug,
    this.format,
    this.timeFormat = defaultLogTimeFormat,
    this.keysFloor = false,
  });

  /// The interactive console level.
  final LogLevel consoleLevel;

  /// Whether the console level came from `--log-level`/`FA_LOG_LEVEL`.
  /// Headless runs filter ONLY when this is true (the pinned contract).
  final bool consoleExplicit;

  /// The fa.log level.
  final LogLevel fileLevel;

  /// The configured line pattern for both sinks; null keeps the
  /// current shapes.
  final LogPattern? format;

  /// The `{time}` rendering.
  final String timeFormat;

  /// `--debug-secrets`/`FA_DEBUG_KEYS` as `keys=debug`: keys-category
  /// lines get a `debug` floor on the console sink so the key
  /// diagnostics survive a `warn`-or-quieter dial (never an explicit
  /// `off` — off stays off).
  final bool keysFloor;

  /// Whether a console line at [level]/[category] renders.
  bool consolePasses(LogLevel level, LogCategory category) =>
      _passes(consoleLevel, level, category, applyKeysFloor: true);

  /// Whether a fa.log line at [level]/[category] is written.
  bool filePasses(LogLevel level, LogCategory category) =>
      _passes(fileLevel, level, category, applyKeysFloor: false);
}

bool _passes(
  LogLevel threshold,
  LogLevel line,
  LogCategory category, {
  required bool applyKeysFloor,
}) {
  if (threshold == LogLevel.off) return false;
  if (applyKeysFloor &&
      category == LogCategory.keys &&
      threshold.index < LogLevel.debug.index) {
    threshold = LogLevel.debug;
  }
  return line.index <= threshold.index;
}

/// Resolves the settings from the five sources. [flagLevel] is the
/// already-parsed `--log-level` value (a bad flag string is a usage
/// error in `cli_args.dart`); [envLevel] is the raw `FA_LOG_LEVEL`
/// value (parsed here — invalid input throws [ConfigException]).
ResolvedLogSettings resolveLogSettings({
  LogLevel? flagLevel,
  String? envLevel,
  LoggingConfig? project,
  LoggingConfig? user,
  bool debugKeys = false,
}) {
  final LogLevel? fromEnv;
  if (envLevel == null || envLevel.trim().isEmpty) {
    fromEnv = null;
  } else {
    fromEnv = LogLevel.parse(envLevel, label: 'FA_LOG_LEVEL');
  }
  final format = project?.format ?? user?.format;
  return ResolvedLogSettings(
    consoleLevel:
        flagLevel ??
        fromEnv ??
        project?.console ??
        user?.console ??
        LogLevel.warn,
    consoleExplicit: flagLevel != null || fromEnv != null,
    fileLevel: project?.file ?? user?.file ?? LogLevel.debug,
    format: format == null ? null : LogPattern(format),
    timeFormat: project?.timeFormat ?? user?.timeFormat ?? defaultLogTimeFormat,
    keysFloor: debugKeys,
  );
}
