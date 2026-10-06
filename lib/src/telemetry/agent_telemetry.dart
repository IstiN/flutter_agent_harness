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

  /// The provider HTTP status of the FAILED request, on the `error` kind:
  /// typed [ProviderHttpError] when the harness has it, else parsed from
  /// the error formatter's own `<status>: ` shape. Null on every other
  /// kind — success statuses are not observable through the event surface
  /// (a streamed token implies 2xx, but the code never crosses it), so
  /// `runEnd` carries the duration and stop outcome only.
  final int? httpStatus;

  /// The heartbeat's captured-output size in bytes (toolHeartbeat only).
  final int? outputBytes;

  /// The stuck-supervision attempt number (toolHeartbeat/toolStuck only).
  final int? attempt;

  const AgentTelemetryEvent({
    required this.kind,
    required this.timestamp,
    required this.sinceRunStart,
    this.toolCallId,
    this.toolName,
    this.isError,
    this.stopReason,
    this.httpStatus,
    this.outputBytes,
    this.attempt,
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
      if (outputBytes != null) 'out=${outputBytes}B',
      if (attempt != null) 'attempt=$attempt',
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
  Agent? _agent;

  /// Subscribes to [agent]'s lifecycle events. Returns the unsubscribe
  /// function (the same contract as [Agent.subscribe]).
  void Function() attach(Agent agent) {
    _agent = agent;
    return agent.subscribe(_onEvent);
  }

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
        _emit(
          AgentTelemetryEventKind.firstToken,
          detail: _modelDetail(_agent?.state.model),
        );
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
        :final outputBytes,
        :final attempt,
      ):
        _emit(
          AgentTelemetryEventKind.toolHeartbeat,
          toolCallId: toolCallId,
          toolName: toolName,
          outputBytes: outputBytes,
          attempt: attempt,
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
        // Aborted runs (user stop, watchdog fire) are NOT errors — the
        // CLI's fa.log records them as a plain `run end` with the turn's
        // `stop=aborted` carrying the distinction; mirror that.
        _emit(AgentTelemetryEventKind.runEnd);
      default:
      // MessageStart/End, ModelRequest, pairing repair, partial
      // updates — per-message detail the CLI also keeps out of fa.log.
    }
  }

  /// The terminal PROVIDER error of a finished run, or null. Only a
  /// `StopReason.error` message counts: the abort terminal also carries an
  /// errorMessage (`Operation aborted`), and a user stop / watchdog fire
  /// is a phase outcome, not a failure — it must not produce a `run error`
  /// record (the CLI logs those runs as a plain `run end`).
  String? agentErrorMessage(AgentEndEvent event) {
    for (final message in event.messages.reversed) {
      if (message is AssistantMessage &&
          message.stopReason == StopReason.error &&
          message.errorMessage != null) {
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
    int? outputBytes,
    int? attempt,
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
        httpStatus: httpStatus,
        outputBytes: outputBytes,
        attempt: attempt,
        detail: detail,
      ),
    );
  }

  /// The `model=<id> provider=<id>` context both provider-leg records
  /// carry, so a shared fa.log line names its request without the
  /// preceding record.
  static String _modelDetail(Model? model) =>
      model == null ? '' : 'model=${model.id} provider=${model.provider}';

  /// Wraps [inner] so the provider leg records `requestStart` (the exact
  /// moment a hung call starts), `firstToken` (the first provider event —
  /// the 512-s zero-byte hang from the issue is visible as requestStart
  /// with no firstToken and a growing age), and the structured HTTP status
  /// of a failed request on the follow-up `error` record.
  ///
  /// The wrap is OBSERVATIONAL for conforming providers only: a host
  /// stream function that THROWS (out of contract — providers never
  /// throw) gets its exception converted here into an `ErrorEvent` whose
  /// message is `formatProviderError`-shaped — with telemetry off, the
  /// loop's own conversion records the raw `'$error'` text instead.
  /// Toggling telemetry therefore changes the user-visible message only
  /// for out-of-contract functions; provider adapters are unaffected.
  StreamFunction wrapStreamFunction(StreamFunction inner) {
    return (model, context, {cancelToken}) {
      _emit(AgentTelemetryEventKind.requestStart, detail: _modelDetail(model));
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
          // success path) — only `error` carries one.
          _sawFirstToken = true;
          _emit(
            AgentTelemetryEventKind.firstToken,
            detail: _modelDetail(model),
          );
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
