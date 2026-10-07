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
/// the SAME `<iso8601> <message>` shape, and — like every CLI lifecycle
/// line — carry `sid=<tag>` so interleaved host/CLI processes in the
/// shared log stay attributable: pass the host's own correlation id as
/// [tag] (`FileAgentTelemetrySink.forHomeDir(home, tag: 'yoclip-$runId')`).
///
/// `record` performs SYNCHRONOUS appends (create-dir once + writeAsString).
/// Record rate is low (phase transitions + heartbeats), but a UI-sensitive
/// host that cannot tolerate a rare frame hitch should wrap the sink in
/// its own queue/isolate — the interface is one method by design.
library;

import 'dart:io';

import 'agent_telemetry.dart'
    show AgentTelemetryEvent, AgentTelemetryEventKind, AgentTelemetrySink;

/// Appends one fa.log line per telemetry record. Never throws — a broken
/// log path degrades to silence exactly like the CLI's own diagnostic
/// writer.
final class FileAgentTelemetrySink implements AgentTelemetrySink {
  /// Creates a sink appending to [path] (the CLI's is `~/.fah/logs/fa.log`).
  /// [tag] is the correlation id rendered as `sid=<tag>` on every line —
  /// the CLI's own lines always name their session for shared-log
  /// post-mortems; `-` (the CLI's no-session marker) when the host has none.
  FileAgentTelemetrySink(this.path, {this.tag = '-'});

  /// The canonical fa.log sink for [homeDir], or null when the host has no
  /// home dir (web build, sandbox) — mirror of the CLI's own null path
  /// stance.
  static FileAgentTelemetrySink? forHomeDir(
    String? homeDir, {
    String tag = '-',
  }) {
    if (homeDir == null || homeDir.isEmpty) return null;
    return FileAgentTelemetrySink('$homeDir/.fah/logs/fa.log', tag: tag);
  }

  /// The log file path.
  final String path;

  /// The correlation id rendered as `sid=<tag>` (the CLI's `_logSid`
  /// convention; `-` when the host runs session-less).
  final String tag;

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
  /// (`run start sid=…` / `tool start sid=… name=…` / `turn end sid=…
  /// stop=…` / …), extended with the in-process records the CLI cannot
  /// have (`request start`, `first token`) and durations/status on the
  /// terminal lines. [detail]-less events render without a trailing
  /// segment (never a dangling separator).
  String _message(AgentTelemetryEvent event) {
    final tail = _tail(event) ?? '';
    final head = switch (event.kind) {
      AgentTelemetryEventKind.runStart => 'run start',
      AgentTelemetryEventKind.turnStart => 'turn start',
      AgentTelemetryEventKind.requestStart => 'request start',
      AgentTelemetryEventKind.firstToken => 'first token',
      AgentTelemetryEventKind.toolStart => 'tool start',
      AgentTelemetryEventKind.toolEnd => 'tool end',
      AgentTelemetryEventKind.toolHeartbeat => 'tool heartbeat',
      AgentTelemetryEventKind.toolStuck => 'tool stuck',
      AgentTelemetryEventKind.turnEnd => 'turn end',
      AgentTelemetryEventKind.error => 'run error',
      AgentTelemetryEventKind.runEnd => 'run end',
    };
    return tail.isEmpty ? '$head sid=$tag' : '$head sid=$tag $tail';
  }

  /// The per-kind fields after `sid=`, null-guarded so a record missing
  /// its optional detail never renders a dangling separator or a literal
  /// `null`.
  String? _tail(AgentTelemetryEvent event) {
    final name = event.toolName;
    final detail = event.detail;
    final parts = switch (event.kind) {
      AgentTelemetryEventKind.runStart => const <String>[],
      AgentTelemetryEventKind.turnStart => const <String>[],
      AgentTelemetryEventKind.requestStart => [?detail],
      AgentTelemetryEventKind.firstToken => [?detail],
      AgentTelemetryEventKind.toolStart => [if (name != null) 'name=$name'],
      AgentTelemetryEventKind.toolEnd => [
        if (name != null) 'name=$name',
        'error=${event.isError}',
      ],
      AgentTelemetryEventKind.toolHeartbeat => [
        if (name != null) 'name=$name',
        ?detail,
        if (event.outputBytes != null) 'out=${event.outputBytes}B',
        if (event.attempt != null) 'attempt=${event.attempt}',
      ],
      AgentTelemetryEventKind.toolStuck => [
        if (name != null) 'name=$name',
        ?detail,
      ],
      AgentTelemetryEventKind.turnEnd => [
        'stop=${event.stopReason}',
        'elapsed=${event.sinceRunStart.inSeconds}s',
      ],
      AgentTelemetryEventKind.error => [
        'elapsed=${event.sinceRunStart.inSeconds}s',
        if (event.httpStatus != null) 'http=${event.httpStatus}',
        ?detail,
      ],
      AgentTelemetryEventKind.runEnd => [
        'elapsed=${event.sinceRunStart.inSeconds}s',
      ],
    };
    return parts.isEmpty ? null : parts.join(' ');
  }
}
