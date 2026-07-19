/// OpenAI chat-completions provider adapter (OpenRouter-ready).
///
/// Ported from pi-mono `packages/ai/src/api/openai-completions.ts`. Kept
/// mechanically close to the TypeScript original so future pi fixes port
/// trivially. Deliberate divergences:
///
/// - pi uses the `openai` SDK; this port talks to `POST {baseUrl}/chat/
///   completions` directly with `package:http` and decodes SSE via
///   [SseDecoder].
/// - pi accumulates into one mutable `AssistantMessage`; Dart types are
///   immutable, so every pushed event carries a freshly built snapshot of the
///   live partial message instead (same partial-first contract).
/// - pi's `parseStreamingJson` falls back to the `partial-json` package;
///   [parseStreamingJson] falls back to an empty map (after a repair pass),
///   which only matters for truncated final arguments.
/// - pi's `normalizeProviderError` probes SDK-specific error shapes; there is
///   no SDK here, so [formatProviderError] handles the Dart error types this
///   adapter can actually produce.
/// - Not yet ported (later phases): the full compat matrix (zai/qwen/
///   together/...), prompt-cache retention and session-affinity headers,
///   `transformMessages` reordering, surrogate sanitization, developer-role
///   system prompts, and thinking formats beyond OpenAI/OpenRouter.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../types.dart';
import 'provider_common.dart';

/// Options for [streamOpenAICompletions].
///
/// Ported subset of pi's `OpenAICompletionsOptions` (which extends
/// `SimpleStreamOptions`): temperature, maxTokens, apiKey, headers, signal,
/// reasoningEffort, toolChoice, onPayload, onResponse. pi's `signal:
/// AbortSignal` is [cancelToken] here.
final class OpenAICompletionsOptions {
  const OpenAICompletionsOptions({
    this.temperature,
    this.maxTokens,
    this.apiKey,
    this.headers,
    this.cancelToken,
    this.reasoningEffort,
    this.toolChoice,
    this.onPayload,
    this.onResponse,
  });

  /// Sampling temperature.
  final double? temperature;

  /// Output-token cap. Sent as `max_completion_tokens` (or `max_tokens`,
  /// depending on [OpenAICompletionsCompat.maxTokensField]).
  final int? maxTokens;

  /// API key sent as `Authorization: Bearer ...`. Falls back to an
  /// `authorization` entry in [headers] (key then unused), else the stream
  /// fails with an error event.
  final String? apiKey;

  /// Extra request headers, merged over [Model.headers]; a `null` value
  /// suppresses the header with the same name (pi's `ProviderHeaders`).
  final Map<String, String?>? headers;

  /// Cancels the in-flight request when triggered. The stream then ends with
  /// an [ErrorEvent] whose reason is [StopReason.aborted].
  final CancelToken? cancelToken;

  /// Reasoning effort level (`minimal`, `low`, `medium`, `high`, `xhigh`,
  /// `max`), sent per [OpenAICompletionsCompat.thinkingFormat]. pi's
  /// thinking-level clamping/mapping is not ported yet.
  final String? reasoningEffort;

  /// Tool choice: `'auto'`, `'none'`, `'required'`, or a
  /// `{type: 'function', function: {name: ...}}` map.
  final Object? toolChoice;

  /// Inspect or replace the request payload before it is sent. Return `null`
  /// to keep the payload unchanged.
  final FutureOr<Map<String, dynamic>?> Function(
    Map<String, dynamic> payload,
    Model model,
  )?
  onPayload;

  /// Called after the HTTP response headers arrive and before the body
  /// stream is consumed.
  final FutureOr<void> Function(
    int statusCode,
    Map<String, String> headers,
    Model model,
  )?
  onResponse;
}

/// Streams an assistant message from an OpenAI-compatible chat-completions
/// endpoint.
///
/// Ported from pi's `stream` in `openai-completions.ts`. The endpoint is
/// `{model.baseUrl}/chat/completions`, so OpenRouter is reached by setting
/// `baseUrl: 'https://openrouter.ai/api/v1'`.
///
/// **Errors-as-events invariant (non-negotiable):** this function never
/// throws. Network failures, non-200 responses, malformed SSE, and aborts
/// all terminate the returned stream with an [ErrorEvent] carrying
/// [StopReason.error] or [StopReason.aborted].
///
/// [client] overrides the HTTP client (used by tests with
/// `http.testing.MockClient`); when omitted, an owned client is created and
/// closed when the stream finishes.
AssistantMessageEventStream streamOpenAICompletions(
  Model model,
  Context context, [
  OpenAICompletionsOptions? options,
  http.Client? client,
]) {
  final eventStream = AssistantMessageEventStream();
  final cancelToken = options?.cancelToken;
  final httpClient = client ?? http.Client();

  // Mutable accumulation state. pi mutates a single `output` object; we keep
  // the pieces in a shared state holder and build an immutable snapshot per
  // event instead.
  final state = ProviderStreamState(model);
  final blocks = state.blocks;
  final toolCallBlocksByIndex = <int, ToolCallStreamingBlock>{};
  final toolCallBlocksById = <String, ToolCallStreamingBlock>{};
  final pendingReasoningDetailsByToolCallId = <String, String>{};
  var hasFinishReason = false;

  unawaited(
    runProviderStream(
      eventStream,
      state,
      cancelToken,
      httpClient,
      ownsClient: client == null,
      body: () async {
        final apiKey = _getClientApiKey(
          model.provider,
          options?.apiKey,
          options?.headers,
        );
        final compat = _getCompat(model);
        final params = await applyPayloadHook(
          _buildParams(model, context, options, compat),
          model,
          options?.onPayload,
        );

        cancelToken?.throwIfCancelled();

        final request =
            http.Request('POST', Uri.parse('${model.baseUrl}/chat/completions'))
              ..headers.addAll(_buildHeaders(model, options, apiKey))
              ..body = jsonEncode(params);

        final response = await startProviderResponse(
          eventStream,
          state,
          httpClient,
          request,
          cancelToken,
          options?.onResponse,
        );

        TextStreamingBlock? textBlock;
        ThinkingStreamingBlock? thinkingBlock;

        int contentIndex(StreamingBlock block) => blocks.indexOf(block);

        AssistantMessage snapshot() => state.snapshot();

        TextStreamingBlock ensureTextBlock() {
          var block = textBlock;
          if (block == null) {
            block = TextStreamingBlock();
            textBlock = block;
            blocks.add(block);
            eventStream.push(
              TextStartEvent(
                contentIndex: contentIndex(block),
                partial: snapshot(),
              ),
            );
          }
          return block;
        }

        ThinkingStreamingBlock ensureThinkingBlock(String thinkingSignature) {
          var block = thinkingBlock;
          if (block == null) {
            block = ThinkingStreamingBlock(signature: thinkingSignature);
            thinkingBlock = block;
            blocks.add(block);
            eventStream.push(
              ThinkingStartEvent(
                contentIndex: contentIndex(block),
                partial: snapshot(),
              ),
            );
          }
          return block;
        }

        void applyPendingReasoningDetail(ToolCallStreamingBlock block) {
          if (block.id.isEmpty) {
            return;
          }
          final pending = pendingReasoningDetailsByToolCallId.remove(block.id);
          if (pending != null) {
            block.thoughtSignature = pending;
          }
        }

        ToolCallStreamingBlock ensureToolCallBlock(
          Map<String, dynamic> toolCall,
        ) {
          final streamIndex = toolCall['index'] is int
              ? toolCall['index'] as int
              : null;
          final id = toolCall['id'] as String?;
          var block = streamIndex != null
              ? toolCallBlocksByIndex[streamIndex]
              : null;
          block ??= id != null ? toolCallBlocksById[id] : null;
          if (block == null) {
            final function = toolCall['function'];
            block = ToolCallStreamingBlock(
              id: id ?? '',
              name: function is Map ? function['name'] as String? ?? '' : '',
              streamIndex: streamIndex,
            );
            if (streamIndex != null) {
              toolCallBlocksByIndex[streamIndex] = block;
            }
            if (id != null) {
              toolCallBlocksById[id] = block;
            }
            blocks.add(block);
            eventStream.push(
              ToolCallStartEvent(
                contentIndex: contentIndex(block),
                partial: snapshot(),
              ),
            );
          }
          if (streamIndex != null && block.streamIndex == null) {
            block.streamIndex = streamIndex;
            toolCallBlocksByIndex[streamIndex] = block;
          }
          if (id != null) {
            toolCallBlocksById[id] = block;
          }
          applyPendingReasoningDetail(block);
          return block;
        }

        final iterator = createSseIterator(response, cancelToken);

        while (await iterator.moveNext()) {
          final data = iterator.current.data.trim();
          if (data.isEmpty || data == '[DONE]') {
            continue;
          }
          final chunk = jsonDecode(data);
          if (chunk is! Map<String, dynamic>) {
            continue;
          }

          // Each chunk in a streamed completion carries the same id.
          state.responseId ??= chunk['id'] as String?;
          final chunkModel = chunk['model'];
          if (chunkModel is String &&
              chunkModel.isNotEmpty &&
              chunkModel != model.id) {
            state.responseModel ??= chunkModel;
          }
          final rawUsage = chunk['usage'];
          if (rawUsage is Map<String, dynamic>) {
            state.usage = _parseChunkUsage(rawUsage, model);
          }

          final choices = chunk['choices'];
          final choice = choices is List && choices.isNotEmpty
              ? choices.first
              : null;
          if (choice is! Map<String, dynamic>) {
            continue;
          }

          // Fallback: some providers (e.g., Moonshot) return usage in
          // choice.usage instead of the standard chunk.usage.
          if (rawUsage == null) {
            final choiceUsage = choice['usage'];
            if (choiceUsage is Map<String, dynamic>) {
              state.usage = _parseChunkUsage(choiceUsage, model);
            }
          }

          final finishReason = choice['finish_reason'];
          if (finishReason != null) {
            final result = _mapStopReason(finishReason as String);
            state.stopReason = result.reason;
            state.errorMessage = result.errorMessage;
            hasFinishReason = true;
          }

          final delta = choice['delta'];
          if (delta is! Map<String, dynamic>) {
            continue;
          }

          final content = delta['content'];
          if (content is String && content.isNotEmpty) {
            final block = ensureTextBlock();
            block.text.write(content);
            eventStream.push(
              TextDeltaEvent(
                contentIndex: contentIndex(block),
                delta: content,
                partial: snapshot(),
              ),
            );
          }

          // Some endpoints return reasoning in reasoning_content (llama.cpp),
          // or reasoning (other openai compatible endpoints). Use the first
          // non-empty reasoning field to avoid duplication (e.g., chutes.ai
          // returns both reasoning_content and reasoning with same content).
          const reasoningFields = [
            'reasoning_content',
            'reasoning',
            'reasoning_text',
          ];
          String? foundReasoningField;
          for (final field in reasoningFields) {
            final value = delta[field];
            if (value is String && value.isNotEmpty) {
              foundReasoningField = field;
              break;
            }
          }
          if (foundReasoningField != null) {
            final reasoningDelta = delta[foundReasoningField] as String;
            final block = ensureThinkingBlock(foundReasoningField);
            block.thinking.write(reasoningDelta);
            eventStream.push(
              ThinkingDeltaEvent(
                contentIndex: contentIndex(block),
                delta: reasoningDelta,
                partial: snapshot(),
              ),
            );
          }

          final toolCalls = delta['tool_calls'];
          if (toolCalls is List) {
            for (final rawToolCall in toolCalls) {
              if (rawToolCall is! Map<String, dynamic>) {
                continue;
              }
              final block = ensureToolCallBlock(rawToolCall);
              final id = rawToolCall['id'] as String?;
              if (block.id.isEmpty && id != null) {
                block.id = id;
                toolCallBlocksById[id] = block;
              }
              final function = rawToolCall['function'];
              if (function is Map) {
                final name = function['name'] as String?;
                if (block.name.isEmpty && name != null) {
                  block.name = name;
                }
              }
              var toolDelta = '';
              if (function is Map && function['arguments'] is String) {
                toolDelta = function['arguments'] as String;
                block.partialArgs.write(toolDelta);
              }
              eventStream.push(
                ToolCallDeltaEvent(
                  contentIndex: contentIndex(block),
                  delta: toolDelta,
                  partial: snapshot(),
                ),
              );
            }
          }

          final reasoningDetails = delta['reasoning_details'];
          if (reasoningDetails is List) {
            for (final detail in reasoningDetails) {
              if (_isEncryptedReasoningDetail(detail)) {
                final map = detail as Map<String, dynamic>;
                final serialized = jsonEncode(map);
                final matching = toolCallBlocksById[map['id']];
                if (matching != null) {
                  matching.thoughtSignature = serialized;
                } else {
                  pendingReasoningDetailsByToolCallId[map['id'] as String] =
                      serialized;
                }
              }
            }
          }
        }

        for (final block in List.of(blocks)) {
          pushBlockEndEvent(eventStream, blocks, block, state.snapshot);
        }

        if (cancelToken?.isCancelled ?? false) {
          throw const AbortedError();
        }
        if (state.stopReason == StopReason.error) {
          throw StateError(
            state.errorMessage ?? 'Provider returned an error stop reason',
          );
        }
        if (!hasFinishReason) {
          throw StateError('Stream ended without finish_reason');
        }

        eventStream.push(
          DoneEvent(reason: state.stopReason, message: state.snapshot()),
        );
      },
    ),
  );

  return eventStream;
}

String _truncate40(String value) {
  return value.length > 40 ? value.substring(0, 40) : value;
}

String _getClientApiKey(
  String provider,
  String? apiKey,
  Map<String, String?>? headers,
) {
  if (apiKey != null) {
    return apiKey;
  }
  if (hasHeader(headers, 'authorization')) {
    return 'unused';
  }
  throw StateError('No API key for provider: $provider');
}

bool _hasToolHistory(List<Message> messages) {
  for (final message in messages) {
    if (message is ToolResultMessage) {
      return true;
    }
    if (message is AssistantMessage &&
        message.content.any((block) => block is ToolCall)) {
      return true;
    }
  }
  return false;
}

Map<String, String> _buildHeaders(
  Model model,
  OpenAICompletionsOptions? options,
  String apiKey,
) {
  return mergeProviderHeaders(
    {'content-type': 'application/json', 'authorization': 'Bearer $apiKey'},
    model.headers,
    options?.headers,
  );
}

/// Auto-detected plus overridden compatibility settings for [model].
///
/// Ported subset of pi's `detectCompat`/`getCompat`: only the OpenRouter
/// detection matters in Phase 0; the rest of the provider matrix arrives
/// with later cards.
final class _ResolvedCompat {
  const _ResolvedCompat({
    required this.maxTokensField,
    required this.supportsUsageInStreaming,
    required this.thinkingFormat,
    required this.requiresToolResultName,
  });

  final String maxTokensField;
  final bool supportsUsageInStreaming;
  final ThinkingFormat thinkingFormat;
  final bool requiresToolResultName;
}

_ResolvedCompat _getCompat(Model model) {
  final isOpenRouter =
      model.provider == 'openrouter' || model.baseUrl.contains('openrouter.ai');
  final compat = model.compat;
  return _ResolvedCompat(
    maxTokensField: compat?.maxTokensField ?? 'max_completion_tokens',
    supportsUsageInStreaming: compat?.supportsUsageInStreaming ?? true,
    thinkingFormat:
        compat?.thinkingFormat ??
        (isOpenRouter ? ThinkingFormat.openrouter : ThinkingFormat.openai),
    requiresToolResultName: compat?.requiresToolResultName ?? false,
  );
}

Map<String, dynamic> _buildParams(
  Model model,
  Context context,
  OpenAICompletionsOptions? options,
  _ResolvedCompat compat,
) {
  final messages = _convertMessages(model, context, compat);

  final params = <String, dynamic>{
    'model': model.id,
    'messages': messages,
    'stream': true,
  };

  if (compat.supportsUsageInStreaming) {
    params['stream_options'] = {'include_usage': true};
  }

  if (options?.maxTokens != null) {
    params[compat.maxTokensField] = options!.maxTokens;
  }

  if (options?.temperature != null) {
    params['temperature'] = options!.temperature;
  }

  if (context.tools != null && context.tools!.isNotEmpty) {
    params['tools'] = _convertTools(context.tools!);
  } else if (_hasToolHistory(context.messages)) {
    // Anthropic (via LiteLLM/proxy) requires tools param when conversation
    // has tool_calls/tool_results.
    params['tools'] = const <Object>[];
  }

  if (options?.toolChoice != null) {
    params['tool_choice'] = options!.toolChoice;
  }

  if (model.reasoning && options?.reasoningEffort != null) {
    if (compat.thinkingFormat == ThinkingFormat.openrouter) {
      // OpenRouter normalizes reasoning across providers via a nested
      // reasoning object.
      params['reasoning'] = {'effort': options!.reasoningEffort};
    } else {
      params['reasoning_effort'] = options!.reasoningEffort;
    }
  }

  return params;
}

List<Map<String, dynamic>> _convertMessages(
  Model model,
  Context context,
  _ResolvedCompat compat,
) {
  final params = <Map<String, dynamic>>[];

  String normalizeToolCallId(String id) {
    // Handle pipe-separated IDs from OpenAI Responses API
    // (format: {call_id}|{id}): extract the call_id part, sanitize to
    // allowed chars, and truncate to 40 chars (OpenAI limit).
    if (id.contains('|')) {
      final callId = id.split('|').first;
      return _truncate40(callId.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_'));
    }
    if (model.provider == 'openai') {
      return _truncate40(id);
    }
    return id;
  }

  if (context.systemPrompt != null) {
    params.add({'role': 'system', 'content': context.systemPrompt});
  }

  final messages = downgradeUnsupportedImages(context.messages, model);
  for (var i = 0; i < messages.length; i++) {
    final message = messages[i];
    if (message is UserMessage) {
      final content = message.content;
      if (content is String) {
        params.add({'role': 'user', 'content': content});
      } else {
        final parts = <Map<String, dynamic>>[];
        for (final item in content as List<ContentBlock>) {
          switch (item) {
            case TextContent():
              parts.add({'type': 'text', 'text': item.text});
            case ImageContent():
              parts.add({
                'type': 'image_url',
                'image_url': {
                  'url': 'data:${item.mimeType};base64,${item.data}',
                },
              });
            case ThinkingContent() || ToolCall():
              // Not valid in user messages; skip defensively.
              break;
          }
        }
        if (parts.isEmpty) {
          continue;
        }
        params.add({'role': 'user', 'content': parts});
      }
    } else if (message is AssistantMessage) {
      final assistantMsg = <String, dynamic>{'role': 'assistant'};

      final assistantText = [
        for (final block in message.content)
          if (block is TextContent && block.text.trim().isNotEmpty) block.text,
      ].join();

      final thinkingBlocks = [
        for (final block in message.content)
          if (block is ThinkingContent && block.thinking.trim().isNotEmpty)
            block,
      ];
      if (thinkingBlocks.isNotEmpty) {
        // Always send assistant content as a plain string (OpenAI Chat
        // Completions API standard format); see pi for why arrays of text
        // parts break some models.
        if (assistantText.isNotEmpty) {
          assistantMsg['content'] = assistantText;
        }
        // Use the signature from the first thinking block if available (for
        // llama.cpp server + gpt-oss).
        final signature = thinkingBlocks.first.thinkingSignature;
        if (signature != null && signature.isNotEmpty) {
          assistantMsg[signature] = thinkingBlocks
              .map((block) => block.thinking)
              .join('\n');
        }
      } else if (assistantText.isNotEmpty) {
        assistantMsg['content'] = assistantText;
      }

      final toolCalls = [
        for (final block in message.content)
          if (block is ToolCall) block,
      ];
      if (toolCalls.isNotEmpty) {
        assistantMsg['tool_calls'] = [
          for (final toolCall in toolCalls)
            {
              'id': normalizeToolCallId(toolCall.id),
              'type': 'function',
              'function': {
                'name': toolCall.name,
                'arguments': jsonEncode(toolCall.arguments),
              },
            },
        ];
        final reasoningDetails = [
          for (final toolCall in toolCalls)
            if (toolCall.thoughtSignature != null)
              _tryJsonDecode(toolCall.thoughtSignature!),
        ].nonNulls.toList();
        if (reasoningDetails.isNotEmpty) {
          assistantMsg['reasoning_details'] = reasoningDetails;
        }
      }

      // Skip assistant messages that have no content and no tool calls.
      final hasContent =
          assistantMsg['content'] is String &&
          (assistantMsg['content'] as String).isNotEmpty;
      if (!hasContent && !assistantMsg.containsKey('tool_calls')) {
        continue;
      }
      params.add(assistantMsg);
    } else if (message is ToolResultMessage) {
      final imageBlocks = <Map<String, dynamic>>[];
      var j = i;

      for (; j < messages.length && messages[j] is ToolResultMessage; j++) {
        final toolMessage = messages[j] as ToolResultMessage;

        // Extract text and image content.
        final textResult = [
          for (final block in toolMessage.content)
            if (block is TextContent) block.text,
        ].join('\n');
        final images = [
          for (final block in toolMessage.content)
            if (block is ImageContent) block,
        ];

        // Always send tool result with text (or placeholder if only images).
        final hasText = textResult.isNotEmpty;
        final toolResultText = hasText
            ? textResult
            : images.isNotEmpty
            ? '(see attached image)'
            : '(no tool output)';
        final toolResultMsg = <String, dynamic>{
          'role': 'tool',
          'content': toolResultText,
          'tool_call_id': normalizeToolCallId(toolMessage.toolCallId),
        };
        if (compat.requiresToolResultName && toolMessage.toolName.isNotEmpty) {
          toolResultMsg['name'] = toolMessage.toolName;
        }
        params.add(toolResultMsg);

        if (images.isNotEmpty && model.input.contains('image')) {
          for (final block in images) {
            imageBlocks.add({
              'type': 'image_url',
              'image_url': {
                'url': 'data:${block.mimeType};base64,${block.data}',
              },
            });
          }
        }
      }

      i = j - 1;

      if (imageBlocks.isNotEmpty) {
        params.add({
          'role': 'user',
          'content': [
            {'type': 'text', 'text': 'Attached image(s) from tool result:'},
            ...imageBlocks,
          ],
        });
      }
    }
  }

  return params;
}

List<Map<String, dynamic>> _convertTools(List<Tool> tools) {
  return [
    for (final tool in tools)
      {
        'type': 'function',
        'function': {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
        // pi only includes `strict` when the provider supports it; the
        // auto-detected default is to include it.
        'strict': false,
      },
  ];
}

Usage _parseChunkUsage(Map<String, dynamic> rawUsage, Model model) {
  final promptTokens = rawUsage['prompt_tokens'] as int? ?? 0;
  final promptDetails = rawUsage['prompt_tokens_details'];
  final cachedTokens = promptDetails is Map
      ? promptDetails['cached_tokens'] as int?
      : null;
  // Follow documented OpenAI/OpenRouter semantics: cached_tokens is
  // cache-read tokens (hits). Do not subtract writes from cached_tokens.
  final cacheReadTokens =
      cachedTokens ?? rawUsage['prompt_cache_hit_tokens'] as int? ?? 0;
  final cacheWriteTokens = promptDetails is Map
      ? promptDetails['cache_write_tokens'] as int? ?? 0
      : 0;

  final input = max(0, promptTokens - cacheReadTokens - cacheWriteTokens);
  // OpenAI completion_tokens already includes reasoning_tokens.
  final outputTokens = rawUsage['completion_tokens'] as int? ?? 0;
  final completionDetails = rawUsage['completion_tokens_details'];
  final reasoningTokens = completionDetails is Map
      ? completionDetails['reasoning_tokens'] as int?
      : null;

  var usage = Usage(
    input: input,
    output: outputTokens,
    cacheRead: cacheReadTokens,
    cacheWrite: cacheWriteTokens,
    reasoning: reasoningTokens,
    totalTokens: input + outputTokens + cacheReadTokens + cacheWriteTokens,
    cost: const UsageCost(),
  );
  usage = calculateCost(usage, model);

  // OpenRouter reports the actual billed cost in `usage.cost`; prefer it
  // over the rate-based estimate when present.
  final reportedCost = rawUsage['cost'];
  if (reportedCost is num) {
    usage = usage.copyWith(
      cost: usage.cost.copyWith(total: reportedCost.toDouble()),
    );
  }
  return usage;
}

({StopReason reason, String? errorMessage}) _mapStopReason(String reason) {
  return switch (reason) {
    'stop' || 'end' => (reason: StopReason.stop, errorMessage: null),
    'length' => (reason: StopReason.length, errorMessage: null),
    'function_call' ||
    'tool_calls' => (reason: StopReason.toolUse, errorMessage: null),
    'content_filter' => (
      reason: StopReason.error,
      errorMessage: 'Provider finish_reason: content_filter',
    ),
    'network_error' => (
      reason: StopReason.error,
      errorMessage: 'Provider finish_reason: network_error',
    ),
    _ => (
      reason: StopReason.error,
      errorMessage: 'Provider finish_reason: $reason',
    ),
  };
}

bool _isEncryptedReasoningDetail(Object? detail) {
  if (detail is! Map) {
    return false;
  }
  final id = detail['id'];
  final data = detail['data'];
  return detail['type'] == 'reasoning.encrypted' &&
      id is String &&
      id.isNotEmpty &&
      data is String &&
      data.isNotEmpty;
}

Object? _tryJsonDecode(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return null;
  }
}
