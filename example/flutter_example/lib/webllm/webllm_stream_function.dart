// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Bridges the on-device WebLLM engine to the harness's provider contract.
///
/// Emits the same [AssistantMessageEvent] protocol as the HTTP provider
/// adapters (see `streamOpenAICompletions`): `StartEvent` → text and/or
/// tool-call start/delta/end with partial-first snapshots → exactly one
/// terminal `DoneEvent` or `ErrorEvent`. **Errors-as-events is
/// non-negotiable:** this function never throws; engine/config failures and
/// aborts terminate the stream with an [ErrorEvent].
///
/// Tool calling is gated on [WebLlmModelPreset.supportsTools] (the model ids
/// in web-llm's `functionCallingModelIds` — Hermes presets only). With a
/// tool-capable preset and a non-empty `Context.tools`, the OpenAI tools
/// array goes to the engine and streamed `tool_calls` become
/// [ToolCallStartEvent]/[ToolCallDeltaEvent]/[ToolCallEndEvent]s, mirroring
/// `streamOpenAICompletions`. WebLLM delivers tool calls complete in the
/// final stream chunk (the raw JSON array it constrains the model to is
/// suppressed from the visible text), so each call gets a single delta
/// carrying the full arguments JSON — the same event sequence an
/// OpenAI-compatible server produces when it does not fragment deltas.
///
/// With any other preset, `Context.tools` is never forwarded; instead
/// [webLlmNoToolsNote] is appended to the system message so the model does
/// not try to call tools it cannot reach. The agent loop still works — it
/// just gets plain-text answers.
///
/// Usage accounting: WebLLM reports no token counts, so every message
/// carries [Usage.zero] (documented on the DoneEvent).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../prompts.g.dart';
import 'webllm_types.dart';

/// Builds a [StreamFunction] that runs inference through [service].
///
/// The model id in [Model.id] must be one of [webLlmModelPresets]; unknown
/// ids produce an [ErrorEvent], never a throw.
StreamFunction webLlmStreamFunction(WebLlmEngineApi service) {
  return (model, context, {cancelToken}) =>
      streamWebLlm(service, model, context, cancelToken: cancelToken);
}

/// Streams one assistant message from the on-device engine. See the library
/// docstring for the event contract.
AssistantMessageEventStream streamWebLlm(
  WebLlmEngineApi service,
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final eventStream = AssistantMessageEventStream();
  unawaited(_runWebLlm(eventStream, service, model, context, cancelToken));
  return eventStream;
}

/// Accumulating state for one streamed tool call (WebLLM emits the complete
/// call in one chunk; the shape mirrors `ToolCallStreamingBlock` in the
/// harness's HTTP adapters, which is package-internal).
final class _WebLlmToolCallBlock {
  _WebLlmToolCallBlock(this.id);

  /// Synthesized tool call id (WebLLM's streaming `tool_calls` carry none).
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
    arguments = _parseWebLlmToolArgs(partialArgs.toString());
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

/// Parses WebLLM's `function.arguments` (a JSON string produced by
/// `JSON.stringify` on the engine side). Falls back to an empty map on
/// malformed JSON — in practice unreachable, since the engine stringifies an
/// already-parsed object.
Map<String, dynamic> _parseWebLlmToolArgs(String jsonText) {
  try {
    final decoded = jsonDecode(jsonText);
    if (decoded is Map<String, dynamic>) return decoded;
  } on FormatException {
    // Fall through to the empty map.
  }
  return const <String, dynamic>{};
}

Future<void> _runWebLlm(
  AssistantMessageEventStream eventStream,
  WebLlmEngineApi service,
  Model model,
  Context context,
  CancelToken? cancelToken,
) async {
  final timestamp = DateTime.now();
  final text = StringBuffer();
  final toolBlocks = <int, _WebLlmToolCallBlock>{};
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

    final preset = findWebLlmPreset(model.id);
    if (preset == null) {
      throw StateError(
        'Unknown WebLLM model preset: ${model.id}. Pick one of: '
        '${webLlmModelPresets.map((p) => p.id).join(', ')}',
      );
    }

    // Function calling is only wired up for presets web-llm itself lists in
    // functionCallingModelIds — the engine rejects `tools` for anything else
    // (UnsupportedModelIdError), so gating here is non-negotiable.
    final toolsMode =
        preset.supportsTools && (context.tools?.isNotEmpty ?? false);

    // Model download/compile happens here on the very first turn (the
    // settings form pre-loads, so this is normally instant). A cancel during
    // the wait takes effect right after.
    await service.loadModel(preset);
    cancelToken?.throwIfCancelled();

    eventStream.push(StartEvent(partial: snapshot()));

    var textStarted = false;
    var finishReason = '';
    String? streamError;
    final done = Completer<void>();
    void Function()? cancelJsStream;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

    // Tool blocks live after the text block when one exists (in tools mode
    // the raw JSON text is suppressed, so this is normally 0).
    int toolContentIndex(int orderPosition) =>
        (textStarted ? 1 : 0) + orderPosition;

    if (cancelToken != null) {
      unawaited(
        cancelToken.onCancel.then((_) {
          unawaited(service.interrupt());
          try {
            cancelJsStream?.call();
          } catch (_) {
            // Best effort: interruptGenerate above is the authoritative stop.
          }
          finish();
        }),
      );
    }

    cancelJsStream = await service.chatStream(
      messages: convertWebLlmMessages(context, toolsMode: toolsMode),
      tools: toolsMode ? convertWebLlmTools(context.tools!) : null,
      maxTokens: model.maxTokens > 0 ? model.maxTokens : null,
      onChunk: (chunk) {
        if (chunk.isEmpty) return;
        // In tools mode the model's raw output is the tool-call JSON array
        // (grammar-constrained); it is surfaced via onToolCalls instead and
        // must never leak into the visible text.
        if (toolsMode) return;
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
            block = _WebLlmToolCallBlock(
              // WebLLM's streaming tool_calls carry no id; synthesize one the
              // way the Google adapter does for id-less calls.
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
      onDone: (reason) {
        finishReason = reason;
        finish();
      },
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
    } else if (finishReason == 'length') {
      stopReason = StopReason.length;
    }
    eventStream.push(DoneEvent(reason: stopReason, message: snapshot()));
  } catch (error) {
    final aborted =
        error is CancelledException || (cancelToken?.isCancelled ?? false);
    stopReason = aborted ? StopReason.aborted : StopReason.error;
    errorMessage = aborted ? 'Request was aborted' : _formatWebLlmError(error);
    eventStream.push(ErrorEvent(reason: stopReason, error: snapshot()));
  } finally {
    eventStream.end();
  }
}

/// Serializes harness [Tool]s to the OpenAI tools array WebLLM's
/// `chatCompletion` expects (mirrors `_convertTools` in the harness's OpenAI
/// adapter, minus `strict` — web-llm embeds this JSON verbatim into the
/// Hermes function-calling system prompt, so extra keys only burn context).
List<Map<String, dynamic>> convertWebLlmTools(List<Tool> tools) {
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

/// Maps a harness [Context] to OpenAI-style messages for WebLLM.
///
/// With [toolsMode] off (default, used for presets without function
/// calling):
/// - `systemPrompt` becomes a `system` message; when tools are registered
///   they are NOT forwarded and [webLlmNoToolsNote] is appended instead.
/// - User text passes through; image blocks degrade to an omission note
///   (the shipped presets are text-only).
/// - Assistant text passes through; thinking blocks are dropped; historical
///   tool calls become a `[tool call: ...]` text line so role alternation is
///   preserved.
/// - Tool results become `user` messages with a `[tool result]` header
///   (plain-text fallback — non-function-calling templates have no `tool`
///   role).
///
/// With [toolsMode] on (function-calling presets):
/// - **No `system` message is sent at all.** WebLLM's Hermes function-calling
///   handling injects its own tool-calling system prompt and throws
///   (`CustomSystemPromptError`) when the request carries a system message.
/// - Historical tool calls serialize as the raw JSON array the model itself
///   produced (`[{"name": ..., "arguments": {...}}]`) — WebLLM requires
///   assistant content to be a plain string and rejects OpenAI-style
///   `tool_calls` arrays in history.
/// - Tool results become `tool` messages carrying the result text and
///   [WebLlmChatMessage.toolCallId].
List<WebLlmChatMessage> convertWebLlmMessages(
  Context context, {
  bool toolsMode = false,
}) {
  final messages = <WebLlmChatMessage>[];

  if (!toolsMode) {
    var system = context.systemPrompt ?? '';
    final tools = context.tools;
    if (tools != null && tools.isNotEmpty) {
      system = system.isEmpty
          ? webLlmNoToolsNote
          : '$system\n\n$webLlmNoToolsNote';
    }
    if (system.isNotEmpty) {
      messages.add((role: 'system', content: system, toolCallId: null));
    }
  }

  for (final message in context.messages) {
    switch (message) {
      case UserMessage():
        final content = message.content;
        if (content is String) {
          if (content.trim().isNotEmpty) {
            messages.add((role: 'user', content: content, toolCallId: null));
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
              '(attached image omitted: on-device models are text-only)',
            );
          }
          if (parts.isNotEmpty) {
            messages.add((
              role: 'user',
              content: parts.join('\n'),
              toolCallId: null,
            ));
          }
        }
      case AssistantMessage():
        final parts = <String>[
          for (final block in message.content)
            if (block is TextContent && block.text.trim().isNotEmpty)
              block.text,
        ];
        final toolCalls = [
          for (final block in message.content)
            if (block is ToolCall) block,
        ];
        if (toolsMode) {
          if (toolCalls.isNotEmpty) {
            // The model's own raw output format (what web-llm's grammar
            // constrained it to): a JSON array of {name, arguments}.
            parts.add(
              jsonEncode([
                for (final call in toolCalls)
                  {'name': call.name, 'arguments': call.arguments},
              ]),
            );
          }
        } else {
          for (final call in toolCalls) {
            parts.add(
              '[tool call: ${call.name}(${jsonEncode(call.arguments)})]',
            );
          }
        }
        if (parts.isNotEmpty) {
          messages.add((
            role: 'assistant',
            content: parts.join('\n'),
            toolCallId: null,
          ));
        }
      case ToolResultMessage():
        final resultText = message.content
            .whereType<TextContent>()
            .map((block) => block.text)
            .join('\n');
        if (toolsMode) {
          messages.add((
            role: 'tool',
            content: resultText.isEmpty ? '(no output)' : resultText,
            toolCallId: message.toolCallId,
          ));
        } else {
          messages.add((
            role: 'user',
            content:
                '[tool result · ${message.toolName}'
                '${message.isError ? ' · error' : ''}]\n'
                '${resultText.isEmpty ? '(no output)' : resultText}',
            toolCallId: null,
          ));
        }
    }
  }
  return messages;
}

String _formatWebLlmError(Object error) {
  if (error is StateError) return error.message;
  return error.toString();
}
