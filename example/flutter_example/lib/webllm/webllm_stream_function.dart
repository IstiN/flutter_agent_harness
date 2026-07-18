// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Bridges the on-device WebLLM engine to the harness's provider contract.
///
/// Emits the same [AssistantMessageEvent] protocol as the HTTP provider
/// adapters (see `streamOpenAICompletions`): `StartEvent` → text
/// start/delta/end with partial-first snapshots → exactly one terminal
/// `DoneEvent` or `ErrorEvent`. **Errors-as-events is non-negotiable:** this
/// function never throws; engine/config failures and aborts terminate the
/// stream with an [ErrorEvent].
///
/// v1 scope decision (deliberate): **no tool calling**. `Context.tools` is
/// never forwarded to the engine; instead [webLlmNoToolsNote] is appended to
/// the system message so the model does not try to call tools it cannot
/// reach. The agent loop still works — it just gets plain-text answers.
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

Future<void> _runWebLlm(
  AssistantMessageEventStream eventStream,
  WebLlmEngineApi service,
  Model model,
  Context context,
  CancelToken? cancelToken,
) async {
  final timestamp = DateTime.now();
  final text = StringBuffer();
  var stopReason = StopReason.stop;
  String? errorMessage;

  // Partial-first invariant: every event carries a freshly built snapshot of
  // the message with ALL text accumulated so far (mirrors ProviderStreamState
  // in the HTTP adapters, which is package-internal).
  AssistantMessage snapshot() => AssistantMessage(
    content: [if (text.isNotEmpty) TextContent(text: text.toString())],
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

    // Model download/compile happens here on the very first turn (the
    // settings form pre-loads, so this is normally instant). A cancel during
    // the wait takes effect right after.
    await service.loadModel(preset);
    cancelToken?.throwIfCancelled();

    eventStream.push(StartEvent(partial: snapshot()));

    var textStarted = false;
    String? streamError;
    final done = Completer<void>();
    void Function()? cancelJsStream;

    void finish() {
      if (!done.isCompleted) done.complete();
    }

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
      messages: convertWebLlmMessages(context),
      maxTokens: model.maxTokens > 0 ? model.maxTokens : null,
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
    eventStream.push(DoneEvent(reason: StopReason.stop, message: snapshot()));
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

/// Maps a harness [Context] to plain-text OpenAI-style messages for WebLLM.
///
/// - `systemPrompt` becomes a `system` message; when tools are registered
///   they are NOT forwarded (v1: no tool calling) and [webLlmNoToolsNote] is
///   appended instead.
/// - User text passes through; image blocks degrade to an omission note
///   (the shipped presets are text-only).
/// - Assistant text passes through; thinking blocks are dropped; historical
///   tool calls become a `[tool call: ...]` text line so role alternation is
///   preserved.
/// - Tool results become `user` messages with a `[tool result]` header
///   (plain-text fallback — WebLLM is chat-template based and has no
///   `tool` role in v1).
List<WebLlmChatMessage> convertWebLlmMessages(Context context) {
  final messages = <WebLlmChatMessage>[];

  var system = context.systemPrompt ?? '';
  final tools = context.tools;
  if (tools != null && tools.isNotEmpty) {
    system = system.isEmpty
        ? webLlmNoToolsNote
        : '$system\n\n$webLlmNoToolsNote';
  }
  if (system.isNotEmpty) {
    messages.add((role: 'system', content: system));
  }

  for (final message in context.messages) {
    switch (message) {
      case UserMessage():
        final content = message.content;
        if (content is String) {
          if (content.trim().isNotEmpty) {
            messages.add((role: 'user', content: content));
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
            messages.add((role: 'user', content: parts.join('\n')));
          }
        }
      case AssistantMessage():
        final parts = <String>[
          for (final block in message.content)
            if (block is TextContent && block.text.trim().isNotEmpty)
              block.text,
        ];
        for (final block in message.content) {
          if (block is ToolCall) {
            parts.add(
              '[tool call: ${block.name}(${jsonEncode(block.arguments)})]',
            );
          }
        }
        if (parts.isNotEmpty) {
          messages.add((role: 'assistant', content: parts.join('\n')));
        }
      case ToolResultMessage():
        final resultText = message.content
            .whereType<TextContent>()
            .map((block) => block.text)
            .join('\n');
        messages.add((
          role: 'user',
          content:
              '[tool result · ${message.toolName}'
              '${message.isError ? ' · error' : ''}]\n'
              '${resultText.isEmpty ? '(no output)' : resultText}',
        ));
    }
  }
  return messages;
}

String _formatWebLlmError(Object error) {
  if (error is StateError) return error.message;
  return error.toString();
}
