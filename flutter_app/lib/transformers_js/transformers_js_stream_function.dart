// Copyright (c) 2026, the Flutter Agent Harness authors.
// Use of this source code is governed by a MIT license that can be found
// in the LICENSE file.

/// Bridges the on-device transformers.js engine (Gemma 4 ONNX via
/// `@huggingface/transformers` + onnxruntime-web) to the harness's provider
/// contract.
///
/// Emits the same [AssistantMessageEvent] protocol as the HTTP provider
/// adapters (see `streamOpenAICompletions`): `StartEvent` → text deltas with
/// partial-first snapshots → exactly one terminal `DoneEvent` or
/// `ErrorEvent`. **Errors-as-events is non-negotiable:** this function never
/// throws; engine/config failures and aborts terminate the stream with an
/// [ErrorEvent].
///
/// The engine runs chat-only. Gemma's native function-calling tokens are not
/// used: tool calling goes through the harness's universal prompt-tools
/// wrapper instead — [transformersJsStreamFunction] wraps the plain chat
/// stream with `promptToolStreamFunction`, which appends the tool
/// instructions to the system prompt and parses fenced `tool_call` blocks
/// out of the text stream into the harness tool-call event contract
/// ([ToolCallStartEvent] → [ToolCallDeltaEvent] → [ToolCallEndEvent],
/// [StopReason.toolUse]).
///
/// When `Context.tools` is empty the wrapper is a byte-identical
/// passthrough; [transformersJsNoToolsNote] is then appended to the system
/// message so the model does not try to call tools that are not there.
///
/// Usage accounting: the engine reports no token counts, so every message
/// carries [Usage.zero] (documented on the DoneEvent).
///
/// GPU-crash recovery: a WebGPU/ORT crash class ([isTransformersJsGpuCrash]
/// — `OrtRun` failures, the `mapAsync ... invalid Buffer` cascade a lost GPU
/// device produces, out-of-memory) poisons the engine, so a failure before
/// any text was streamed triggers ONE engine dispose + reload + retry per
/// turn (capped by a counter — a GPU that cannot fit the model must not
/// cause a reload loop). An unrecovered crash surfaces as
/// [transformersJsGpuCrashMessage] (the raw native dump stays in the console
/// log), and the engine is unloaded so the next turn reloads from the cached
/// weights rather than inheriting the broken state.
library;

import 'dart:async';

import 'package:fa/on_device/on_device_message_codec.dart';
import 'package:fa/on_device/on_device_stream_pump.dart';
import 'package:fa/prompts.g.dart';
import 'package:fa/services/upload.dart';
import 'package:fa/transformers_js/transformers_js_types.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

/// Builds a [StreamFunction] that runs inference through [service], with
/// tool calling provided by the universal prompt-tools wrapper (see the
/// library docstring).
///
/// The model id in [Model.id] must be one of [transformersJsModelPresets];
/// unknown ids produce an [ErrorEvent], never a throw.
/// On-device models have small context windows, so tool instructions are
/// emitted in the compact slim format.
StreamFunction transformersJsStreamFunction(TransformersJsEngineApi service) {
  return promptToolStreamFunction(
    (model, context, {cancelToken}) =>
        streamTransformersJs(service, model, context, cancelToken: cancelToken),
    options: const PromptToolOptions(slim: true),
  );
}

/// Streams one assistant message from the on-device engine (plain chat — the
/// inner half of [transformersJsStreamFunction]). See the library docstring
/// for the event contract.
AssistantMessageEventStream streamTransformersJs(
  TransformersJsEngineApi service,
  Model model,
  Context context, {
  CancelToken? cancelToken,
}) {
  final eventStream = AssistantMessageEventStream();
  unawaited(
    _runTransformersJs(eventStream, service, model, context, cancelToken),
  );
  return eventStream;
}

Future<void> _runTransformersJs(
  AssistantMessageEventStream eventStream,
  TransformersJsEngineApi service,
  Model model,
  Context context,
  CancelToken? cancelToken,
) async {
  // Set once the engine has loaded the model: only then can a failure be
  // an ORT session poisoning that requires an engine reset.
  var engineEngaged = false;

  // GPU-crash recovery budget: ONE engine dispose + reload + retry per turn
  // ([isTransformersJsGpuCrash] failures only). The counter caps reload
  // loops — a GPU that genuinely cannot fit the model fails the retry too,
  // and the error then surfaces instead of reloading forever.
  var recoveryAttempts = 0;

  final turn = OnDeviceStreamTurn(
    eventStream: eventStream,
    model: model,
    formatError: _formatTransformersJsError,
    formatUserError: formatTransformersJsErrorForUser,
    beforeErrorEvent: (aborted) async {
      if (aborted || !engineEngaged) return;
      // A failed generate can leave the ORT session poisoned (the WebGPU
      // invalid-buffer OrtRun error an undecodable image input causes):
      // drop the engine so the NEXT message reloads from the cached
      // weights instead of inheriting the broken state. Best effort.
      try {
        await service.unloadModel();
      } on Object {
        // Recovery must never mask the original error.
      }
    },
  );

  try {
    while (true) {
      try {
        cancelToken?.throwIfCancelled();

        final preset = findTransformersJsPreset(model.id);
        if (preset == null) {
          throw StateError(
            'Unknown transformers.js model preset: ${model.id}. Pick one '
            'of: ${transformersJsModelPresets.map((p) => p.id).join(', ')}',
          );
        }

        // Model download/compile happens here on the very first turn (the
        // settings form pre-loads, so this is normally instant). A cancel
        // during the wait takes effect right after.
        await service.loadModel(preset);
        engineEngaged = true;
        cancelToken?.throwIfCancelled();

        turn.pushStart();

        final call = await pumpOnDeviceChat(
          turn: turn,
          cancelToken: cancelToken,
          interrupt: service.interrupt,
          startChat: (call) async {
            call.cancelJs = await service.chatStream(
              messages: convertTransformersJsMessages(
                context,
                supportsVision: preset.supportsVision,
              ),
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
        return;
      } catch (error) {
        final aborted =
            error is CancelledException || (cancelToken?.isCancelled ?? false);
        // A GPU crash poisons the ORT session (and possibly the WebGPU
        // device): dispose the engine and retry ONCE against a freshly
        // reloaded model before surfacing anything to the user. Only
        // pre-text failures retry — after the first delta the events are
        // already out and a retry would stream the answer twice.
        if (!aborted &&
            engineEngaged &&
            !turn.hasText &&
            recoveryAttempts < _maxRecoveryAttemptsPerTurn &&
            isTransformersJsGpuCrash(_formatTransformersJsError(error))) {
          recoveryAttempts++;
          debugPrint(
            'transformers.js: GPU crash — reloading the engine and retrying '
            '($recoveryAttempts/$_maxRecoveryAttemptsPerTurn). '
            'Raw error: ${_formatTransformersJsError(error)}',
          );
          try {
            await service.unloadModel();
          } on Object {
            // Recovery must never mask the original error.
          }
          continue;
        }
        await turn.fail(error, cancelToken: cancelToken);
        return;
      }
    }
  } finally {
    turn.end();
  }
}

/// The transformers.js projection quirks: a system message (carrying
/// [transformersJsNoToolsNote] when the context has no tools — with tools
/// present the wrapper already appended the tool instructions upstream),
/// vision images as decodable `data:` URIs ([isInlineImageMimeType]:
/// PNG, JPEG, GIF, WebP — feeding undecodable bytes to `RawImage` kills
/// the ONNX Runtime WebGPU session, `mapAsync ... invalid Buffer`), inline
/// `[tool call: …]` history lines, and `[tool result]` user headers (the
/// chat template has no tool role).
OnDeviceCodecProfile _transformersJsCodecProfile({
  required bool supportsVision,
}) => OnDeviceCodecProfile(
  systemMessage: (system, hasTools) {
    var text = system;
    if (!hasTools) {
      text = text.isEmpty
          ? transformersJsNoToolsNote
          : '$text\n\n$transformersJsNoToolsNote';
    }
    if (text.isEmpty) return null;
    return (role: 'system', content: text, toolName: null, images: const []);
  },
  projectImages: (images) {
    final decodable = <ImageContent>[
      if (supportsVision)
        for (final block in images)
          if (isInlineImageMimeType(block.mimeType)) block,
    ];
    final omitted = images.length - decodable.length;
    return (
      dataUris: [
        for (final block in decodable)
          'data:${block.mimeType};base64,${block.data}',
      ],
      omissionNote: omitted == 0
          ? null
          : supportsVision
          ? '(attached image omitted: format not decodable on-device)'
          : '(attached image omitted: this model is text-only)',
    );
  },
  toolCallLine: onDeviceToolCallLine,
  extraAssistantMessages: (_) => const [],
  toolResultMessage: (result, resultText) => (
    role: 'user',
    content: '${onDeviceToolResultHeader(result)}\n$resultText',
    toolName: null,
    images: const [],
  ),
);

/// Maps a harness [Context] to chat messages for the transformers.js
/// engine — the shared on-device walk ([convertOnDeviceMessages]) with the
/// transformers.js wire quirks ([_transformersJsCodecProfile]).
List<TransformersJsChatMessage> convertTransformersJsMessages(
  Context context, {
  required bool supportsVision,
}) {
  return [
    for (final message in convertOnDeviceMessages(
      context,
      _transformersJsCodecProfile(supportsVision: supportsVision),
    ))
      (role: message.role, content: message.content, images: message.images),
  ];
}

String _formatTransformersJsError(Object error) {
  if (error is StateError) return error.message;
  return error.toString();
}

/// Engine-dispose + reload + retry budget per turn for the GPU-crash class
/// (see [isTransformersJsGpuCrash]). One retry recovers a transiently
/// poisoned ORT session without the user doing anything; a deterministic
/// crash (a GPU that cannot fit the model) fails the retry as well, and the
/// counter keeps that from becoming a reload loop.
const _maxRecoveryAttemptsPerTurn = 1;

/// Whether [message] is the raw dump of a GPU-crash-class engine failure:
/// ORT's `OrtRun` errors, the `mapAsync ... invalid Buffer` cascade a lost
/// or errored WebGPU device produces (the buffer dies "due to a previous
/// error" — the crash itself happened earlier), the
/// `onnxruntime::webgpu::BufferManager` failures that cascade from it,
/// device-lost reports, and outright out-of-memory failures.
///
/// This class gets the automatic reload + retry ([_maxRecoveryAttemptsPerTurn])
/// and maps to [transformersJsGpuCrashMessage] for the user instead of the
/// native dump. Deliberately narrower than "any engine error": a chat
/// template or input-shape error is deterministic, so retrying it would
/// only cost a reload.
bool isTransformersJsGpuCrash(String message) =>
    _gpuCrashPattern.hasMatch(message);

final _gpuCrashPattern = RegExp(
  'ortrun|mapasync|invalid buffer|gpubuffer|buffermanager|device lost|'
  'device was lost|device_lost|device_removed|out of memory',
  caseSensitive: false,
);

/// The user-facing text for the GPU-crash class ([isTransformersJsGpuCrash]).
/// The raw engine dump goes to the console instead; this says what happened
/// and what to do, in order of escalating effort.
const transformersJsGpuCrashMessage =
    'The on-device model crashed (the GPU ran out of memory or the WebGPU '
    'device was lost). The model was reset — send your message again. If it '
    'keeps crashing, reload the page or pick a smaller model.';

/// Maps a raw engine error message to the text shown to the user: the
/// GPU-crash class becomes [transformersJsGpuCrashMessage] with the raw dump
/// kept in the console log; everything else passes through unchanged.
String formatTransformersJsErrorForUser(String rawMessage) {
  if (!isTransformersJsGpuCrash(rawMessage)) return rawMessage;
  debugPrint('transformers.js engine error (raw): $rawMessage');
  return transformersJsGpuCrashMessage;
}
