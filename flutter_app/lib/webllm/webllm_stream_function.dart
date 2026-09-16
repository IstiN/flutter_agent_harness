// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Bridges the on-device WebLLM engine to the harness's provider contract.
///
/// Emits the same [AssistantMessageEvent] protocol as the HTTP provider
/// adapters (see `streamOpenAICompletions`): `StartEvent` → text deltas with
/// partial-first snapshots → exactly one terminal `DoneEvent` or
/// `ErrorEvent`. **Errors-as-events is non-negotiable:** this function never
/// throws; engine/config failures and aborts terminate the stream with an
/// [ErrorEvent].
///
/// WebLLM runs chat-only. The engine's native function calling was removed:
/// web-llm's FC mode (Hermes presets only) forces JSON-only output so the
/// model loops on tool calls, and it rejects a custom system prompt
/// (`CustomSystemPromptError`) — the Fa identity would never reach the
/// model. Tool calling goes through the harness's universal prompt-tools
/// wrapper instead: [webLlmStreamFunction] wraps the plain chat stream with
/// `promptToolStreamFunction`, which appends the tool instructions to the
/// system prompt and parses fenced `tool_call` blocks out of the text
/// stream into the harness tool-call event contract
/// ([ToolCallStartEvent] → [ToolCallDeltaEvent] → [ToolCallEndEvent],
/// [StopReason.toolUse]).
///
/// When `Context.tools` is empty the wrapper is a byte-identical
/// passthrough; [webLlmNoToolsNote] is then appended to the system message
/// so the model does not try to call tools that are not there.
///
/// Usage accounting: WebLLM reports no token counts, so every message
/// carries [Usage.zero] (documented on the DoneEvent).
library;

import 'dart:async';

import 'package:fa/on_device/on_device_message_codec.dart';
import 'package:fa/on_device/on_device_stream_pump.dart';
import 'package:fa/prompts.g.dart';
import 'package:fa/webllm/webllm_types.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Builds a [StreamFunction] that runs inference through [service], with
/// tool calling provided by the universal prompt-tools wrapper (see the
/// library docstring).
///
/// The model id in [Model.id] must be one of [webLlmModelPresets]; unknown
/// ids produce an [ErrorEvent], never a throw.
/// On-device models have small context windows, so tool instructions are
/// emitted in the compact slim format.
StreamFunction webLlmStreamFunction(WebLlmEngineApi service) {
  return promptToolStreamFunction(
    (model, context, {cancelToken}) =>
        streamWebLlm(service, model, context, cancelToken: cancelToken),
    options: const PromptToolOptions(slim: true),
  );
}

/// Streams one assistant message from the on-device engine (plain chat — the
/// inner half of [webLlmStreamFunction]). See the library docstring for the
/// event contract.
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
  final turn = OnDeviceStreamTurn(
    eventStream: eventStream,
    model: model,
    formatError: _formatWebLlmError,
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

    turn.pushStart();

    final call = await pumpOnDeviceChat(
      turn: turn,
      cancelToken: cancelToken,
      interrupt: service.interrupt,
      startChat: (call) async {
        call.cancelJs = await service.chatStream(
          messages: convertWebLlmMessages(context),
          maxTokens: model.maxTokens > 0 ? model.maxTokens : null,
          onChunk: turn.pushTextDelta,
          onError: (message) {
            call.streamError = message;
            call.complete();
          },
          onDone: (reason) {
            call.finishReason = reason;
            call.complete();
          },
        );
      },
    );

    if (call.streamError != null) {
      throw StateError(call.streamError!);
    }
    cancelToken?.throwIfCancelled();

    turn.pushTextEnd();
    turn.pushDone(
      call.finishReason == 'length' ? StopReason.length : StopReason.stop,
    );
  } catch (error) {
    await turn.fail(error, cancelToken: cancelToken);
  } finally {
    turn.end();
  }
}

/// Maps a harness [Context] to OpenAI-style messages for WebLLM — the
/// shared on-device walk ([convertOnDeviceMessages]) with the WebLLM wire
/// quirks ([_webLlmCodecProfile]): a system message (carrying
/// [webLlmNoToolsNote] when the context has no tools — with tools present
/// the wrapper already appended the tool instructions upstream), text-only
/// images, inline `[tool call: …]` history lines, and `[tool result]` user
/// headers (the chat template has no tool role).
List<WebLlmChatMessage> convertWebLlmMessages(Context context) {
  return [
    for (final message in convertOnDeviceMessages(context, _webLlmCodecProfile))
      (role: message.role, content: message.content),
  ];
}

/// The WebLLM projection quirks (see [convertWebLlmMessages]).
final _webLlmCodecProfile = OnDeviceCodecProfile(
  systemMessage: (system, hasTools) {
    var text = system;
    if (!hasTools) {
      text = text.isEmpty ? webLlmNoToolsNote : '$text\n\n$webLlmNoToolsNote';
    }
    if (text.isEmpty) return null;
    return (role: 'system', content: text, toolName: null, images: const []);
  },
  projectImages: (images) => (
    dataUris: const [],
    omissionNote: images.isEmpty
        ? null
        : '(attached image omitted: on-device models are text-only)',
  ),
  toolCallLine: onDeviceToolCallLine,
  extraAssistantMessages: (_) => const [],
  toolResultMessage: (result, resultText) => (
    role: 'user',
    content: '${onDeviceToolResultHeader(result)}\n$resultText',
    toolName: null,
    images: const [],
  ),
);

String _formatWebLlmError(Object error) {
  if (error is StateError) return error.message;
  return error.toString();
}
