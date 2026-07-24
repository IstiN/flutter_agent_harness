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

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import 'gemma_types.dart';

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
  final timestamp = DateTime.now();
  final text = StringBuffer();
  final toolBlocks = <int, _GemmaToolCallBlock>{};
  final toolBlockOrder = <int>[];
  var toolCallCounter = 0;
  var stopReason = StopReason.stop;
  String? errorMessage;

  // Partial-first invariant: every event carries a freshly built snapshot of
  // the message with ALL content accumulated so far (mirrors
  // ProviderStreamState in the HTTP adapters, which is package-internal).
  AssistantMessage snapshot() => AssistantMessage(
    content: [
      if (text.isNotEmpty) TextContent(text: text.toString()),
      for (final key in toolBlockOrder) toolBlocks[key]!.toToolCall(),
    ],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: timestamp,
  );

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

    // The engine's KV budget (preset.contextWindow) is shared by input and
    // output and hard-fails past it (INVALID_ARGUMENT) — fit the context
    // instead of ever going there.
    final outputReserve = model.maxTokens > 0 ? model.maxTokens : 256;
    final fitted = _fitGemmaContext(
      context,
      budgetTokens: preset.contextWindow - outputReserve - 64,
      onNote: (note) => debugPrint('[gemma] $note'),
    );

    eventStream.push(StartEvent(partial: snapshot()));

    var textStarted = false;
    String? streamError;
    final done = Completer<void>();

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    // Tool blocks live after the text block when one exists.
    int toolContentIndex(int orderPosition) =>
        (textStarted ? 1 : 0) + orderPosition;

    if (cancelToken != null) {
      unawaited(
        cancelToken.onCancel.then((_) {
          unawaited(service.interrupt());
          finish();
        }),
      );
    }

    await service.chatStream(
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
      onChunk: (chunk) {
        if (chunk.isEmpty) return;
        if (!textStarted) {
          textStarted = true;
          eventStream.push(
            TextStartEvent(contentIndex: 0, partial: snapshot()),
          );
        }
        text.write(chunk);
        eventStream.push(
          TextDeltaEvent(contentIndex: 0, delta: chunk, partial: snapshot()),
        );
      },
      onToolCalls: (toolCallsJson) {
        final decoded = jsonDecode(toolCallsJson);
        if (decoded is! List) return;
        for (final entry in decoded) {
          if (entry is! Map) continue;
          final index = entry['index'];
          final key = index is int ? index : toolBlockOrder.length;
          var block = toolBlocks[key];
          if (block == null) {
            final function = entry['function'];
            final name = function is Map ? function['name'] as String? : null;
            block = _GemmaToolCallBlock(
              // The plugin's tool calls carry no id; synthesize one the way
              // the Google adapter does for id-less calls.
              '${(name == null || name.isEmpty) ? 'call' : name}'
              '_${timestamp.millisecondsSinceEpoch}'
              '_${toolCallCounter++}',
            );
            toolBlocks[key] = block;
            toolBlockOrder.add(key);
            eventStream.push(
              ToolCallStartEvent(
                contentIndex: toolContentIndex(toolBlockOrder.length - 1),
                partial: snapshot(),
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
            eventStream.push(
              ToolCallDeltaEvent(
                contentIndex: toolContentIndex(toolBlockOrder.indexOf(key)),
                delta: arguments,
                partial: snapshot(),
              ),
            );
          }
        }
      },
      onError: (message) {
        streamError = message;
        finish();
      },
      onDone: finish,
    );

    await done.future;

    if (streamError != null) {
      throw StateError(streamError!);
    }
    cancelToken?.throwIfCancelled();

    if (textStarted) {
      eventStream.push(
        TextEndEvent(
          contentIndex: 0,
          content: text.toString(),
          partial: snapshot(),
        ),
      );
    }
    for (var position = 0; position < toolBlockOrder.length; position++) {
      final block = toolBlocks[toolBlockOrder[position]]!;
      block.finish();
      final partial = snapshot();
      final contentIndex = toolContentIndex(position);
      eventStream.push(
        ToolCallEndEvent(
          contentIndex: contentIndex,
          toolCall: partial.content[contentIndex] as ToolCall,
          partial: partial,
        ),
      );
    }

    if (toolBlockOrder.isNotEmpty) {
      stopReason = StopReason.toolUse;
    }
    eventStream.push(DoneEvent(reason: stopReason, message: snapshot()));
  } catch (error) {
    final aborted =
        error is CancelledException || (cancelToken?.isCancelled ?? false);
    stopReason = aborted ? StopReason.aborted : StopReason.error;
    errorMessage = aborted ? 'Request was aborted' : _formatGemmaError(error);
    eventStream.push(ErrorEvent(reason: stopReason, error: snapshot()));
  } finally {
    eventStream.end();
  }
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
/// engine.
///
/// The system prompt is NOT part of the output — it travels via
/// [GemmaEngineApi.chatStream]'s `systemInstruction` (the plugin renders it
/// natively through the LiteRT-LM conversation config).
///
/// - User text passes through; image blocks degrade to an omission note
///   (Gemma 4 is multimodal, but this provider ships text-only — vision is
///   a deliberate follow-up).
/// - Assistant text passes through; thinking blocks are dropped; historical
///   tool calls become a `tool_call` message carrying the OpenAI-style
///   assistant JSON (the shape the plugin's own history replay stores).
/// - Tool results become `tool_result` messages with [GemmaChatMessage
///   .toolName] set; the plugin renders them as `<tool_response>` blocks.
List<GemmaChatMessage> convertGemmaMessages(Context context) {
  final messages = <GemmaChatMessage>[];

  for (final message in context.messages) {
    switch (message) {
      case UserMessage():
        final content = message.content;
        if (content is String) {
          if (content.trim().isNotEmpty) {
            messages.add((role: 'user', content: content, toolName: null));
          }
        } else {
          final blocks = content as List<ContentBlock>;
          final parts = <String>[
            for (final block in blocks)
              if (block is TextContent && block.text.trim().isNotEmpty)
                block.text,
          ];
          if (blocks.any((block) => block is ImageContent)) {
            parts.add(
              '(attached image omitted: the Gemma provider is text-only '
              'in this build)',
            );
          }
          if (parts.isNotEmpty) {
            messages.add((
              role: 'user',
              content: parts.join('\n'),
              toolName: null,
            ));
          }
        }
      case AssistantMessage():
        final parts = <String>[
          for (final block in message.content)
            if (block is TextContent && block.text.trim().isNotEmpty)
              block.text,
        ];
        if (parts.isNotEmpty) {
          messages.add((
            role: 'assistant',
            content: parts.join('\n'),
            toolName: null,
          ));
        }
        final toolCalls = [
          for (final block in message.content)
            if (block is ToolCall) block,
        ];
        if (toolCalls.isNotEmpty) {
          // The shape the LiteRT-LM SDK produces for tool-call turns (and
          // the plugin's own history replay stores): an OpenAI-style
          // assistant message with a tool_calls array.
          messages.add((
            role: 'tool_call',
            content: jsonEncode({
              'role': 'assistant',
              'tool_calls': [
                for (final call in toolCalls)
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
          ));
        }
      case ToolResultMessage():
        final resultText = message.content
            .whereType<TextContent>()
            .map((block) => block.text)
            .join('\n');
        messages.add((
          role: 'tool_result',
          content: resultText.isEmpty ? '(no output)' : resultText,
          toolName: message.toolName,
        ));
    }
  }
  return messages;
}

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
