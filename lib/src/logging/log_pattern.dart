/// Log line patterns (issue #2117 scope 4): the `{time} {elapsed} {sid}
/// {level} {cat} {msg}` placeholders, the time rendering, and the one
/// event value carried through a render.
///
/// Pure Dart. A sink WITHOUT a configured pattern keeps its current
/// shape (the file sink prefixes the ISO timestamp and the level tag;
/// the console sink prints the raw message) — the pattern applies only
/// when `logging.format` is configured.
library;

import 'log_level.dart';

/// The default `logging.timeFormat` (issue #2117 scope 4).
const String defaultLogTimeFormat = 'HH:mm:ss.SSS';

/// One log event rendered through a [LogPattern].
final class LogEvent {
  /// Creates a log event.
  const LogEvent({
    required this.time,
    required this.elapsed,
    required this.sid,
    required this.level,
    required this.category,
    required this.message,
  });

  /// Wall-clock time of the line.
  final DateTime time;

  /// Time since the process (logger) booted.
  final Duration elapsed;

  /// The short session id (fa.log's `_logSid` convention).
  final String sid;

  /// Line severity.
  final LogLevel level;

  /// Line category tag.
  final LogCategory category;

  /// The (already redacted) message text.
  final String message;
}

/// Renders wall-clock time per [pattern]. Supported tokens: `HH`, `mm`,
/// `ss`, `SSS`; anything else passes through literally.
String formatLogTime(DateTime time, String pattern) => pattern
    .replaceAll('HH', time.hour.toString().padLeft(2, '0'))
    .replaceAll('mm', time.minute.toString().padLeft(2, '0'))
    .replaceAll('ss', time.second.toString().padLeft(2, '0'))
    .replaceAll('SSS', time.millisecond.toString().padLeft(3, '0'));

/// Renders [event.elapsed] for the `{elapsed}` placeholder: seconds with
/// millisecond precision (`12.345s`).
String formatLogElapsed(Duration elapsed) =>
    '${(elapsed.inMicroseconds / 1e6).toStringAsFixed(3)}s';

/// A configured `logging.format` line pattern. Unknown placeholders
/// (`{msgg}`) stay literal text; the known set is `{time} {elapsed}
/// {sid} {level} {cat} {msg}`.
final class LogPattern {
  /// Creates a pattern from the raw `logging.format` string.
  const LogPattern(this.template);

  /// The raw pattern template.
  final String template;

  static final RegExp _placeholder = RegExp(
    r'\{(time|elapsed|sid|level|cat|msg)\}',
  );

  /// Renders one line from [event]; [timeFormat] carries the settings'
  /// `logging.timeFormat` (default [defaultLogTimeFormat]).
  String render(LogEvent event, {String timeFormat = defaultLogTimeFormat}) =>
      template.replaceAllMapped(
        _placeholder,
        (match) => switch (match.group(1)!) {
          'time' => formatLogTime(event.time, timeFormat),
          'elapsed' => formatLogElapsed(event.elapsed),
          'sid' => event.sid,
          'level' => event.level.name,
          'cat' => event.category.name,
          _ => event.message,
        },
      );
}
