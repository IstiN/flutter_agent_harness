// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Bridges the on-device Gemma 4 engine (`flutter_gemma` plugin) to the
/// harness's provider contract.
///
/// Emits the same [AssistantMessageEvent] protocol as the HTTP provider
/// adapters (see `streamOpenAICompletions`): `StartEvent` → text and/or
/// tool-call start/delta/end with partial-first snapshots → exactly one
/// terminal `DoneEvent` or `ErrorEvent`. **Errors-as-events is
/// non-negotiable:** this function never throws; engine/config failures and
/// aborts terminate the stream with an [ErrorEvent].
///
/// Function calling IS wired up (unlike most WebLLM presets): Gemma 4 has
/// native function-call tokens and the plugin routes them through the
/// LiteRT-LM SDK's chat-template path when tools are passed at chat
/// creation (`openChat(tools: ...)` — `createChat` drops them, verified
/// against flutter_gemma 1.3.1). Whenever `Context.tools` is non-empty the
/// OpenAI tools array goes to the engine; the plugin surfaces the model's
/// SDK-parsed `tool_calls` complete at end-of-stream, so each call becomes
/// [ToolCallStartEvent] → one [ToolCallDeltaEvent] carrying the full
/// arguments JSON → [ToolCallEndEvent] — the same event sequence an
/// OpenAI-compatible server produces when it does not fragment deltas.
///
/// History is replayed through the engine on every call (the harness owns
/// the conversation; the plugin chat is created fresh per turn), which
/// keeps harness-side history rewrites (compaction) exact. Historical
/// assistant tool calls serialize as the OpenAI-style assistant JSON the
/// plugin's own history replay stores; tool results replay as the plugin's
/// `<tool_response>` blocks.
///
/// Usage accounting: the plugin reports no token counts for a generation,
/// so every message carries [Usage.zero] (documented on the DoneEvent).
library;

import 'dart:async';
import 'dart:convert';

import 'package:fa/gemma/gemma_types.dart';
import 'package:fa/on_device/on_device_message_codec.dart';
import 'package:fa/on_device/on_device_stream_pump.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Builds a [StreamFunction] that runs inference through [service].
///
/// The model id in [Model.id] must be one of [gemmaModelPresets]; unknown
/// ids produce an [ErrorEvent], never a throw.
StreamFunction gemmaStreamFunction(GemmaEngineApi service) {
  return (model, context, {cancelToken}) =>
      streamGemma(service, model, context, cancelToken: cancelToken);
}

/// Streams one assistant message from the on-device engine. See the library
/// docstring for the event contract.
AssistantMessageEventStream streamGemma(
  GemmaEngineApi service,
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final eventStream = AssistantMessageEventStream();
  unawaited(_runGemma(eventStream, service, model, context, cancelToken));
  return eventStream;
}

/// Accumulating state for one streamed tool call (the plugin emits complete
/// calls; the shape mirrors `ToolCallStreamingBlock` in the harness's HTTP
/// adapters, which is package-internal).
final class _GemmaToolCallBlock {
  _GemmaToolCallBlock(this.id);

  /// Synthesized tool call id (the plugin's tool calls carry none).
  final String id;

  /// Tool name from the `function.name` field.
  String name = '';

  /// The accumulated raw JSON argument text.
  final partialArgs = StringBuffer();

  /// Parsed arguments, filled in by [finish].
  Map<String, dynamic> arguments = const <String, dynamic>{};

  /// Whether [finish] has run (the block's end event was pushed).
  var finished = false;

  /// Parses the accumulated [partialArgs] into [arguments].
  void finish() {
    arguments = _parseGemmaToolArgs(partialArgs.toString());
    finished = true;
  }

  /// Converts to the immutable [ToolCall] carried by event snapshots.
  ToolCall toToolCall() => finished
      ? ToolCall(id: id, name: name, arguments: arguments)
      : ToolCall(
          id: id,
          name: name,
          arguments: const <String, dynamic>{},
          partialArguments: partialArgs.toString(),
        );
}

/// Parses a tool call's `function.arguments` JSON string. Falls back to an
/// empty map on malformed JSON — the arguments stay available in raw form
/// on the delta events.
Map<String, dynamic> _parseGemmaToolArgs(String jsonText) {
  try {
    final decoded = jsonDecode(jsonText);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // Fall through to the empty map.
  }
  return const <String, dynamic>{};
}

Future<void> _runGemma(
  AssistantMessageEventStream eventStream,
  GemmaEngineApi service,
  Model model,
  Context context,
  CancelToken? cancelToken,
) async {
  // The emitter and the turn reference each other (snapshots carry the
  // partial tool calls); the holder breaks the declaration cycle.
  _GemmaToolCallEvents? toolEventsRef;
  final turn = OnDeviceStreamTurn(
    eventStream: eventStream,
    model: model,
    formatError: _formatGemmaError,
    extraContent: () => toolEventsRef?.calls ?? const <ToolCall>[],
  );
  final toolEvents = _GemmaToolCallEvents(turn);
  toolEventsRef = toolEvents;

  try {
    cancelToken?.throwIfCancelled();

    final preset = findGemmaPreset(model.id);
    if (preset == null) {
      throw StateError(
        'Unknown Gemma model preset: ${model.id}. Pick one of: '
        '${gemmaModelPresets.map((p) => p.id).join(', ')}',
      );
    }

    // Model load happens here on the very first turn (the settings form
    // pre-loads, so this is normally instant). A cancel during the wait
    // takes effect right after.
    await service.loadModel(preset);
    cancelToken?.throwIfCancelled();

    // The engine's KV budget is shared by input and output and hard-fails
    // past it (INVALID_ARGUMENT) — fit the context instead of ever going
    // there. The active [Model.contextWindow] controls the effective budget
    // (agent config may cap it below the preset maximum); fall back to the
    // preset when the model record carries none.
    final kvBudget = model.contextWindow > 0
        ? model.contextWindow
        : preset.contextWindow;
    final outputReserve = model.maxTokens > 0 ? model.maxTokens : 256;
    final fitted = _fitGemmaContext(
      context,
      budgetTokens: kvBudget - outputReserve - 64,
      onNote: (note) => debugPrint('[gemma] $note'),
    );

    turn.pushStart();

    final call = await pumpOnDeviceChat(
      turn: turn,
      cancelToken: cancelToken,
      interrupt: service.interrupt,
      startChat: (call) => service.chatStream(
        systemInstruction: fitted.systemPrompt,
        messages: convertGemmaMessages(
          Context(
            systemPrompt: fitted.systemPrompt,
            messages: fitted.messages,
            tools: context.tools,
          ),
        ),
        tools: context.tools != null && context.tools!.isNotEmpty
            ? convertGemmaTools(context.tools!)
            : null,
        maxOutputTokens: model.maxTokens > 0 ? model.maxTokens : null,
        onChunk: turn.pushTextDelta,
        onToolCalls: toolEvents.handle,
        onError: (message) {
          call.streamError = message;
          call.complete();
        },
        onDone: call.complete,
      ),
    );

    if (call.streamError != null) {
      throw StateError(call.streamError!);
    }
    cancelToken?.throwIfCancelled();

    turn.pushTextEnd();
    turn.pushDone(toolEvents.finishAll());
  } catch (error) {
    await turn.fail(error, cancelToken: cancelToken);
  } finally {
    turn.end();
  }
}

/// Turns the plugin's end-of-stream `tool_calls` payloads (complete calls
/// in the OpenAI streaming shape) into the tool-call event sequence,
/// tracking the accumulating blocks. The plugin surfaces calls complete at
/// end-of-stream, so each call becomes [ToolCallStartEvent] → one
/// [ToolCallDeltaEvent] carrying the full arguments JSON →
/// [ToolCallEndEvent] — the same event sequence an OpenAI-compatible
/// server produces when it does not fragment deltas.
final class _GemmaToolCallEvents {
  _GemmaToolCallEvents(this._turn);

  final OnDeviceStreamTurn _turn;

  final _blocks = <int, _GemmaToolCallBlock>{};
  final _order = <int>[];
  var _counter = 0;

  /// The accumulated blocks as the [ToolCall]s a snapshot carries.
  List<ToolCall> get calls => [
    for (final key in _order) _blocks[key]!.toToolCall(),
  ];

  /// Tool blocks live after the text block when one exists.
  int _contentIndex(int orderPosition) =>
      (_turn.hasText ? 1 : 0) + orderPosition;

  /// Ingests one `tool_calls` JSON payload.
  void handle(String toolCallsJson) {
    final decoded = jsonDecode(toolCallsJson);
    if (decoded is! List) return;
    for (final entry in decoded) {
      if (entry is! Map) continue;
      final index = entry['index'];
      final key = index is int ? index : _order.length;
      var block = _blocks[key];
      if (block == null) {
        final function = entry['function'];
        final name = function is Map ? function['name'] as String? : null;
        block = _GemmaToolCallBlock(_syntheticId(name));
        _blocks[key] = block;
        _order.add(key);
        _turn.eventStream.push(
          ToolCallStartEvent(
            contentIndex: _contentIndex(_order.length - 1),
            partial: _turn.snapshot(),
          ),
        );
      }
      final function = entry['function'];
      if (function is! Map) continue;
      final name = function['name'];
      if (name is String && name.isNotEmpty) block.name = name;
      final arguments = function['arguments'];
      if (arguments is String && arguments.isNotEmpty) {
        block.partialArgs.write(arguments);
        _turn.eventStream.push(
          ToolCallDeltaEvent(
            contentIndex: _contentIndex(_order.indexOf(key)),
            delta: arguments,
            partial: _turn.snapshot(),
          ),
        );
      }
    }
  }

  /// Closes every block, pushing the end events, and infers the terminal
  /// stop reason: the plugin reports no finish reason, so the turn ends
  /// `toolUse` when any call was emitted.
  StopReason finishAll() {
    for (var position = 0; position < _order.length; position++) {
      final block = _blocks[_order[position]]!;
      block.finish();
      final partial = _turn.snapshot();
      final contentIndex = _contentIndex(position);
      _turn.eventStream.push(
        ToolCallEndEvent(
          contentIndex: contentIndex,
          toolCall: partial.content[contentIndex] as ToolCall,
          partial: partial,
        ),
      );
    }
    return _order.isEmpty ? StopReason.stop : StopReason.toolUse;
  }

  /// Synthesizes the id the plugin's id-less tool calls carry — the way
  /// the Google adapter does it.
  String _syntheticId(String? name) =>
      '${(name == null || name.isEmpty) ? 'call' : name}'
      '_${_turn.timestamp.millisecondsSinceEpoch}'
      '_${_counter++}';
}

/// Serializes harness [Tool]s to the OpenAI tools array the engine adapter
/// forwards to the plugin (mirrors `_convertTools` in the harness's OpenAI
/// adapter).
List<Map<String, dynamic>> convertGemmaTools(List<Tool> tools) {
  return [
    for (final tool in tools)
      {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
      },
  ];
}

/// Maps a harness [Context] to provider-neutral messages for the Gemma
/// engine — the shared on-device walk ([convertOnDeviceMessages]) with the
/// Gemma wire quirks ([_gemmaCodecProfile]).
///
/// The system prompt is NOT part of the output — it travels via
/// [GemmaEngineApi.chatStream]'s `systemInstruction` (the plugin renders it
/// natively through the LiteRT-LM conversation config).
///
/// User text passes through; image blocks degrade to an omission note
/// (Gemma 4 is multimodal, but this provider ships text-only — vision is a
/// deliberate follow-up). Assistant text passes through; thinking blocks
/// are dropped; historical tool calls become a `tool_call` message carrying
/// the OpenAI-style assistant JSON (the shape the plugin's own history
/// replay stores). Tool results become `tool_result` messages with
/// [GemmaChatMessage.toolName] set; the plugin renders them as
/// `<tool_response>` blocks.
List<GemmaChatMessage> convertGemmaMessages(Context context) {
  return [
    for (final message in convertOnDeviceMessages(context, _gemmaCodecProfile))
      (
        role: message.role,
        content: message.content,
        toolName: message.toolName,
      ),
  ];
}

/// The Gemma projection quirks (see [convertGemmaMessages]).
final _gemmaCodecProfile = OnDeviceCodecProfile(
  systemMessage: (_, _) => null,
  projectImages: (images) => (
    dataUris: const [],
    omissionNote: images.isEmpty
        ? null
        : '(attached image omitted: the Gemma provider is text-only '
              'in this build)',
  ),
  toolCallLine: (_) => null,
  extraAssistantMessages: (calls) {
    if (calls.isEmpty) return const [];
    return [
      (
        role: 'tool_call',
        content: jsonEncode({
          'role': 'assistant',
          'tool_calls': [
            for (final call in calls)
              {
                'type': 'function',
                'function': {
                  'name': call.name,
                  'arguments': jsonEncode(call.arguments),
                },
              },
          ],
        }),
        toolName: null,
        images: const [],
      ),
    ];
  },
  toolResultMessage: (result, resultText) => (
    role: 'tool_result',
    content: resultText,
    toolName: result.toolName,
    images: const [],
  ),
);

String _formatGemmaError(Object error) {
  final text = error is StateError ? error.message : error.toString();
  if (text.contains('too long') && text.contains('tokens')) {
    return "the conversation no longer fits the on-device model's context "
        'window — start a new session';
  }
  return text;
}

/// Heuristic chars-per-token matching the harness estimator (see
/// `token_estimation.dart`).
const _charsPerTokenEstimate = 4;

/// Fits [context] into the on-device KV budget (see
/// [GemmaModelPreset.contextWindow] — shared input+output, hard-failing
/// past it): the oldest messages drop first, the newest is truncated next,
/// and an oversized system prompt is hard-truncated last. [onNote] receives
/// one line per action taken (never silent about reduced context).
({String? systemPrompt, List<Message> messages}) _fitGemmaContext(
  Context context, {
  required int budgetTokens,
  required void Function(String note) onNote,
}) {
  final systemPrompt = context.systemPrompt ?? '';
  final systemTokens = systemPrompt.length ~/ _charsPerTokenEstimate;
  final toolsTokens = context.tools == null
      ? 0
      : jsonEncode(context.tools).length ~/ _charsPerTokenEstimate;
  var used = systemTokens + toolsTokens;
  var dropped = 0;
  final kept = <Message>[];
  // Newest first: the current turn always stays; older ones while they fit.
  for (final message in context.messages.reversed) {
    final tokens = estimateTokens(message);
    if (kept.isNotEmpty && used + tokens > budgetTokens) {
      dropped++;
      continue;
    }
    used += tokens;
    kept.insert(0, message);
  }
  var messages = kept;
  // The newest message alone still overruns: truncate its content so the
  // turn keeps its intent.
  if (used > budgetTokens && messages.isNotEmpty) {
    final last = messages.last;
    final spare = budgetTokens - (used - estimateTokens(last));
    if (spare > 64) {
      messages = [
        ...messages.sublist(0, messages.length - 1),
        _truncateGemmaMessage(last, spare),
      ];
      onNote('truncated the latest message to fit the on-device context');
    }
  }
  var fittedSystemPrompt = systemPrompt;
  if (systemTokens > budgetTokens) {
    fittedSystemPrompt =
        '${systemPrompt.substring(0, budgetTokens * _charsPerTokenEstimate)}…';
    onNote('truncated the system prompt to fit the on-device context');
  }
  if (dropped > 0) {
    onNote('dropped $dropped older message(s) to fit the on-device context');
  }
  return (systemPrompt: fittedSystemPrompt, messages: messages);
}

/// Hard-truncates the text content of [message] to [spareTokens] (ellipsis
/// marked), preserving its role and shape.
Message _truncateGemmaMessage(Message message, int spareTokens) {
  final spareChars = spareTokens * _charsPerTokenEstimate;
  String cut(String text) =>
      text.length <= spareChars ? text : '${text.substring(0, spareChars)}…';
  List<ContentBlock> cutBlocks(List<ContentBlock> blocks) => [
    for (final block in blocks)
      block is TextContent ? TextContent(text: cut(block.text)) : block,
  ];
  return switch (message) {
    UserMessage(content: final String text) => UserMessage(
      content: cut(text),
      timestamp: message.timestamp,
    ),
    UserMessage(content: final List<ContentBlock> blocks) => UserMessage(
      content: cutBlocks(blocks),
      timestamp: message.timestamp,
    ),
    ToolResultMessage() => ToolResultMessage(
      toolCallId: message.toolCallId,
      toolName: message.toolName,
      content: cutBlocks(message.content),
      isError: message.isError,
      timestamp: message.timestamp,
    ),
    AssistantMessage() => message.copyWith(content: cutBlocks(message.content)),
    _ => message,
  };
}
