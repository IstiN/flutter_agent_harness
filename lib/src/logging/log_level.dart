/// Log severity levels and categories (issue #2117).
///
/// Pure Dart: no `dart:io`, no Flutter — the same vocabulary serves the
/// CLI console sink, the fa.log file sink, and any other embedder.
library;

import '../exceptions.dart';

/// The severity dial: `off < error < warn < info < debug < trace`.
///
/// A sink at level L passes every line whose level is at or under L
/// (ordinal comparison); `off` passes nothing. The filter governs the
/// INTERACTIVE console only — the headless stdout contract (HEP,
/// stream-json, wire-serve, plain runs) is pinned byte-identical and
/// never routes through the console sink filter unless the user passes
/// `--log-level`/`FA_LOG_LEVEL` explicitly.
enum LogLevel {
  off,
  error,
  warn,
  info,
  debug,
  trace;

  /// Parses one level keyword (case-insensitive, trimmed). Invalid input
  /// is LOUD — a [ConfigException] naming [label] — never a silent
  /// fallthrough to a permissive default (issue #2117 border case).
  static LogLevel parse(String raw, {required String label}) {
    for (final level in LogLevel.values) {
      if (level.name == raw.trim().toLowerCase()) return level;
    }
    throw ConfigException(
      '$label must be one of off, error, warn, info, debug, trace, '
      'got: "$raw"',
    );
  }
}

/// The category tags every log call declares (issue #2117 scope 3). The
/// default for migrated `_logDiagnostic` call sites is [lifecycle];
/// `keys` participates in the `--debug-secrets`/`FA_DEBUG_KEYS` alias —
/// a category floor at `debug` resolved into the settings.
enum LogCategory { keys, lifecycle, tool, provider, compaction, messaging }
