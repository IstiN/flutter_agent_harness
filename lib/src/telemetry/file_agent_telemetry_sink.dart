/// The `fa.log`-backed telemetry sink for in-process hosts (issue #1322
/// Gap 3).
///
/// `dart:io` lives here (exported only from `lib/io.dart`) so the agent
/// core stays pure Dart: the sink INTERFACE and the in-memory default are
/// in `lib/src/telemetry/agent_telemetry.dart`; 'when available' is this
/// file — a platform host imports `package:flutter_agent_harness/io.dart`,
/// constructs the sink over its home dir, and hands it to
/// `AgentCoreServices(telemetry: …)` (one line; AC3).
///
/// Lines land in the SAME file the CLI writes (`~/.fah/logs/fa.log`) in
/// the SAME `<iso8601> <message>` shape, so a host embed and a CLI session
/// are post-mortem-identical: grep one log for either.
library;

import 'dart:io';

import 'agent_telemetry.dart'
    show AgentTelemetryEvent, AgentTelemetryEventKind, AgentTelemetrySink;

/// Appends one fa.log line per telemetry record. Never throws — a broken
/// log path degrades to silence exactly like the CLI's own diagnostic
/// writer.
final class FileAgentTelemetrySink implements AgentTelemetrySink {
  /// Creates a sink appending to [path] (the CLI's is `~/.fah/logs/fa.log`).
  FileAgentTelemetrySink(this.path);

  /// The canonical fa.log sink for [homeDir], or null when the host has no
  /// home dir (web build, sandbox) — mirror of the CLI's own null path
  /// stance.
  static FileAgentTelemetrySink? forHomeDir(String? homeDir) {
    if (homeDir == null || homeDir.isEmpty) return null;
    return FileAgentTelemetrySink('$homeDir/.fah/logs/fa.log');
  }

  /// The log file path.
  final String path;

  var _dirEnsured = false;

  @override
  void record(AgentTelemetryEvent event) {
    final line = '${DateTime.now().toIso8601String()} ${_message(event)}\n';
    try {
      if (!_dirEnsured) {
        _dirEnsured = true;
        File(path).parent.createSync(recursive: true);
      }
      File(path).writeAsStringSync(line, mode: FileMode.append);
    } catch (_) {
      // Diagnostics must never break the host.
    }
  }

  /// The message half of the line — the CLI's phase vocabulary
  /// (`run start` / `tool start name=…` / `turn end stop=…` / …), extended
  /// with the in-process records the CLI cannot have (`request start`,
  /// `first token`) and durations/status on the terminal lines.
  static String _message(AgentTelemetryEvent event) {
    final name = event.toolName;
    return switch (event.kind) {
      AgentTelemetryEventKind.runStart => 'run start',
      AgentTelemetryEventKind.turnStart => 'turn start',
      AgentTelemetryEventKind.requestStart => 'request start ${event.detail}',
      AgentTelemetryEventKind.firstToken => 'first token ${event.detail ?? ''}',
      AgentTelemetryEventKind.toolStart => 'tool start name=$name',
      AgentTelemetryEventKind.toolEnd =>
        'tool end name=$name error=${event.isError}',
      AgentTelemetryEventKind.toolHeartbeat =>
        'tool heartbeat name=$name ${event.detail}',
      AgentTelemetryEventKind.toolStuck =>
        'tool stuck name=$name ${event.detail}',
      AgentTelemetryEventKind.turnEnd =>
        'turn end stop=${event.stopReason} '
            'elapsed=${event.sinceRunStart.inSeconds}s',
      AgentTelemetryEventKind.error =>
        'run error elapsed=${event.sinceRunStart.inSeconds}s'
            '${_status(event)}: ${event.detail}',
      AgentTelemetryEventKind.runEnd =>
        'run end elapsed=${event.sinceRunStart.inSeconds}s'
            '${_status(event)}',
    };
  }

  static String _status(AgentTelemetryEvent event) =>
      event.httpStatus == null ? '' : ' http=${event.httpStatus}';
}
