/// HEP v1 — the Harness Event Protocol: `--output events` (issue #155).
///
/// A strict JSONL stream on stdout for server-side supervisors (the Go
/// backend agent driver): one JSON object per line, nothing else. The
/// supervisor consumes lifecycle frames to mirror UI progress, capture
/// tool traffic, and react to cancels — without scraping human prose.
///
/// A **turn is one assistant LLM round** — one model response plus the
/// tool calls it triggered — NOT one user message. A user message that
/// runs tools produces several rounds, so it yields SEVERAL terminal
/// frames (one per round, turn ids incrementing); the LAST terminal
/// frame of the run carries the user-visible answer.
///
/// Frame set:
///
/// - `hep_header` — first line; protocol + fah versions and session id.
/// - `agent_start` — the run began; carries the first `turn_id` (once
///   per run, never re-emitted on later rounds).
/// - `message_start` / `message_delta` — assistant text streaming
///   (thinking deltas are NOT `message_delta` frames).
/// - `tool_start` / `tool_delta` — tool calls and their partial output.
/// - `turn_done` / `turn_error` / `cancelled` — exactly one terminal
///   frame per round, in order.
/// - `compaction_start` / `compaction_end` — context compaction runs
///   (pre-flight or post-turn), bracketed like a round.
///
/// Turn ids are small incrementing integers starting at 1; every frame of
/// a round carries the same id. Pre-flight compaction allocates the id of
/// the round it precedes, so the following `agent_start` reuses it.
library;

import 'dart:convert';

import '../agent/agent_loop.dart';
import '../cancel_token.dart';
import '../context.dart';
import '../types.dart';
import 'text_format.dart';

/// The HEP protocol version emitted in `hep_header` frames.
const hepVersion = 'v1';

/// Tool-argument verbosity for `tool_start` frames.
enum HepToolArgs {
  /// One-line `key=value` summary (`--output events`, the default).
  summary,

  /// Raw JSON arguments, bounded (`--output events=full`).
  full,
}

/// The `tool_results[].text` cap — a pathological tool output must not
/// blow the supervisor's pipe.
const _toolResultTextCap = 2000;

/// The `args_summary` cap in [HepToolArgs.full] mode.
const _fullArgsCap = 4000;

/// Builds the header frame: protocol version, fah version, session id.
String hepHeaderFrame({required String fahVersion, required String sessionId}) {
  return jsonEncode({
    'type': 'hep_header',
    'hep': hepVersion,
    'fah': fahVersion,
    'session': sessionId,
  });
}

/// Builds `agent_start` for [turnId].
String hepAgentStartFrame({required int turnId}) =>
    jsonEncode({'type': 'agent_start', 'turn_id': turnId});

/// Builds `message_start` for [turnId].
String hepMessageStartFrame({required int turnId, required String role}) =>
    jsonEncode({'type': 'message_start', 'turn_id': turnId, 'role': role});

/// Builds `message_delta` for [turnId].
String hepMessageDeltaFrame({required int turnId, required String delta}) =>
    jsonEncode({'type': 'message_delta', 'turn_id': turnId, 'delta': delta});

/// Builds `tool_start` for [turnId].
String hepToolStartFrame({
  required int turnId,
  required String id,
  required String name,
  required String argsSummary,
}) => jsonEncode({
  'type': 'tool_start',
  'turn_id': turnId,
  'id': id,
  'name': name,
  'args_summary': argsSummary,
});

/// Builds `tool_delta` for [turnId].
String hepToolDeltaFrame({
  required int turnId,
  required String id,
  required String update,
}) => jsonEncode({'type': 'tool_delta', 'turn_id': turnId, 'id': id, 'update': update});

/// Builds `turn_done` for [turnId].
String hepTurnDoneFrame({
  required int turnId,
  required String message,
  required List<Map<String, Object>> toolResults,
  required Usage usage,
  required String stopReason,
}) => jsonEncode({
  'type': 'turn_done',
  'turn_id': turnId,
  'message': message,
  'tool_results': toolResults,
  'usage': {
    'input': usage.input,
    'output': usage.output,
    'cost': usage.cost.total,
  },
  'stop_reason': stopReason,
});

/// Builds `turn_error` for [turnId].
String hepTurnErrorFrame({
  required int turnId,
  required String error,
  required bool fatal,
}) => jsonEncode({
  'type': 'turn_error',
  'turn_id': turnId,
  'error': error,
  'fatal': fatal,
});

/// Builds `cancelled` for [turnId].
String hepCancelledFrame({required int turnId}) =>
    jsonEncode({'type': 'cancelled', 'turn_id': turnId});

/// Builds `compaction_start` for [turnId].
String hepCompactionStartFrame(int turnId) =>
    jsonEncode({'type': 'compaction_start', 'turn_id': turnId});

/// Builds `compaction_end` for [turnId].
String hepCompactionEndFrame(int turnId, int tokensFreed) =>
    jsonEncode({'type': 'compaction_end', 'turn_id': turnId, 'tokens_freed': tokensFreed});

/// Renders tool-call arguments for a `tool_start` frame.
String hepArgsSummary(Map<String, dynamic> args, HepToolArgs mode) {
  if (mode == HepToolArgs.full) {
    final encoded = safeJsonEncode(args);
    if (encoded.length <= _fullArgsCap) return encoded;
    return '${encoded.substring(0, _fullArgsCap)}…(+${encoded.length - _fullArgsCap} chars)';
  }
  return formatArgs(args);
}

/// Joins an assistant message's text blocks into the `turn_done` message.
String hepMessageText(AssistantMessage message) => [
  for (final block in message.content)
    if (block is TextContent) block.text,
].join('\n');

/// Builds a `tool_results` entry from a tool result message.
Map<String, Object> hepToolResultEntry(ToolResultMessage result) {
  final text = [
    for (final block in result.content)
      if (block is TextContent) block.text,
  ].join('\n');
  return {
    'id': result.toolCallId,
    'name': result.toolName,
    'ok': !result.isError,
    'text': _bound(text, _toolResultTextCap),
  };
}

String _bound(String text, int cap) =>
    text.length <= cap ? text : '${text.substring(0, cap)}…(+${text.length - cap} chars)';

/// Streams [AgentEvent]s as HEP v1 JSONL frames — one [emit] per line.
///
/// [AgentListener]-shaped on purpose: `agent.subscribe(hep.handleEvent)`
/// wires it directly. Owns stdout exclusively in events mode (see the
/// host's CliIO decorator): every [emit] must land on its own line.
class HepWriter {
  /// Creates a writer emitting to [emit] (hosts pass a stdout line sink).
  HepWriter({
    required void Function(String line) emit,
    required this.fahVersion,
    this.toolArgs = HepToolArgs.summary,
  }) : _emit = emit;

  final void Function(String line) _emit;

  /// The fah version reported in the header frame.
  final String fahVersion;

  /// Tool-argument verbosity for `tool_start` frames.
  final HepToolArgs toolArgs;

  var _nextTurnId = 1;
  int? _openTurnId;
  var _agentStartEmitted = false;
  var _headerWritten = false;

  /// The turn id frames currently belong to (the last allocated one when
  /// between turns) — the host uses it to correlate compaction brackets.
  int get currentTurnId => _openTurnId ?? _nextTurnId - 1;

  /// Emits the `hep_header` frame (once; further calls are no-ops).
  void writeHeader({required String sessionId}) {
    if (_headerWritten) return;
    _headerWritten = true;
    _emit(hepHeaderFrame(fahVersion: fahVersion, sessionId: sessionId));
  }

  /// Emits `compaction_start`, allocating the id of the turn the
  /// compaction precedes (the following `agent_start` reuses it).
  void compactionStart() {
    final turnId = _openTurnId ??= _nextTurnId++;
    _emit(hepCompactionStartFrame(turnId));
  }

  /// Emits `compaction_end` with the tokens freed. The turn stays open:
  /// its `agent_start`/terminal frames follow under the same id.
  void compactionEnd(int tokensFreed) {
    _emit(hepCompactionEndFrame(_openTurnId ?? currentTurnId, tokensFreed));
  }

  /// Handles one agent event (AgentListener shape). The turn-lifecycle
  /// arms live here; the streaming arms (message/tool deltas) are split
  /// into [_handleStreamEvent] — one switch each keeps the CRAP gate.
  Future<void> handleEvent(AgentEvent event, CancelToken cancelToken) async {
    switch (event) {
      case AgentStartEvent():
        if (!_agentStartEmitted) {
          _agentStartEmitted = true;
          final turnId = _openTurnId ??= _nextTurnId++;
          _emit(hepAgentStartFrame(turnId: turnId));
        }
      case TurnStartEvent():
        _openTurnId ??= _nextTurnId++;
      case MessageStartEvent(:final message):
        if (message is AssistantMessage) {
          _emit(
            hepMessageStartFrame(turnId: _turnId(), role: 'assistant'),
          );
        }
      case MessageUpdateEvent(:final assistantMessageEvent):
        if (assistantMessageEvent is TextDeltaEvent) {
          _emit(
            hepMessageDeltaFrame(
              turnId: _turnId(),
              delta: assistantMessageEvent.delta,
            ),
          );
        }
      case TurnEndEvent(:final message, :final toolResults):
        _emitTerminal(message, toolResults);
      default:
        _handleStreamEvent(event);
    }
  }

  /// The tool-execution streaming arms of [handleEvent].
  void _handleStreamEvent(AgentEvent event) {
    switch (event) {
      case ToolExecutionStartEvent(:final toolCallId, :final toolName, :final args):
        _emit(
          hepToolStartFrame(
            turnId: _turnId(),
            id: toolCallId,
            name: toolName,
            argsSummary: hepArgsSummary(args, toolArgs),
          ),
        );
      case ToolExecutionUpdateEvent(
        :final toolCallId,
        :final partialResult,
      ):
        final update = [
          for (final block in partialResult.content)
            if (block is TextContent) block.text,
        ].join('\n');
        if (update.isNotEmpty) {
          _emit(
            hepToolDeltaFrame(turnId: _turnId(), id: toolCallId, update: update),
          );
        }
      default:
        break;
    }
  }

  int _turnId() => _openTurnId ??= _nextTurnId++;

  void _emitTerminal(AssistantMessage message, List<ToolResultMessage> toolResults) {
    final turnId = _turnId();
    switch (message.stopReason) {
      case StopReason.aborted:
        _emit(hepCancelledFrame(turnId: turnId));
      case StopReason.error:
        _emit(
          hepTurnErrorFrame(
            turnId: turnId,
            error: message.errorMessage ?? 'unknown error',
            fatal: true,
          ),
        );
      default:
        _emit(
          hepTurnDoneFrame(
            turnId: turnId,
            message: hepMessageText(message),
            toolResults: [
              for (final result in toolResults) hepToolResultEntry(result),
            ],
            usage: message.usage,
            stopReason: message.stopReason.name,
          ),
        );
    }
    _openTurnId = null;
  }
}
