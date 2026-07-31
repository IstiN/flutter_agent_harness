/// Anthropic messages provider adapter.
///
/// Ported from pi-mono `packages/ai/src/api/anthropic-messages.ts`. Kept
/// mechanically close to the TypeScript original so future pi fixes port
/// trivially. Deliberate divergences:
///
/// - pi uses the `@anthropic-ai/sdk`; this port talks to
///   `POST {baseUrl}/v1/messages` directly with `package:http` and decodes
///   the named-event SSE stream via [SseDecoder] (the decoder itself was
///   ported from this same pi file).
/// - pi accumulates into one mutable `AssistantMessage`; Dart types are
///   immutable, so every pushed event carries a freshly built snapshot of the
///   live partial message instead (same partial-first contract). Scratch
///   state lives in the shared `StreamingBlock` classes (see
///   `provider_common.dart`).
/// - The `anthropic-version` header is sent explicitly (the SDK adds it for
///   pi).
/// - Not yet ported (later phases): OAuth/Claude Code identity (Bearer auth,
///   tool-name canonicalization, forced system prompt), GitHub Copilot
///   headers, adaptive thinking (`forceAdaptiveThinking`, `output_config`
///   effort), `AnthropicMessagesCompat` overrides on `Model` (defaults are
///   used), deferred tools / tool references, `transformMessages`
///   reordering, surrogate sanitization, session-affinity headers, and
///   `PI_CACHE_RETENTION` env lookup (cache retention is option-driven only).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../json_parse.dart';
import '../model.dart';
import '../sse_decoder.dart';
import '../types.dart';
import 'provider_common.dart';

const _fineGrainedToolStreamingBeta = 'fine-grained-tool-streaming-2025-05-14';
const _interleavedThinkingBeta = 'interleaved-thinking-2025-05-14';

/// The SSE event names Anthropic streams for a message. Other named events
/// (e.g. `ping`) are skipped, per pi's `iterateAnthropicEvents`.
const _anthropicMessageEvents = {
  'message_start',
  'message_delta',
  'message_stop',
  'content_block_start',
  'content_block_delta',
  'content_block_stop',
};

/// Options for [streamAnthropic].
///
/// Ported subset of pi's `AnthropicOptions` (which extends `StreamOptions`):
/// temperature, maxTokens, apiKey, headers, signal, thinkingEnabled,
/// thinkingBudgetTokens, effort, thinkingDisplay, interleavedThinking,
/// cacheRetention, toolChoice, onPayload, onResponse. pi's `signal:
/// AbortSignal` is [cancelToken] here. OAuth, metadata, sessionId, timeoutMs,
/// maxRetries, and the pre-built SDK client are not ported yet.
final class AnthropicOptions {
  const AnthropicOptions({
    this.temperature,
    this.maxTokens,
    this.apiKey,
    this.headers,
    this.cancelToken,
    this.thinkingEnabled,
    this.thinkingBudgetTokens,
    this.effort,
    this.thinkingDisplay,
    this.interleavedThinking,
    this.cacheRetention,
    this.toolChoice,
    this.onPayload,
    this.onResponse,
  });

  /// Sampling temperature. Ignored when [thinkingEnabled] is true (extended
  /// thinking is incompatible with temperature), per pi.
  final double? temperature;

  /// Output-token cap, sent as `max_tokens`. Defaults to [Model.maxTokens].
  final int? maxTokens;

  /// API key sent as `x-api-key: ...`. Falls back to an `authorization`,
  /// `x-api-key`, or `cf-aig-authorization` entry in [headers] (key then
  /// unused), else the stream fails with an error event.
  final String? apiKey;

  /// Extra request headers, merged over [Model.headers]; a `null` value
  /// suppresses the header with the same name (pi's `ProviderHeaders`).
  final Map<String, String?>? headers;

  /// Cancels the in-flight request when triggered. The stream then ends with
  /// an [ErrorEvent] whose reason is [StopReason.aborted].
  final CancelToken? cancelToken;

  /// Enable extended thinking. Only sent when [Model.reasoning] is true:
  /// `true` sends `thinking: {type: 'enabled', ...}`, `false` sends
  /// `{type: 'disabled'}`, `null` omits the parameter (provider default).
  final bool? thinkingEnabled;

  /// Token budget for budget-based extended thinking. Default: 1024 when
  /// [thinkingEnabled] is true and no budget is provided.
  final int? thinkingBudgetTokens;

  /// Effort level for adaptive-thinking models (`low`, `medium`, `high`,
  /// `xhigh`, `max`). Accepted for forward compatibility; only sent once
  /// adaptive thinking lands (pi gates it on `forceAdaptiveThinking`).
  final String? effort;

  /// How thinking content is returned: `summarized` (default) or `omitted`.
  /// Sent as `thinking.display` when [thinkingEnabled] is true.
  final String? thinkingDisplay;

  /// Whether to request the interleaved-thinking beta header. Default: true,
  /// per pi (adaptive-thinking models skip it, which is not ported yet).
  final bool? interleavedThinking;

  /// Prompt-cache retention: `short` (default; ephemeral cache breakpoints),
  /// `long` (1h TTL where supported), or `none` (no `cache_control`).
  final String? cacheRetention;

  /// Anthropic tool choice: `'auto'`, `'any'`, `'none'`, or a
  /// `{type: 'tool', name: ...}` map forcing a specific tool.
  final Object? toolChoice;

  /// Hook invoked with the fully built request payload right before sending;
  /// return a replacement map to override it, or `null` to send it as-is.
  final FutureOr<Map<String, dynamic>?> Function(
    Map<String, dynamic> payload,
    Model model,
  )?
  onPayload;

  /// Hook invoked once the response headers are in, before the SSE body is
  /// consumed.
  final FutureOr<void> Function(
    int statusCode,
    Map<String, String> headers,
    Model model,
  )?
  onResponse;
}

/// Anthropic compatibility settings for [Model].
///
/// Ported subset of pi's `AnthropicMessagesCompat` with pi's defaults.
/// pi reads these from `model.compat`; this package's [Model] has no
/// Anthropic compat field yet, so the defaults are constant for now.
final class _ResolvedCompat {
  const _ResolvedCompat({
    required this.supportsEagerToolInputStreaming,
    required this.supportsLongCacheRetention,
    required this.supportsCacheControlOnTools,
    required this.supportsTemperature,
    required this.allowEmptySignature,
  });

  final bool supportsEagerToolInputStreaming;
  final bool supportsLongCacheRetention;
  final bool supportsCacheControlOnTools;
  final bool supportsTemperature;
  final bool allowEmptySignature;
}

_ResolvedCompat _getCompat(Model model) {
  return const _ResolvedCompat(
    supportsEagerToolInputStreaming: true,
    supportsLongCacheRetention: true,
    supportsCacheControlOnTools: true,
    supportsTemperature: true,
    allowEmptySignature: false,
  );
}

/// Streams an assistant message from an Anthropic messages endpoint.
///
/// Ported from pi's `stream` in `anthropic-messages.ts`. The endpoint is
/// `{model.baseUrl}/v1/messages` (default base URL
/// `https://api.anthropic.com` on the model descriptor).
///
/// **Errors-as-events invariant (non-negotiable):** this function never
/// throws. Network failures, non-200 responses, provider `error` SSE events,
/// malformed SSE, and aborts all terminate the returned stream with an
/// [ErrorEvent] carrying [StopReason.error] or [StopReason.aborted].
///
/// [client] overrides the HTTP client (used by tests with
/// `http.testing.MockClient`); when omitted, an owned client is created and
/// closed when the stream finishes.
AssistantMessageEventStream streamAnthropic(
  Model model,
  Context context, [
  AnthropicOptions? options,
  http.Client? client,
]) {
  final eventStream = AssistantMessageEventStream();
  final cancelToken = options?.cancelToken;
  final httpClient = client ?? http.Client();

  // Blocks accumulate in the shared state holder; each event carries a
  // fresh immutable snapshot of them (pi mutates one `output` object).
  final state = ProviderStreamState(model);
  final session = _AnthropicStreamSession(model, eventStream, state);

  unawaited(
    runProviderStream(
      eventStream,
      state,
      cancelToken,
      httpClient,
      ownsClient: client == null,
      body: () => session.run(context, options, httpClient, cancelToken),
    ),
  );

  return eventStream;
}

/// Per-request SSE state machine for [streamAnthropic].
///
/// Ported from the body of pi's `stream` in `anthropic-messages.ts` (the
/// request build plus `iterateAnthropicEvents` loop). Holds the mutable
/// streaming state (block table, message_start/message_stop flags) so each
/// SSE event type can be handled by a small dedicated method.
final class _AnthropicStreamSession {
  _AnthropicStreamSession(this.model, this.eventStream, this.state)
    : blocks = state.blocks;

  final Model model;
  final AssistantMessageEventStream eventStream;
  final ProviderStreamState state;

  /// Aliases [ProviderStreamState.blocks] (the snapshot source of truth).
  final List<StreamingBlock> blocks;
  final Map<int, StreamingBlock> blocksByEventIndex = <int, StreamingBlock>{};
  var sawMessageStart = false;
  var sawMessageStop = false;

  /// Builds and sends the request, then consumes the SSE stream. Never
  /// returns a provider failure normally — errors propagate so
  /// `runProviderStream` can surface them as an [ErrorEvent].
  Future<void> run(
    Context context,
    AnthropicOptions? options,
    http.Client httpClient,
    CancelToken? cancelToken,
  ) async {
    final compat = _getCompat(model);
    final apiKey = _getClientApiKey(
      model.provider,
      options?.apiKey,
      options?.headers,
    );
    final params = await applyPayloadHook(
      _buildParams(model, context, options, compat),
      model,
      options?.onPayload,
    );

    cancelToken?.throwIfCancelled();

    final request =
        http.Request('POST', Uri.parse('${model.baseUrl}/v1/messages'))
          ..headers.addAll(
            _buildHeaders(model, context, options, compat, apiKey),
          )
          ..body = jsonEncode(params);

    final response = await startProviderResponse(
      eventStream,
      state,
      httpClient,
      request,
      cancelToken,
      options?.onResponse,
    );

    final iterator = createSseIterator(response, cancelToken);

    // Ported from pi's `iterateAnthropicEvents`: only the message events
    // are parsed, an `error` event aborts, and a stream that started but
    // never saw message_stop is a failure.
    while (await iterator.moveNext()) {
      _handleSseEvent(iterator.current);
    }

    if (sawMessageStart && !sawMessageStop) {
      throw StateError('Anthropic stream ended before message_stop');
    }

    if (cancelToken?.isCancelled ?? false) {
      throw const AbortedError();
    }
    if (state.stopReason == StopReason.aborted ||
        state.stopReason == StopReason.error) {
      throw StateError(state.errorMessage ?? 'An unknown error occurred');
    }

    eventStream.push(
      DoneEvent(reason: state.stopReason, message: state.snapshot()),
    );
  }

  /// Per-type handlers, keyed by the SSE event `type`. `message_stop` is
  /// absent on purpose: it carries no payload; it only terminates the
  /// stream.
  late final Map<String, void Function(Map<String, dynamic> event)>
  _eventHandlers = {
    'message_start': _handleMessageStart,
    'content_block_start': _handleContentBlockStart,
    'content_block_delta': _handleContentBlockDelta,
    'content_block_stop': _handleContentBlockStop,
    'message_delta': _handleMessageDelta,
  };

  /// Parses one raw SSE event and dispatches it to the per-type handler.
  void _handleSseEvent(ServerSentEvent sse) {
    if (sse.event == 'error') {
      throw StateError(sse.data);
    }
    if (!_anthropicMessageEvents.contains(sse.event)) {
      return;
    }
    final event = _parseSseEvent(sse);
    _eventHandlers[event['type']]?.call(event);
  }

  /// Decodes the SSE `data` JSON into the event map, recording
  /// message_start/message_stop sightings along the way.
  Map<String, dynamic> _parseSseEvent(ServerSentEvent sse) {
    try {
      final parsed = parseJsonWithRepair(sse.data);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('SSE data is not a JSON object');
      }
      final type = parsed['type'];
      if (type == 'message_start') {
        sawMessageStart = true;
      } else if (type == 'message_stop') {
        sawMessageStop = true;
      }
      return parsed;
    } catch (error) {
      throw StateError(
        'Could not parse Anthropic SSE event ${sse.event}: $error; '
        'data=${sse.data}; raw=${sse.raw.join(r'\n')}',
      );
    }
  }

  void _handleMessageStart(Map<String, dynamic> event) {
    final message = event['message'];
    if (message is Map<String, dynamic>) {
      state.responseId = message['id'] as String?;
      final rawUsage = message['usage'];
      if (rawUsage is Map<String, dynamic>) {
        // Capture initial token usage from message_start so we have
        // input token counts even if the stream is aborted early.
        _applyUsage(rawUsage, initial: true);
      }
    }
  }

  void _handleContentBlockStart(Map<String, dynamic> event) {
    final index = event['index'] as int?;
    final contentBlock = event['content_block'];
    if (index != null && contentBlock is Map<String, dynamic>) {
      final block = _createStreamingBlock(contentBlock);
      if (block != null) {
        blocks.add(block);
        blocksByEventIndex[index] = block;
        final startIndex = blocks.indexOf(block);
        switch (block) {
          case TextStreamingBlock():
            eventStream.push(
              TextStartEvent(
                contentIndex: startIndex,
                partial: state.snapshot(),
              ),
            );
          case ThinkingStreamingBlock():
            eventStream.push(
              ThinkingStartEvent(
                contentIndex: startIndex,
                partial: state.snapshot(),
              ),
            );
          case ToolCallStreamingBlock():
            eventStream.push(
              ToolCallStartEvent(
                contentIndex: startIndex,
                partial: state.snapshot(),
              ),
            );
        }
      }
    }
  }

  /// Creates the scratch block for a `content_block_start`, or `null` for
  /// block types pi does not stream (unknown types are ignored).
  StreamingBlock? _createStreamingBlock(Map<String, dynamic> contentBlock) {
    return switch (contentBlock['type']) {
      'text' => TextStreamingBlock(),
      'thinking' => ThinkingStreamingBlock(signature: ''),
      'redacted_thinking' => ThinkingStreamingBlock(
        signature: contentBlock['data'] as String? ?? '',
        redacted: true,
        initialText: '[Reasoning redacted]',
      ),
      'tool_use' => ToolCallStreamingBlock(
        id: contentBlock['id'] as String? ?? '',
        name: contentBlock['name'] as String? ?? '',
        initialArguments: contentBlock['input'] is Map<String, dynamic>
            ? contentBlock['input'] as Map<String, dynamic>
            : null,
      ),
      _ => null,
    };
  }

  void _handleContentBlockDelta(Map<String, dynamic> event) {
    final index = event['index'] as int?;
    final delta = event['delta'];
    final block = index != null ? blocksByEventIndex[index] : null;
    if (block != null && delta is Map<String, dynamic>) {
      _dispatchContentBlockDelta(block, delta);
    }
  }

  /// Routes a `content_block_delta` to the per-delta-type handler; a delta
  /// whose type does not match the block it lands on is ignored, per pi.
  void _dispatchContentBlockDelta(
    StreamingBlock block,
    Map<String, dynamic> delta,
  ) {
    switch (delta['type']) {
      case 'text_delta':
        _handleTextDelta(block, delta);
      case 'thinking_delta':
        _handleThinkingDelta(block, delta);
      case 'input_json_delta':
        _handleInputJsonDelta(block, delta);
      case 'signature_delta':
        _handleSignatureDelta(block, delta);
    }
  }

  void _handleTextDelta(StreamingBlock block, Map<String, dynamic> delta) {
    if (block is! TextStreamingBlock) {
      return;
    }
    final text = delta['text'] as String? ?? '';
    block.text.write(text);
    eventStream.push(
      TextDeltaEvent(
        contentIndex: blocks.indexOf(block),
        delta: text,
        partial: state.snapshot(),
      ),
    );
  }

  void _handleThinkingDelta(StreamingBlock block, Map<String, dynamic> delta) {
    if (block is! ThinkingStreamingBlock) {
      return;
    }
    final thinking = delta['thinking'] as String? ?? '';
    block.thinking.write(thinking);
    eventStream.push(
      ThinkingDeltaEvent(
        contentIndex: blocks.indexOf(block),
        delta: thinking,
        partial: state.snapshot(),
      ),
    );
  }

  void _handleInputJsonDelta(StreamingBlock block, Map<String, dynamic> delta) {
    if (block is! ToolCallStreamingBlock) {
      return;
    }
    final partialJson = delta['partial_json'] as String? ?? '';
    block.partialArgs.write(partialJson);
    eventStream.push(
      ToolCallDeltaEvent(
        contentIndex: blocks.indexOf(block),
        delta: partialJson,
        partial: state.snapshot(),
      ),
    );
  }

  void _handleSignatureDelta(StreamingBlock block, Map<String, dynamic> delta) {
    if (block is! ThinkingStreamingBlock) {
      return;
    }
    // Signatures accumulate silently; pi pushes no event here.
    block.signature =
        (block.signature ?? '') + (delta['signature'] as String? ?? '');
  }

  void _handleContentBlockStop(Map<String, dynamic> event) {
    final index = event['index'] as int?;
    final block = index != null ? blocksByEventIndex[index] : null;
    if (block != null) {
      pushBlockEndEvent(eventStream, blocks, block, state.snapshot);
    }
  }

  void _handleMessageDelta(Map<String, dynamic> event) {
    final delta = event['delta'];
    if (delta is Map<String, dynamic>) {
      final rawStopReason = delta['stop_reason'];
      if (rawStopReason is String) {
        final stopDetails = delta['stop_details'];
        final result = _mapStopReason(
          rawStopReason,
          stopDetails is Map<String, dynamic> ? stopDetails : null,
        );
        state.stopReason = result.reason;
        state.errorMessage = result.errorMessage;
      }
    }
    final rawUsage = event['usage'];
    if (rawUsage is Map<String, dynamic>) {
      _applyUsage(rawUsage, initial: false);
    }
  }

  void _applyUsage(Map<String, dynamic> rawUsage, {required bool initial}) {
    // message_start seeds every field; message_delta only overwrites
    // fields that are present, preserving message_start values when
    // proxies omit them (pi's null-preserving merge).
    var input = rawUsage['input_tokens'] as int?;
    var output = rawUsage['output_tokens'] as int?;
    var cacheRead = rawUsage['cache_read_input_tokens'] as int?;
    var cacheWrite = rawUsage['cache_creation_input_tokens'] as int?;
    final cacheCreation = rawUsage['cache_creation'];
    final cacheWrite1h = cacheCreation is Map
        ? cacheCreation['ephemeral_1h_input_tokens'] as int?
        : null;
    if (initial) {
      input ??= 0;
      output ??= 0;
      cacheRead ??= 0;
      cacheWrite ??= 0;
    }
    // Anthropic reports reasoning tokens in
    // `output_tokens_details.thinking_tokens` on the final message_delta
    // usage (a subset of output_tokens).
    final outputDetails = rawUsage['output_tokens_details'];
    final reasoning = outputDetails is Map
        ? outputDetails['thinking_tokens'] as int?
        : null;

    final merged = state.usage.copyWith(
      input: input,
      output: output,
      cacheRead: cacheRead,
      cacheWrite: cacheWrite,
      cacheWrite1h: cacheWrite1h,
      reasoning: reasoning,
    );
    // Anthropic doesn't provide total_tokens; compute from components.
    state.usage = calculateCost(
      merged.copyWith(
        totalTokens:
            merged.input + merged.output + merged.cacheRead + merged.cacheWrite,
      ),
      model,
    );
  }
}

/// Ported from pi's `assertRequestAuth`: an explicit API key wins; otherwise
/// the caller must have supplied an auth header themselves.
String? _getClientApiKey(
  String provider,
  String? apiKey,
  Map<String, String?>? headers,
) {
  if (apiKey != null) {
    return apiKey;
  }
  if (hasHeader(headers, 'authorization') ||
      hasHeader(headers, 'x-api-key') ||
      hasHeader(headers, 'cf-aig-authorization')) {
    return null;
  }
  throw StateError('No API key for provider: $provider');
}

Map<String, String> _buildHeaders(
  Model model,
  Context context,
  AnthropicOptions? options,
  _ResolvedCompat compat,
  String? apiKey,
) {
  // Ported from pi's `createClient` (API-key path).
  final betaFeatures = <String>[];
  if (_shouldUseFineGrainedToolStreamingBeta(model, context, compat)) {
    betaFeatures.add(_fineGrainedToolStreamingBeta);
  }
  // Adaptive thinking models have interleaved thinking built in; since
  // adaptive thinking is not ported yet, the beta is always requested when
  // the option allows it.
  if (options?.interleavedThinking ?? true) {
    betaFeatures.add(_interleavedThinkingBeta);
  }

  final headers = mergeProviderHeaders(
    {
      'content-type': 'application/json',
      'accept': 'application/json',
      // The Anthropic SDK sends this for pi; without an SDK we send it
      // explicitly.
      'anthropic-version': '2023-06-01',
      'x-api-key': ?apiKey,
      if (betaFeatures.isNotEmpty) 'anthropic-beta': betaFeatures.join(','),
    },
    model.headers,
    options?.headers,
  );
  return headers;
}

bool _shouldUseFineGrainedToolStreamingBeta(
  Model model,
  Context context,
  _ResolvedCompat compat,
) {
  return (context.tools?.isNotEmpty ?? false) &&
      !compat.supportsEagerToolInputStreaming;
}

/// Ported from pi's `getCacheControl` (minus the `PI_CACHE_RETENTION` env
/// lookup): `short` is the default, `long` requests a 1h TTL where the model
/// supports it, `none` disables cache breakpoints entirely.
Map<String, dynamic>? _getCacheControl(
  AnthropicOptions? options,
  _ResolvedCompat compat,
) {
  final retention = options?.cacheRetention ?? 'short';
  if (retention == 'none') {
    return null;
  }
  return {
    'type': 'ephemeral',
    if (retention == 'long' && compat.supportsLongCacheRetention) 'ttl': '1h',
  };
}

Map<String, dynamic> _buildParams(
  Model model,
  Context context,
  AnthropicOptions? options,
  _ResolvedCompat compat,
) {
  final cacheControl = _getCacheControl(options, compat);
  final params = <String, dynamic>{
    'model': model.id,
    'messages': _convertMessages(
      downgradeUnsupportedImages(context.messages, model),
      cacheControl: cacheControl,
      allowEmptySignature: compat.allowEmptySignature,
    ),
    'max_tokens': options?.maxTokens ?? model.maxTokens,
    'stream': true,
  };

  _addSystemParam(params, context, cacheControl);
  _addTemperatureParam(params, options, compat);
  _addToolsParam(params, context, compat, cacheControl);
  _addThinkingParam(params, model, options);
  _addToolChoiceParam(params, options);

  return params;
}

void _addSystemParam(
  Map<String, dynamic> params,
  Context context,
  Map<String, dynamic>? cacheControl,
) {
  if (context.systemPrompt != null) {
    params['system'] = [
      {
        'type': 'text',
        'text': context.systemPrompt,
        'cache_control': ?cacheControl,
      },
    ];
  }
}

void _addTemperatureParam(
  Map<String, dynamic> params,
  AnthropicOptions? options,
  _ResolvedCompat compat,
) {
  // Temperature is incompatible with extended thinking.
  if (options?.temperature != null &&
      options?.thinkingEnabled != true &&
      compat.supportsTemperature) {
    params['temperature'] = options!.temperature;
  }
}

void _addToolsParam(
  Map<String, dynamic> params,
  Context context,
  _ResolvedCompat compat,
  Map<String, dynamic>? cacheControl,
) {
  if (context.tools != null && context.tools!.isNotEmpty) {
    params['tools'] = _convertTools(
      context.tools!,
      supportsEagerToolInputStreaming: compat.supportsEagerToolInputStreaming,
      cacheControl: compat.supportsCacheControlOnTools ? cacheControl : null,
    );
  }
}

/// Configures thinking mode: budget-based enabled, explicitly disabled, or
/// provider default (omitted). pi's adaptive-thinking branch
/// (forceAdaptiveThinking, output_config effort) is not ported yet.
void _addThinkingParam(
  Map<String, dynamic> params,
  Model model,
  AnthropicOptions? options,
) {
  if (model.reasoning && options?.thinkingEnabled != null) {
    if (options!.thinkingEnabled!) {
      params['thinking'] = {
        'type': 'enabled',
        'budget_tokens': options.thinkingBudgetTokens ?? 1024,
        'display': options.thinkingDisplay ?? 'summarized',
      };
    } else {
      params['thinking'] = {'type': 'disabled'};
    }
  }
}

void _addToolChoiceParam(
  Map<String, dynamic> params,
  AnthropicOptions? options,
) {
  if (options?.toolChoice != null) {
    final toolChoice = options!.toolChoice!;
    params['tool_choice'] = toolChoice is String
        ? {'type': toolChoice}
        : toolChoice;
  }
}

/// Normalize tool call IDs to match Anthropic's required pattern and length.
///
/// Ported from pi's `normalizeToolCallId`. pi applies it inside
/// `transformMessages`; the image-downgrade half of that pre-pass is ported
/// ([downgradeUnsupportedImages] runs in [_buildParams]), while id
/// normalization is still applied at conversion time (same net effect).
String _normalizeToolCallId(String id) {
  final sanitized = id.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
  return sanitized.length > 64 ? sanitized.substring(0, 64) : sanitized;
}

/// Converts tool-result content blocks to Anthropic format.
///
/// Ported from pi's `convertContentBlocks`: text-only results collapse to a
/// single string; results with images become a content-block array, seeded
/// with placeholder text when there is no text block.
Object _convertContentBlocks(List<ContentBlock> content) {
  final hasImages = content.any((block) => block is ImageContent);
  if (!hasImages) {
    return [
      for (final block in content)
        if (block is TextContent) block.text,
    ].join('\n');
  }

  final blocks = <Map<String, dynamic>>[];
  for (final block in content) {
    switch (block) {
      case TextContent():
        blocks.add({'type': 'text', 'text': block.text});
      case ImageContent():
        blocks.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': block.mimeType,
            'data': block.data,
          },
        });
      case ThinkingContent() || ToolCall():
        // Not valid in tool results; skip defensively.
        break;
    }
  }
  if (!blocks.any((block) => block['type'] == 'text')) {
    blocks.insert(0, {'type': 'text', 'text': '(see attached image)'});
  }
  return blocks;
}

List<Map<String, dynamic>> _convertMessages(
  List<Message> messages, {
  Map<String, dynamic>? cacheControl,
  required bool allowEmptySignature,
}) {
  final params = <Map<String, dynamic>>[];

  for (var i = 0; i < messages.length; i++) {
    i = _convertMessageAt(
      messages,
      i,
      params,
      allowEmptySignature: allowEmptySignature,
    );
  }

  // Add cache_control to the last user message to cache conversation history.
  if (cacheControl != null && params.isNotEmpty) {
    _applyCacheControlToLastUserMessage(params.last, cacheControl);
  }

  return params;
}

/// Converts the message at [index], appending the result to [params], and
/// returns the index of the last consumed message (a run of tool results is
/// grouped, consuming several).
int _convertMessageAt(
  List<Message> messages,
  int index,
  List<Map<String, dynamic>> params, {
  required bool allowEmptySignature,
}) {
  final message = messages[index];

  if (message is UserMessage) {
    final converted = _convertUserMessage(message);
    if (converted != null) {
      params.add(converted);
    }
  } else if (message is AssistantMessage) {
    final converted = _convertAssistantMessage(
      message,
      allowEmptySignature: allowEmptySignature,
    );
    if (converted != null) {
      params.add(converted);
    }
  } else if (message is ToolResultMessage) {
    final group = _convertToolResultGroup(messages, index);
    params.add(group.message);
    // Skip the messages we've already processed.
    return group.lastIndex;
  }

  return index;
}

/// Converts a [UserMessage] to Anthropic format, or returns `null` when the
/// message has no non-empty content (the caller then skips it).
Map<String, dynamic>? _convertUserMessage(UserMessage message) {
  final content = message.content;
  if (content is String) {
    if (content.trim().isNotEmpty) {
      return {'role': 'user', 'content': content};
    }
    return null;
  }

  final blocks = _convertUserContentBlocks(content as List<ContentBlock>);
  final filtered = [
    for (final block in blocks)
      if (block['type'] != 'text' ||
          (block['text'] as String).trim().isNotEmpty)
        block,
  ];
  if (filtered.isEmpty) {
    return null;
  }
  return {'role': 'user', 'content': filtered};
}

/// Converts user content blocks: text and images map one-to-one; anything
/// else is not valid in user messages and is skipped defensively.
List<Map<String, dynamic>> _convertUserContentBlocks(
  List<ContentBlock> content,
) {
  final blocks = <Map<String, dynamic>>[];
  for (final item in content) {
    switch (item) {
      case TextContent():
        blocks.add({'type': 'text', 'text': item.text});
      case ImageContent():
        blocks.add({
          'type': 'image',
          'source': {
            'type': 'base64',
            'media_type': item.mimeType,
            'data': item.data,
          },
        });
      case ThinkingContent() || ToolCall():
        // Not valid in user messages; skip defensively.
        break;
    }
  }
  return blocks;
}

/// Converts an [AssistantMessage] to Anthropic format, or returns `null`
/// when nothing convertible remains (the caller then skips it).
Map<String, dynamic>? _convertAssistantMessage(
  AssistantMessage message, {
  required bool allowEmptySignature,
}) {
  final blocks = <Map<String, dynamic>>[];

  for (final block in message.content) {
    _addAssistantBlock(blocks, block, allowEmptySignature: allowEmptySignature);
  }
  if (blocks.isEmpty) {
    return null;
  }
  return {'role': 'assistant', 'content': blocks};
}

/// Converts one assistant content block, appending it to [blocks] unless it
/// is empty or invalid in assistant messages (skipped defensively).
void _addAssistantBlock(
  List<Map<String, dynamic>> blocks,
  ContentBlock block, {
  required bool allowEmptySignature,
}) {
  switch (block) {
    case TextContent():
      if (block.text.trim().isEmpty) {
        return;
      }
      blocks.add({'type': 'text', 'text': block.text});
    case ThinkingContent():
      final converted = _convertThinkingBlock(
        block,
        allowEmptySignature: allowEmptySignature,
      );
      if (converted != null) {
        blocks.add(converted);
      }
    case ToolCall():
      blocks.add({
        'type': 'tool_use',
        'id': _normalizeToolCallId(block.id),
        'name': block.name,
        'input': block.arguments,
      });
    case ImageContent():
      // Not valid in assistant messages; skip defensively.
      break;
  }
}

/// Converts one [ThinkingContent] block, or returns `null` when it carries
/// neither thinking text nor a signature (the caller then skips it).
Map<String, dynamic>? _convertThinkingBlock(
  ThinkingContent block, {
  required bool allowEmptySignature,
}) {
  // Redacted thinking: pass the opaque payload back as redacted_thinking.
  if (block.redacted) {
    return {'type': 'redacted_thinking', 'data': block.thinkingSignature};
  }
  final signature = block.thinkingSignature;
  final hasSignature = signature != null && signature.trim().isNotEmpty;
  if (block.thinking.trim().isEmpty && !hasSignature) {
    return null;
  }
  // If the thinking signature is missing/empty (e.g., from an
  // aborted stream), convert to plain text for Anthropic. Some
  // compatible providers emit and accept empty signatures, so let
  // marked models preserve the block.
  if (!hasSignature) {
    return allowEmptySignature
        ? {'type': 'thinking', 'thinking': block.thinking, 'signature': ''}
        : {'type': 'text', 'text': block.thinking};
  }
  return {
    'type': 'thinking',
    'thinking': block.thinking,
    'signature': signature,
  };
}

/// Collects the run of consecutive [ToolResultMessage]s starting at
/// [startIndex] into a single user message of tool_result blocks (Anthropic
/// requires this grouping). Returns it plus the index of the last consumed
/// message so the caller can skip ahead.
({Map<String, dynamic> message, int lastIndex}) _convertToolResultGroup(
  List<Message> messages,
  int startIndex,
) {
  final toolResults = <Map<String, dynamic>>[];
  var j = startIndex;
  for (; j < messages.length && messages[j] is ToolResultMessage; j++) {
    final toolMessage = messages[j] as ToolResultMessage;
    toolResults.add({
      'type': 'tool_result',
      'tool_use_id': _normalizeToolCallId(toolMessage.toolCallId),
      'content': _convertContentBlocks(toolMessage.content),
      'is_error': toolMessage.isError,
    });
  }
  return (message: {'role': 'user', 'content': toolResults}, lastIndex: j - 1);
}

/// Adds a cache breakpoint to the last user message to cache conversation
/// history: onto its last text/image/tool_result block when it is a block
/// list, or by wrapping a plain-string content into one.
void _applyCacheControlToLastUserMessage(
  Map<String, dynamic> lastMessage,
  Map<String, dynamic> cacheControl,
) {
  if (lastMessage['role'] != 'user') {
    return;
  }
  final content = lastMessage['content'];
  if (content is List && content.isNotEmpty) {
    _applyCacheControlToBlockList(content, cacheControl);
  } else if (content is String) {
    lastMessage['content'] = [
      {'type': 'text', 'text': content, 'cache_control': cacheControl},
    ];
  }
}

/// Sets the cache breakpoint on the last block of a user content list when
/// it is a text/image/tool_result block.
void _applyCacheControlToBlockList(
  List<dynamic> content,
  Map<String, dynamic> cacheControl,
) {
  final lastBlock = content.last;
  if (lastBlock is Map &&
      (lastBlock['type'] == 'text' ||
          lastBlock['type'] == 'image' ||
          lastBlock['type'] == 'tool_result')) {
    lastBlock['cache_control'] = cacheControl;
  }
}

List<Map<String, dynamic>> _convertTools(
  List<Tool> tools, {
  required bool supportsEagerToolInputStreaming,
  Map<String, dynamic>? cacheControl,
}) {
  return [
    for (var index = 0; index < tools.length; index++)
      {
        'name': tools[index].name,
        'description': tools[index].description,
        if (supportsEagerToolInputStreaming) 'eager_input_streaming': true,
        'input_schema': {
          'type': 'object',
          'properties':
              tools[index].parameters['properties'] ??
              const <String, dynamic>{},
          'required': tools[index].parameters['required'] ?? const <String>[],
        },
        // Cache breakpoint on the last tool, per pi.
        if (cacheControl != null && index == tools.length - 1)
          'cache_control': cacheControl,
      },
  ];
}

({StopReason reason, String? errorMessage}) _mapStopReason(
  String reason,
  Map<String, dynamic>? stopDetails,
) {
  return switch (reason) {
    'end_turn' => (reason: StopReason.stop, errorMessage: null),
    'max_tokens' => (reason: StopReason.length, errorMessage: null),
    'tool_use' => (reason: StopReason.toolUse, errorMessage: null),
    'refusal' => (
      reason: StopReason.error,
      errorMessage:
          stopDetails?['explanation'] as String? ??
          'The model refused to complete the request',
    ),
    // Stop is good enough -> resubmit.
    'pause_turn' => (reason: StopReason.stop, errorMessage: null),
    // We don't supply stop sequences, so this should never happen.
    'stop_sequence' => (reason: StopReason.stop, errorMessage: null),
    // Content flagged by safety filters.
    'sensitive' => (reason: StopReason.error, errorMessage: null),
    // Handle unknown stop reasons gracefully (API may add new values).
    _ => throw StateError('Unhandled stop reason: $reason'),
  };
}
