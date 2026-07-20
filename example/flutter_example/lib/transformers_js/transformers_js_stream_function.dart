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
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_agent_harness/flutter_agent_harness.dart';

import '../prompts.g.dart';
import '../upload.dart';
import 'transformers_js_types.dart';

/// Builds a [StreamFunction] that runs inference through [service], with
/// tool calling provided by the universal prompt-tools wrapper (see the
/// library docstring).
///
/// The model id in [Model.id] must be one of [transformersJsModelPresets];
/// unknown ids produce an [ErrorEvent], never a throw.
StreamFunction transformersJsStreamFunction(TransformersJsEngineApi service) {
  return promptToolStreamFunction(
    (model, context, {cancelToken}) =>
        streamTransformersJs(service, model, context, cancelToken: cancelToken),
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
  final timestamp = DateTime.now();
  final text = StringBuffer();
  var stopReason = StopReason.stop;
  String? errorMessage;
  // Set once the engine has loaded the model: only then can a failure be
  // an ORT session poisoning that requires an engine reset.
  var engineEngaged = false;
  var textStarted = false;
  var startPushed = false;

  // Partial-first invariant: every event carries a freshly built snapshot of
  // the message with ALL content accumulated so far (mirrors
  // ProviderStreamState in the HTTP adapters, which is package-internal).
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

  // Cancellation acts on whichever generation is in flight; the listener is
  // registered once (after the first successful load) and the holders are
  // swapped per attempt, so a recovery retry stays cancellable.
  Completer<void>? activeDone;
  void Function()? activeCancelJs;
  var cancelHooked = false;

  // GPU-crash recovery budget: ONE engine dispose + reload + retry per turn
  // ([isTransformersJsGpuCrash] failures only). The counter caps reload
  // loops — a GPU that genuinely cannot fit the model fails the retry too,
  // and the error then surfaces instead of reloading forever.
  var recoveryAttempts = 0;

  /// Terminal path for every non-recovered failure: maps the raw engine
  /// dump to user-facing text, drops a possibly poisoned engine, and ends
  /// the stream with an [ErrorEvent].
  Future<void> fail(Object error) async {
    final aborted =
        error is CancelledException || (cancelToken?.isCancelled ?? false);
    stopReason = aborted ? StopReason.aborted : StopReason.error;
    final rawMessage = aborted
        ? 'Request was aborted'
        : _formatTransformersJsError(error);
    errorMessage = aborted
        ? rawMessage
        : formatTransformersJsErrorForUser(rawMessage);
    if (!aborted && engineEngaged) {
      // A failed generate can leave the ORT session poisoned (the WebGPU
      // invalid-buffer OrtRun error an undecodable image input causes):
      // drop the engine so the NEXT message reloads from the cached
      // weights instead of inheriting the broken state. Best effort.
      try {
        await service.unloadModel();
      } on Object {
        // Recovery must never mask the original error.
      }
    }
    eventStream.push(ErrorEvent(reason: stopReason, error: snapshot()));
  }

  try {
    while (true) {
      try {
        cancelToken?.throwIfCancelled();

        final preset = findTransformersJsPreset(model.id);
        if (preset == null) {
          throw StateError(
            'Unknown transformers.js model preset: ${model.id}. Pick one of: '
            '${transformersJsModelPresets.map((p) => p.id).join(', ')}',
          );
        }

        // Model download/compile happens here on the very first turn (the
        // settings form pre-loads, so this is normally instant). A cancel
        // during the wait takes effect right after.
        await service.loadModel(preset);
        engineEngaged = true;
        cancelToken?.throwIfCancelled();

        if (cancelToken != null && !cancelHooked) {
          cancelHooked = true;
          unawaited(
            cancelToken.onCancel.then((_) {
              unawaited(service.interrupt());
              try {
                activeCancelJs?.call();
              } catch (_) {
                // Best effort: interrupt above is the authoritative stop.
              }
              final inFlight = activeDone;
              if (inFlight != null && !inFlight.isCompleted) {
                inFlight.complete();
              }
            }),
          );
        }

        if (!startPushed) {
          startPushed = true;
          eventStream.push(StartEvent(partial: snapshot()));
        }

        var finishReason = '';
        String? streamError;
        final done = Completer<void>();
        activeDone = done;
        void finish() {
          if (!done.isCompleted) done.complete();
        }

        activeCancelJs = await service.chatStream(
          messages: convertTransformersJsMessages(
            context,
            supportsVision: preset.supportsVision,
          ),
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
              TextDeltaEvent(
                contentIndex: 0,
                delta: chunk,
                partial: snapshot(),
              ),
            );
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
        activeDone = null;
        activeCancelJs = null;

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

        if (finishReason == 'length') {
          stopReason = StopReason.length;
        }
        eventStream.push(DoneEvent(reason: stopReason, message: snapshot()));
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
            !textStarted &&
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
        await fail(error);
        return;
      }
    }
  } finally {
    eventStream.end();
  }
}

/// Maps a harness [Context] to chat messages for the transformers.js engine.
///
/// - `systemPrompt` becomes a `system` message. When the context carries no
///   tools the prompt-tools wrapper is a passthrough, so
///   [transformersJsNoToolsNote] is appended here instead — the model must
///   not try to call tools that are not there. (With tools present the
///   wrapper has already appended the tool instructions to `systemPrompt`
///   upstream.)
/// - User text passes through; image blocks become `data:` URIs on the
///   message's `images` when [supportsVision] AND the MIME type is one the
///   on-device stack can actually decode ([isInlineImageMimeType]: PNG,
///   JPEG, GIF, WebP). Everything else — SVG first among them — degrades to
///   an omission note: feeding undecodable bytes to `RawImage` kills the
///   ONNX Runtime WebGPU session (`mapAsync ... invalid Buffer`).
/// - Assistant text passes through; thinking blocks are dropped; historical
///   tool calls become a `[tool call: ...]` text line so role alternation is
///   preserved.
/// - Tool results become `user` messages with a `[tool result]` header
///   (plain-text fallback — the chat template has no `tool` role).
List<TransformersJsChatMessage> convertTransformersJsMessages(
  Context context, {
  required bool supportsVision,
}) {
  final messages = <TransformersJsChatMessage>[];

  var system = context.systemPrompt ?? '';
  final tools = context.tools;
  if (tools == null || tools.isEmpty) {
    system = system.isEmpty
        ? transformersJsNoToolsNote
        : '$system\n\n$transformersJsNoToolsNote';
  }
  if (system.isNotEmpty) {
    messages.add((role: 'system', content: system, images: const []));
  }

  for (final message in context.messages) {
    switch (message) {
      case UserMessage():
        final content = message.content;
        if (content is String) {
          if (content.trim().isNotEmpty) {
            messages.add((role: 'user', content: content, images: const []));
          }
        } else {
          final blocks = content as List<ContentBlock>;
          final parts = <String>[
            for (final block in blocks)
              if (block is TextContent && block.text.trim().isNotEmpty)
                block.text,
          ];
          final imageBlocks = blocks.whereType<ImageContent>().toList();
          final decodable = <ImageContent>[
            if (supportsVision)
              for (final block in imageBlocks)
                if (isInlineImageMimeType(block.mimeType)) block,
          ];
          final images = <String>[
            for (final block in decodable)
              'data:${block.mimeType};base64,${block.data}',
          ];
          final omitted = imageBlocks.length - decodable.length;
          if (omitted > 0) {
            parts.add(
              supportsVision
                  ? '(attached image omitted: format not decodable on-device)'
                  : '(attached image omitted: this model is text-only)',
            );
          }
          if (parts.isNotEmpty || images.isNotEmpty) {
            messages.add((
              role: 'user',
              content: parts.join('\n'),
              images: images,
            ));
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
          messages.add((
            role: 'assistant',
            content: parts.join('\n'),
            images: const [],
          ));
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
          images: const [],
        ));
    }
  }
  return messages;
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
