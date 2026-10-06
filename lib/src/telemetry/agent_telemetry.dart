/// Lifecycle telemetry for in-process hosts (issue #1322 Gap 3).
///
/// The CLI writes every run/turn/tool/HTTP phase to `~/.fah/logs/fa.log`;
/// an embedded host previously got nothing — a hung LLM call showed
/// "thinking 181 s" in the host's UI with zero lines in any log. This
/// module is the SDK answer: a pure-Dart event record + sink interface on
/// [AgentCoreServices], an adapter that translates the agent's lifecycle
/// events (and the provider stream's first byte) into records, and an
/// in-memory ring as the pure-host default. The file sink that writes the
/// CLI's own `fa.log` format lives behind `lib/io.dart` — no `dart:io`
/// here (hard invariant; web compilation stays clean).
///
/// Pure Dart: no `dart:io`.
library;

import 'dart:async';

import '../agent/agent.dart';
import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../event_stream.dart';
import '../model.dart';
import '../providers/provider_common.dart'
    show ProviderHttpError, formatProviderError;
import '../types.dart';

/// The lifecycle phases a sink receives — the CLI's fa.log phase map
/// (`run start` / `turn start` / `tool start` / `tool end` / `turn end` /
/// `run end` plus heartbeats and stuck-call forensics) extended with the
/// two records an in-process host additionally needs: `firstToken` (the
/// provider answered — a hang after `requestStart` is inbound) and the
/// provider HTTP status on `error`/`runEnd`.
enum AgentTelemetryEventKind {
  runStart,
  turnStart,
  requestStart,
  firstToken,
  toolStart,
  toolEnd,
  toolHeartbeat,
  toolStuck,
  turnEnd,
  runEnd,
  error,
}

/// One lifecycle record. Pure data — [sink]s format it however their
/// backend wants (the io file sink writes fa.log lines, an in-memory ring
/// keeps the objects, a host UI renders them live).
final class AgentTelemetryEvent {
  /// The phase that produced the record.
  final AgentTelemetryEventKind kind;

  /// Wall-clock time of the record.
  final DateTime timestamp;

  /// Time since the current run started (zero for [AgentTelemetryEventKind.runStart]).
  final Duration sinceRunStart;

  /// The tool call id, for the tool_* kinds.
  final String? toolCallId;

  /// The tool name, for the tool_* kinds.
  final String? toolName;

  /// Whether the tool finished with an error result (toolEnd).
  final bool? isError;

  /// The assistant stop reason, for turnEnd (`stop`, `toolUse`, `error`,
  /// `aborted`, …).
  final String? stopReason;

  /// The provider HTTP status when known: on `error`, the status of the
  /// failed request (typed [ProviderHttpError], or parsed from the harness
  /// error formatter's own `<status>: <body>` shape); on `runEnd`, the
  /// status of the LAST request (2xx when any token streamed, else null).
  final int? httpStatus;

  /// Free-form detail: model id on requestStart/firstToken, the formatted
  /// provider error on error, the stuck action label on toolStuck.
  final String? detail;

  const AgentTelemetryEvent({
    required this.kind,
    required this.timestamp,
    required this.sinceRunStart,
    this.toolCallId,
    this.toolName,
    this.isError,
    this.stopReason,
    this.httpStatus,
    this.detail,
  });

  @override
  String toString() {
    final head =
        '${timestamp.toIso8601String()} ${sinceRunStart.inMilliseconds}ms ${kind.name}';
    final parts = [
      if (toolName != null) 'name=$toolName',
      if (toolCallId != null) 'id=$toolCallId',
      if (isError != null) 'error=$isError',
      if (stopReason != null) 'stop=$stopReason',
      if (httpStatus != null) 'http=$httpStatus',
      ?detail,
    ];
    return parts.isEmpty ? head : '$head ${parts.join(' ')}';
  }
}

/// The telemetry backend a host supplies. Methods must not throw — the
/// adapter treats a throwing sink like a broken log file: swallowed, never
/// allowed to break the run.
abstract interface class AgentTelemetrySink {
  /// Records one lifecycle event.
  void record(AgentTelemetryEvent event);
}

/// The pure-host default sink: a bounded in-memory ring, oldest dropped
/// first. A host reads [events] for live UI or debug dumps.
final class InMemoryTelemetrySink implements AgentTelemetrySink {
  InMemoryTelemetrySink({this.capacity = 256});

  /// Maximum records retained.
  final int capacity;

  final _events = <AgentTelemetryEvent>[];

  /// Retained records, oldest first (newest last).
  List<AgentTelemetryEvent> get events => List.unmodifiable(_events);

  @override
  void record(AgentTelemetryEvent event) {
    _events.add(event);
    if (_events.length > capacity) _events.removeAt(0);
  }
}

/// The agent → sink adapter. Wire it through [AgentCoreServices.telemetry]
/// — `buildAgentStack` attaches the listener and wraps the stream function
/// so a host opts in with one constructor field. The event map mirrors the
/// CLI's fa.log forensics line-for-line (issue #1322 AC: the same
/// fidelity for an in-process host), extended with `firstToken` and the
/// provider HTTP status.
final class AgentTelemetry {
  /// Creates an adapter writing to [sink].
  AgentTelemetry(this.sink);

  /// The host's sink. A throwing `record` is swallowed (diagnostics never
  /// break the run — the CLI's own log writer has the same contract).
  final AgentTelemetrySink sink;

  DateTime? _runStart;
  bool _sawFirstToken = false;
  int? _lastHttpStatus;

  /// Subscribes to [agent]'s lifecycle events. Returns the unsubscribe
  /// function (the same contract as [Agent.subscribe]).
  void Function() attach(Agent agent) => agent.subscribe(_onEvent);

  FutureOr<void> _onEvent(AgentEvent event, CancelToken cancelToken) {
    try {
      _record(event);
    } catch (_) {
      // Diagnostics must never break the run.
    }
  }

  void _record(AgentEvent event) {
    switch (event) {
      case AgentStartEvent():
        _runStart = DateTime.now();
        _sawFirstToken = false;
        _lastHttpStatus = null;
        _emit(AgentTelemetryEventKind.runStart);
      case TurnStartEvent():
        _emit(AgentTelemetryEventKind.turnStart);
      case MessageUpdateEvent() when !_sawFirstToken:
        // The agent loop's first streamed update — the provider answered.
        _sawFirstToken = true;
        _emit(AgentTelemetryEventKind.firstToken);
      case ToolExecutionStartEvent(:final toolCallId, :final toolName):
        _emit(
          AgentTelemetryEventKind.toolStart,
          toolCallId: toolCallId,
          toolName: toolName,
        );
      case ToolExecutionEndEvent(
        :final toolCallId,
        :final toolName,
        :final isError,
      ):
        _emit(
          AgentTelemetryEventKind.toolEnd,
          toolCallId: toolCallId,
          toolName: toolName,
          isError: isError,
        );
      case ToolCallHeartbeatEvent(
        :final toolCallId,
        :final toolName,
        :final elapsed,
      ):
        _emit(
          AgentTelemetryEventKind.toolHeartbeat,
          toolCallId: toolCallId,
          toolName: toolName,
          detail: 'elapsed=${elapsed.inSeconds}s',
        );
      case ToolCallStuckEvent(
        :final toolCallId,
        :final toolName,
        :final action,
        :final elapsed,
      ):
        _emit(
          AgentTelemetryEventKind.toolStuck,
          toolCallId: toolCallId,
          toolName: toolName,
          detail: 'action=${action.name} elapsed=${elapsed.inSeconds}s',
        );
      case TurnEndEvent(:final message):
        _emit(
          AgentTelemetryEventKind.turnEnd,
          stopReason: message.stopReason.name,
        );
      case AgentEndEvent():
        final error = agentErrorMessage(event);
        if (error != null) {
          _emit(
            AgentTelemetryEventKind.error,
            httpStatus: _lastHttpStatus,
            detail: error,
          );
        }
        _emit(
          AgentTelemetryEventKind.runEnd,
          httpStatus: error == null ? _lastHttpStatus : null,
        );
      default:
      // MessageStart/End, ModelRequest, pairing repair, partial
      // updates — per-message detail the CLI also keeps out of fa.log.
    }
  }

  /// The terminal error of a finished run, or null on a clean run. The
  /// agent loop stores the last failed assistant turn's message on the
  /// agent state; [event]'s messages carry the same field.
  String? agentErrorMessage(AgentEndEvent event) {
    for (final message in event.messages.reversed) {
      if (message is AssistantMessage && message.errorMessage != null) {
        return message.errorMessage;
      }
    }
    return null;
  }

  void _emit(
    AgentTelemetryEventKind kind, {
    String? toolCallId,
    String? toolName,
    bool? isError,
    String? stopReason,
    int? httpStatus,
    String? detail,
  }) {
    final start = _runStart;
    sink.record(
      AgentTelemetryEvent(
        kind: kind,
        timestamp: DateTime.now(),
        sinceRunStart: start == null
            ? Duration.zero
            : DateTime.now().difference(start),
        toolCallId: toolCallId,
        toolName: toolName,
        isError: isError,
        stopReason: stopReason,
        httpStatus: httpStatus ?? _kindStatus(kind),
        detail: detail,
      ),
    );
  }

  /// requestStart/firstToken imply the transport is at least talking — no
  /// status is claimed for them (a hang after requestStart has no status
  /// to report, which is exactly the diagnosable state).
  int? _kindStatus(AgentTelemetryEventKind kind) =>
      kind == AgentTelemetryEventKind.error ? _lastHttpStatus : null;

  /// Wraps [inner] so the provider leg records `requestStart` (the exact
  /// moment a hung call starts), `firstToken` (the first provider event —
  /// the 512-s zero-byte hang from the issue is visible as requestStart
  /// with no firstToken and a growing age), and the structured HTTP status
  /// of a failed request on the follow-up `error` record.
  StreamFunction wrapStreamFunction(StreamFunction inner) {
    return (model, context, {cancelToken}) {
      _emit(
        AgentTelemetryEventKind.requestStart,
        detail: 'model=${model.id} provider=${model.provider}',
      );
      final outer = AssistantMessageEventStream();
      AssistantMessageEventStream response;
      try {
        response = inner(model, context, cancelToken: cancelToken);
      } catch (error) {
        // The provider threw before a stream existed (non-2xx pre-stream
        // paths): the providers-never-throw contract turned into an event.
        _statusFromError(error);
        outer.push(_errorEventFor(error, model));
        outer.end();
        return outer;
      }
      unawaited(_pump(outer, response, model));
      return outer;
    };
  }

  /// The providers-never-throw conversion for an exception that escaped a
  /// provider stream: an [ErrorEvent] whose message is formatted exactly
  /// like the provider layer formats its own failures.
  ErrorEvent _errorEventFor(Object error, Model model) => ErrorEvent(
    reason: StopReason.error,
    error: AssistantMessage(
      api: model.api,
      provider: model.provider,
      model: model.id,
      content: const [],
      usage: Usage.zero,
      stopReason: StopReason.error,
      errorMessage: formatProviderError(error),
      timestamp: DateTime.now(),
    ),
  );

  Future<void> _pump(
    AssistantMessageEventStream outer,
    AssistantMessageEventStream inner,
    Model model,
  ) async {
    var first = true;
    try {
      await for (final event in inner) {
        if (first) {
          first = false;
          // Provider bytes are flowing: the transport answered. No status
          // is claimed (the adapters throw on non-2xx, so this is the
          // success path) — only `error`/`runEnd` carry one.
          _sawFirstToken = true;
          _emit(AgentTelemetryEventKind.firstToken);
        }
        if (event is ErrorEvent) _statusFromError(event.error.errorMessage);
        outer.push(event);
      }
    } catch (error) {
      _statusFromError(error);
      outer.push(_errorEventFor(error, model));
    } finally {
      outer.end();
    }
  }

  /// Extracts the structured status for the next error record: a typed
  /// [ProviderHttpError] directly, else the harness formatter's own
  /// leading `<status>: ` shape (formatProviderError renders
  /// ProviderHttpError as `'$statusCode: …'`; parsing OUR format, not
  /// provider prose).
  void _statusFromError(Object? error) {
    if (error is ProviderHttpError) {
      _lastHttpStatus = error.statusCode;
      return;
    }
    if (error is String) {
      final match = RegExp(r'^(\d{3}): ').firstMatch(error);
      if (match != null) _lastHttpStatus = int.tryParse(match.group(1)!);
    }
  }
}
