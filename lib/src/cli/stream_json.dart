/// Stream-JSON output for headless `fa` runs (issue #695).
///
/// `fa --output-format stream-json "prompt"` (alias `--mode json`) turns a
/// headless run into a live, machine-readable event stream: one compact
/// JSON object per line on stdout, pi-`--mode json` /
/// claude-code-`--output-format stream-json` parity. The wire contract is
/// pi's closed `JsonAgentSessionEvent` set (`docs/json.md` in
/// pi-coding-agent) — nothing fa-native rides the stream:
///
/// - First line, the session header:
///   `{"type":"session","version":1,"id":"...","timestamp":"...","cwd":"..."}`.
/// - `agent_start`, `turn_start`, `message_start`/`message_end` (the full
///   message JSON, the same canonical encoding the session record
///   persists), `message_update` (delta-only: `assistantMessageEvent` plus
///   the cumulative `usage`, NO message snapshot — keeps the stream size
///   linear), `tool_execution_start` (`toolCallId`/`toolName`/`args`),
///   `tool_execution_update` (`partialResult`), `tool_execution_end`
///   (`result`/`isError`), `turn_end` (`message`/`toolResults`),
///   `agent_end` (`messages`), `agent_settled`.
/// - fa-internal events ([ModelRequestEvent],
///   [ToolPairingRepairEvent]) are FILTERED OUT by design — cost/repair
///   visibility stays with the TUI, `fa trajectory`, and the session
///   ledger. The dispatch mirrors the HEP writer's defaulted family
///   switches (CRAP gate); the sealed-set triage is enforced by the
///   encoder test, which enumerates every [AgentEvent] AND every
///   [AssistantMessageEvent] subtype with count tripwires, so a new
///   subtype cannot slip into (or silently vanish from) the stream
///   unnoticed — and if one still slips past CI,
///   [StreamJsonWriter.handleEvent] degrades it to a `warning` line
///   instead of letting the throw kill the run.
///
/// Redaction rides free: the loop finalizes tool results through the
/// `afterToolCall` hook BEFORE emitting [ToolExecutionEndEvent], and the
/// headless prompt text is redacted before it ever becomes a message —
/// so the stream projects exactly what the persisted session record
/// holds, never a second, leakier dialect.
///
/// Bounding: image content serializes as a placeholder, never a base64
/// blob (E5), and tool-result text is capped at
/// [streamJsonMaxToolResultChars] with the house `…(+N chars)` marker
/// (E3) — a pathological payload must not blow the consumer's pipe.
library;

import 'dart:convert';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../types.dart';

/// The wire version in the session header line (fa's own stream schema;
/// pi's current header says 3 for its superset).
const streamJsonVersion = 1;

/// Placeholder emitted for image content blocks (E5): non-UTF8-safe
/// payloads never ride the stream as base64 blobs.
const streamJsonImagePlaceholder = '[image data omitted]';

/// Cap on a single tool-result text block in the stream (E3), matching
/// the house truncation idiom (`…(+N chars)`).
const streamJsonMaxToolResultChars = 100 * 1000;

/// Builds the session header line (always the first stdout line).
String streamJsonSessionHeaderLine({
  required String sessionId,
  required String cwd,
  DateTime? timestamp,
}) {
  final stamp = (timestamp ?? DateTime.now()).toUtc().toIso8601String();
  return jsonEncode({
    'type': 'session',
    'version': streamJsonVersion,
    'id': sessionId,
    'timestamp': stamp,
    'cwd': cwd,
  });
}

/// Maps one [AgentEvent] to its stream-json line, or `null` when the
/// event is filtered out of the stream (fa-native events).
///
/// Like the HEP writer, the dispatch is split into small defaulted
/// switches (lifecycle vs tool-execution families) to stay under the
/// repo's CRAP gate; the sealed-set triage AC (issue #695 AC2) is
/// enforced by the encoder test, which enumerates every [AgentEvent]
/// subtype (count tripwire included) and asserts each is mapped or
/// explicitly filtered.
String? streamJsonEventLine(AgentEvent event) {
  final Map<String, dynamic>? json;
  if (event is ToolExecutionStartEvent ||
      event is ToolExecutionUpdateEvent ||
      event is ToolExecutionEndEvent) {
    json = _toolExecutionEventJson(event);
  } else {
    json = _lifecycleEventJson(event);
  }
  if (json == null) return null;
  return jsonEncode(json);
}

/// The run/turn/message arms of [streamJsonEventLine].
Map<String, dynamic>? _lifecycleEventJson(AgentEvent event) => switch (event) {
  AgentStartEvent() => {'type': 'agent_start'},
  AgentEndEvent(:final messages) => {
    'type': 'agent_end',
    'messages': [for (final message in messages) _projectMessage(message)],
  },
  AgentSettledEvent() => {'type': 'agent_settled'},
  TurnStartEvent() => {'type': 'turn_start'},
  TurnEndEvent(:final message, :final toolResults) => {
    'type': 'turn_end',
    'message': _projectMessage(message),
    'toolResults': [for (final result in toolResults) _projectMessage(result)],
  },
  MessageStartEvent(:final message) => {
    'type': 'message_start',
    'message': _projectMessage(message),
  },
  MessageUpdateEvent(:final assistantMessageEvent, :final message) => {
    'type': 'message_update',
    // Cumulative provider-reported usage (AC8); may stay zero when
    // the provider only reports usage at completion.
    'usage': message.usage.toJson(),
    'assistantMessageEvent': _assistantMessageEventJson(assistantMessageEvent),
  },
  MessageEndEvent(:final message) => {
    'type': 'message_end',
    'message': _projectMessage(message),
  },
  // Filtered by design (issue #695): fa-native events never ride the
  // pi-shaped stream — cost/repair visibility stays with the TUI,
  // `fa trajectory`, and the session ledger.
  _ => null,
};

/// The tool-execution arms of [streamJsonEventLine].
Map<String, dynamic>? _toolExecutionEventJson(
  AgentEvent event,
) => switch (event) {
  ToolExecutionStartEvent(:final toolCallId, :final toolName, :final args) => {
    'type': 'tool_execution_start',
    'toolCallId': toolCallId,
    'toolName': toolName,
    'args': _sanitize(args),
  },
  ToolExecutionUpdateEvent(
    :final toolCallId,
    :final toolName,
    :final partialResult,
  ) =>
    {
      'type': 'tool_execution_update',
      'toolCallId': toolCallId,
      'toolName': toolName,
      // pi's shape: `partialResult` only — the args already went out
      // with `tool_execution_start` under the same `toolCallId`, so
      // re-sending them would grow the stream quadratically on chatty
      // partial updates with large payloads.
      'partialResult': _toolResultJson(partialResult),
    },
  ToolExecutionEndEvent(
    :final toolCallId,
    :final toolName,
    :final result,
    :final isError,
  ) =>
    {
      'type': 'tool_execution_end',
      'toolCallId': toolCallId,
      'toolName': toolName,
      'result': _toolResultJson(result),
      'isError': isError,
    },
  _ => null,
};

/// Streams [AgentEvent]s as stream-json lines — one [emit] per line.
///
/// [AgentListener]-shaped on purpose (like the HEP writer): the headless
/// run wires it with `agent.subscribe(writer.handleEvent)` and the host
/// owns the stdout sink. [writeHeader] must be called first; it is a
/// no-op after the first line.
class StreamJsonWriter {
  /// Creates a writer emitting to [emit] (hosts pass a stdout line sink).
  StreamJsonWriter({required this._emit});

  final void Function(String line) _emit;
  var _headerWritten = false;

  /// Emits the session header line (once; further calls are no-ops).
  void writeHeader({
    required String sessionId,
    required String cwd,
    DateTime? timestamp,
  }) {
    if (_headerWritten) return;
    _headerWritten = true;
    _emit(
      streamJsonSessionHeaderLine(
        sessionId: sessionId,
        cwd: cwd,
        timestamp: timestamp,
      ),
    );
  }

  /// Handles one agent event (AgentListener shape); filtered events
  /// emit nothing.
  ///
  /// Graceful degrade: a projection hiccup — an [AssistantMessageEvent]
  /// subtype this encoder version has not triaged (the default arms
  /// below throw for it) or a value `jsonEncode` cannot express (e.g. a
  /// non-finite provider-reported cost) — must never kill a live
  /// headless run; an unawaited-listener throw propagates into the
  /// agent loop and turns the whole run into `stopReason: error`. It
  /// degrades to a `warning` line instead: the header's `version` is
  /// the wire's compatibility contract (consumers skip event `type`s
  /// they do not know), so the run streams on with the gap visible,
  /// while the encoder test's subtype-count tripwire keeps new subtypes
  /// loud at build time.
  Future<void> handleEvent(AgentEvent event, CancelToken? cancelToken) async {
    String? line;
    try {
      line = streamJsonEventLine(event);
    } on Object catch (error) {
      line = jsonEncode({
        'type': 'warning',
        'eventType': event.runtimeType.toString(),
        'message': 'stream-json projection failed: $error',
      });
    }
    if (line != null) _emit(line);
  }
}

/// Serializes an [AssistantMessageEvent] without its `partial` snapshot
/// (pi's `WithoutPartial` projection). `toolcall_start` additionally
/// carries the constant-sized `id`/`toolName` fields (pi parity) so
/// consumers can correlate tool traffic without snapshots.
///
/// Split into text/thinking vs tool-call/terminal family switches (CRAP
/// gate); the encoder test enumerates every [AssistantMessageEvent]
/// subtype with a count tripwire (same shape as the [AgentEvent] triage
/// test), so a new one cannot slip through unserialized — and if one
/// still reaches an untriaged default arm at runtime,
/// [StreamJsonWriter.handleEvent] degrades to a warning line instead of
/// letting the throw kill the run.
Map<String, dynamic> _assistantMessageEventJson(AssistantMessageEvent event) =>
    event is StartEvent ||
        event is TextStartEvent ||
        event is TextDeltaEvent ||
        event is TextEndEvent ||
        event is ThinkingStartEvent ||
        event is ThinkingDeltaEvent ||
        event is ThinkingEndEvent
    ? _textStreamEventJson(event)
    : _callStreamEventJson(event);

/// The stream-start and text/thinking arms of
/// [_assistantMessageEventJson].
Map<String, dynamic> _textStreamEventJson(AssistantMessageEvent event) {
  switch (event) {
    case StartEvent():
      return {'type': 'start'};
    case TextStartEvent(:final contentIndex):
      return {'type': 'text_start', 'contentIndex': contentIndex};
    case TextDeltaEvent(:final contentIndex, :final delta):
      return {
        'type': 'text_delta',
        'contentIndex': contentIndex,
        'delta': delta,
      };
    case TextEndEvent(:final contentIndex, :final content):
      return {
        'type': 'text_end',
        'contentIndex': contentIndex,
        'content': content,
      };
    case ThinkingStartEvent(:final contentIndex):
      return {'type': 'thinking_start', 'contentIndex': contentIndex};
    case ThinkingDeltaEvent(:final contentIndex, :final delta):
      return {
        'type': 'thinking_delta',
        'contentIndex': contentIndex,
        'delta': delta,
      };
    case ThinkingEndEvent(:final contentIndex, :final content):
      return {
        'type': 'thinking_end',
        'contentIndex': contentIndex,
        'content': content,
      };
    default:
      // Unreachable via the router above; a new AssistantMessageEvent
      // subtype lands here and throws rather than serializing wrong
      // data. [StreamJsonWriter.handleEvent] contains the throw (a
      // warning line, never a dead run), and the encoder test's
      // subtype-count tripwire surfaces it at build time.
      throw StateError('untriaged AssistantMessageEvent: ${event.runtimeType}');
  }
}

/// The tool-call and terminal (done/error) arms of
/// [_assistantMessageEventJson].
Map<String, dynamic> _callStreamEventJson(AssistantMessageEvent event) {
  switch (event) {
    case ToolCallStartEvent(:final contentIndex, :final partial):
      final block = partial.content.length > contentIndex
          ? partial.content[contentIndex]
          : null;
      final call = block is ToolCall ? block : null;
      return {
        'type': 'toolcall_start',
        'contentIndex': contentIndex,
        if (call != null) 'id': call.id,
        if (call != null) 'toolName': call.name,
      };
    case ToolCallDeltaEvent(:final contentIndex, :final delta):
      return {
        'type': 'toolcall_delta',
        'contentIndex': contentIndex,
        'delta': delta,
      };
    case ToolCallEndEvent(:final contentIndex, :final toolCall):
      return {
        'type': 'toolcall_end',
        'contentIndex': contentIndex,
        'toolCall': toolCall.toJson(),
      };
    case DoneEvent(:final reason):
      return {'type': 'done', 'reason': reason.name};
    case ErrorEvent(:final reason, :final error, :final retryAfter):
      return {
        'type': 'error',
        'reason': reason.name,
        'error': error.errorMessage ?? '',
        if (retryAfter != null) 'retryAfter': retryAfter.inMilliseconds,
      };
    default:
      // Unreachable via the router above; a new AssistantMessageEvent
      // subtype lands here and throws rather than serializing wrong
      // data. [StreamJsonWriter.handleEvent] contains the throw (a
      // warning line, never a dead run), and the encoder test's
      // subtype-count tripwire surfaces it at build time.
      throw StateError('untriaged AssistantMessageEvent: ${event.runtimeType}');
  }
}

/// Serializes a [ToolExecutionResult] with bounded text (E3) and image
/// placeholders (E5).
Map<String, dynamic> _toolResultJson(ToolExecutionResult result) => {
  'content': [
    for (final block in result.content) _projectBlock(block, capText: true),
  ],
  'terminate': result.terminate,
};

/// Serializes a [Message] through the canonical session-record encoding
/// (`Message.toJson`), then bounds its content blocks for the stream:
/// image data becomes a placeholder, tool-result-scale text is capped.
Map<String, dynamic> _projectMessage(Message message) {
  final json = message.toJson();
  final content = json['content'];
  if (content is List) {
    json['content'] = [
      for (final block in content)
        if (block is Map<String, dynamic>)
          _projectJsonBlock(block, capText: message is ToolResultMessage)
        else
          block,
    ];
  }
  return json;
}

/// Bounds a content block object already in JSON form.
Map<String, dynamic> _projectJsonBlock(
  Map<String, dynamic> block, {
  required bool capText,
}) {
  if (block['type'] == 'image') {
    return {
      'type': 'image',
      if (block['mimeType'] is String) 'mimeType': block['mimeType'],
      'data': streamJsonImagePlaceholder,
    };
  }
  final text = block['text'];
  if (capText && text is String && text.length > streamJsonMaxToolResultChars) {
    return {...block, 'text': _capped(text)};
  }
  return block;
}

/// Bounds a typed content block (tool results) through its JSON form.
Map<String, dynamic> _projectBlock(
  ContentBlock block, {
  required bool capText,
}) => _projectJsonBlock(block.toJson(), capText: capText);

String _capped(String text) =>
    '${text.substring(0, streamJsonMaxToolResultChars)}'
    '…(+${text.length - streamJsonMaxToolResultChars} chars)';

/// Recursively replaces values that [jsonEncode] cannot handle with the
/// string `'[unserializable]'` (same contract as `ToolCall.toJson`).
Object? _sanitize(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is List<dynamic>) {
    return value.map(_sanitize).toList();
  }
  if (value is Map<String, dynamic>) {
    return value.map((key, child) => MapEntry(key, _sanitize(child)));
  }
  return '[unserializable]';
}
