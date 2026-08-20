/// Google Generative AI provider adapter.
///
/// Ported from pi-mono `packages/ai/src/api/google-generative-ai.ts` and
/// `packages/ai/src/api/google-shared.ts` (`convertMessages`, `convertTools`,
/// `mapToolChoice`, `mapStopReasonString`, thought-signature helpers). Kept
/// mechanically close to the TypeScript originals so future pi fixes port
/// trivially. Deliberate divergences:
///
/// - pi uses the `@google/genai` SDK; this port talks to
///   `POST {baseUrl}/models/{modelId}:streamGenerateContent?alt=sse` directly
///   with `package:http` and decodes the data-only SSE stream via
///   [SseDecoder]. The SDK-shaped flat `config` becomes the REST body:
///   `generationConfig` (temperature, maxOutputTokens, thinkingConfig),
///   top-level `systemInstruction`, `tools`, and `toolConfig`.
/// - The SDK sends the API key as an `x-goog-api-key` header; so does this
///   port (the `?key=` query-param alternative is not used).
/// - pi consumes SDK-parsed chunks; this port parses raw JSON, so finish
///   reasons go through pi's `mapStopReasonString` (STOP → stop,
///   MAX_TOKENS → length, anything else → error).
/// - pi accumulates into one mutable `AssistantMessage`; Dart types are
///   immutable, so every pushed event carries a freshly built snapshot of the
///   live partial message instead (same partial-first contract).
/// - Not yet ported (later phases): `streamSimple` and its thinking-level
///   clamping/budget maps (`getThinkingLevel`, `getGoogleBudget`),
///   `transformMessages` reordering, surrogate sanitization, OAuth/Vertex
///   (`google-vertex.ts`), and the Cloud Code Assist specifics beyond
///   [GoogleOptions.useParameters].
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../json_parse.dart';
import '../model.dart';
import '../types.dart';
import 'provider_common.dart';

// Counter for generating unique tool call IDs (ported from pi's module-level
// `toolCallCounter`).
var _toolCallCounter = 0;

/// Thinking configuration for Gemini models.
///
/// Ported from pi's `GoogleOptions.thinking`.
final class GoogleThinking {
  /// Creates a thinking configuration.
  const GoogleThinking({required this.enabled, this.budgetTokens, this.level});

  /// Whether thinking is enabled. When false on a reasoning model, the
  /// adapter sends the model-specific disable config (pi's
  /// `getDisabledThinkingConfig`).
  final bool enabled;

  /// Token budget for thinking; `-1` for dynamic, `0` to disable. Ignored
  /// when [level] is set.
  final int? budgetTokens;

  /// Thinking level for Gemini 3 models, mirroring Google's `ThinkingLevel`
  /// enum values: `MINIMAL`, `LOW`, `MEDIUM`, `HIGH`.
  final String? level;
}

/// Options for [streamGoogle].
///
/// Ported subset of pi's `GoogleOptions` (which extends `StreamOptions`):
/// temperature, maxTokens, apiKey, headers, signal, thinking, toolChoice,
/// onPayload, onResponse. pi's `signal: AbortSignal` is [cancelToken] here.
final class GoogleOptions {
  /// Creates Google options.
  const GoogleOptions({
    this.temperature,
    this.maxTokens,
    this.apiKey,
    this.headers,
    this.cancelToken,
    this.thinking,
    this.toolChoice,
    this.useParameters = false,
    this.onPayload,
    this.onResponse,
  });

  /// Sampling temperature, sent as `generationConfig.temperature`.
  final double? temperature;

  /// Output-token cap, sent as `generationConfig.maxOutputTokens`.
  final int? maxTokens;

  /// API key sent as `x-goog-api-key: ...` (what pi's `@google/genai` SDK
  /// does). Falls back to an `x-goog-api-key` or `authorization` entry in
  /// [headers] (key then unused), else the stream fails with an error event.
  final String? apiKey;

  /// Extra request headers, merged over [Model.headers]; a `null` value
  /// suppresses the header with the same name (pi's `ProviderHeaders`).
  final Map<String, String?>? headers;

  /// Cancels the in-flight request when triggered. The stream then ends with
  /// an [ErrorEvent] whose reason is [StopReason.aborted].
  final CancelToken? cancelToken;

  /// Thinking configuration; only sent when [Model.reasoning] is true.
  final GoogleThinking? thinking;

  /// Tool choice: `'auto'`, `'none'`, or `'any'`, mapped to Gemini's
  /// `FunctionCallingConfigMode` (`AUTO` / `NONE` / `ANY`). Only sent when
  /// the context has tools, per pi.
  final String? toolChoice;

  /// Use the legacy `parameters` field (OpenAPI 3.03 Schema, sanitized via
  /// pi's `sanitizeForOpenApi`) instead of `parametersJsonSchema` in
  /// function declarations. Needed for Cloud Code Assist with Claude models,
  /// where the API translates `parameters` into Anthropic's `input_schema`
  /// (pi's `convertTools(tools, useParameters)`).
  final bool useParameters;

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

/// Streams an assistant message from a Google Generative AI endpoint.
///
/// Ported from pi's `stream` in `google-generative-ai.ts`. The endpoint is
/// `{model.baseUrl}/models/{modelId}:streamGenerateContent?alt=sse` (default
/// base URL `https://generativelanguage.googleapis.com/v1beta` on the model
/// descriptor).
///
/// **Errors-as-events invariant (non-negotiable):** this function never
/// throws. Network failures, non-200 responses, provider error chunks,
/// malformed SSE, and aborts all terminate the returned stream with an
/// [ErrorEvent] carrying [StopReason.error] or [StopReason.aborted].
///
/// [client] overrides the HTTP client (used by tests with
/// `http.testing.MockClient`); when omitted, an owned client is created and
/// closed when the stream finishes.
AssistantMessageEventStream streamGoogle(
  Model model,
  Context context, [
  GoogleOptions? options,
  http.Client? client,
]) {
  final eventStream = AssistantMessageEventStream();
  final cancelToken = options?.cancelToken;
  // No injected client: the shared keep-alive client (never closed per call).
  final httpClient = client ?? sharedProviderHttpClient();

  // Blocks accumulate in the shared state holder; each event carries a
  // fresh immutable snapshot of them (pi mutates one `output` object).
  final state = ProviderStreamState(model);

  unawaited(
    runProviderStream(
      eventStream,
      state,
      cancelToken,
      httpClient,
      ownsClient: false, // shared or injected — never closed per call
      body: () async {
        final apiKey = _getClientApiKey(
          model.provider,
          options?.apiKey,
          options?.headers,
        );

        http.Request buildRequest(Map<String, dynamic> params) =>
            http.Request(
                'POST',
                Uri.parse(
                  '${model.baseUrl}/models/${model.id}'
                  ':streamGenerateContent?alt=sse',
                ),
              )
              ..headers.addAll(_buildHeaders(model, options, apiKey))
              ..body = jsonEncode(params);

        final params = await applyPayloadHook(
          _buildParams(model, context, options),
          model,
          options?.onPayload,
        );

        cancelToken?.throwIfCancelled();

        http.StreamedResponse response;
        try {
          response = await startProviderResponse(
            eventStream,
            state,
            httpClient,
            buildRequest(params),
            cancelToken,
            options?.onResponse,
          );
        } on ProviderHttpError catch (error) {
          // Two Gemini 400s are recoverable by rewriting the request and
          // retrying ONCE — the turn survives and the model can explain the
          // situation to the user instead of dying with a raw API error:
          //
          // 1. 'Unable to process input image': an inline image the backend
          //    cannot decode → every image downgraded to placeholder text.
          // 2. 'missing a thought_signature': a replayed functionCall whose
          //    signature was never captured / dropped / belongs to another
          //    model → the tool call and its result become plain text notes.
          final List<Message>? retryMessages;
          if (_isUndecodableImageError(error) &&
              messagesContainImages(context.messages)) {
            retryMessages = downgradeUndecodableImages(context.messages);
          } else if (_isMissingThoughtSignatureError(error) &&
              _hasUnreplayableToolCall(context.messages, model)) {
            retryMessages = _textifyUnreplayableToolCalls(
              context.messages,
              model,
            );
          } else {
            retryMessages = null;
          }
          if (retryMessages == null) rethrow;

          final retryContext = Context(
            systemPrompt: context.systemPrompt,
            messages: retryMessages,
            tools: context.tools,
          );
          final retryParams = await applyPayloadHook(
            _buildParams(model, retryContext, options),
            model,
            options?.onPayload,
          );
          cancelToken?.throwIfCancelled();
          response = await startProviderResponse(
            eventStream,
            state,
            httpClient,
            buildRequest(retryParams),
            cancelToken,
            options?.onResponse,
          );
        }

        // pi tracks `currentBlock` (the open text/thinking block) inline;
        // here that cursor lives in the chunk handler.
        final handler = _GoogleChunkHandler(eventStream, state, model);

        await _consumeSseStream(response, cancelToken, handler);

        handler.endCurrentBlock();

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
      },
    ),
  );

  return eventStream;
}

/// Consumes the SSE body of [response], decoding each `data:` event into a
/// JSON chunk and feeding it to [handler]. Extracted verbatim from
/// [streamGoogle]'s stream body (pi's chunk loop).
Future<void> _consumeSseStream(
  http.StreamedResponse response,
  CancelToken? cancelToken,
  _GoogleChunkHandler handler,
) async {
  final iterator = createSseIterator(response, cancelToken);

  while (await iterator.moveNext()) {
    final data = iterator.current.data.trim();
    if (data.isEmpty) {
      continue;
    }

    final Map<String, dynamic> chunk;
    try {
      final parsed = parseJsonWithRepair(data);
      if (parsed is! Map<String, dynamic>) {
        throw const FormatException('SSE data is not a JSON object');
      }
      chunk = parsed;
    } catch (error) {
      throw StateError('Could not parse Google SSE event: $error');
    }

    handler.processChunk(chunk);
  }
}

/// Per-request SSE chunk handler for [streamGoogle]: owns the open-block
/// cursor (pi's `currentBlock`) and translates raw `streamGenerateContent`
/// chunks into pushed events. Extracted mechanically from `streamGoogle`'s
/// stream body (pi's chunk loop).
final class _GoogleChunkHandler {
  _GoogleChunkHandler(this._eventStream, this._state, this._model);

  final AssistantMessageEventStream _eventStream;
  final ProviderStreamState _state;
  final Model _model;

  List<StreamingBlock> get _blocks => _state.blocks;

  /// pi tracks `currentBlock` (the open text/thinking block); tool-call
  /// parts close it and emit their events immediately.
  StreamingBlock? _currentBlock;

  int _blockIndex() => _blocks.length - 1;

  /// Closes the open text/thinking block, if any.
  void endCurrentBlock() {
    final block = _currentBlock;
    if (block != null) {
      pushBlockEndEvent(_eventStream, _blocks, block, _state.snapshot);
      _currentBlock = null;
    }
  }

  /// Handles one decoded SSE chunk: provider errors, the response id, the
  /// first candidate (content parts + finish reason), and usage metadata.
  void processChunk(Map<String, dynamic> chunk) {
    _throwIfErrorChunk(chunk);
    _retainResponseId(chunk);

    final candidate = _firstCandidate(chunk);
    if (candidate != null) {
      _processCandidate(candidate);
    }

    final usageMetadata = chunk['usageMetadata'];
    if (usageMetadata is Map<String, dynamic>) {
      _processUsage(usageMetadata);
    }
  }

  /// Provider errors arrive as chunks with an `error` object; they abort the
  /// stream by throwing (pi: `chunk.error` check in the chunk loop).
  void _throwIfErrorChunk(Map<String, dynamic> chunk) {
    final error = chunk['error'];
    if (error is Map) {
      final message = error['message'];
      throw StateError(message is String ? message : jsonEncode(error));
    }
  }

  /// Keep the first non-empty response id (pi: `output.responseId ||=
  /// chunk.responseId`).
  void _retainResponseId(Map<String, dynamic> chunk) {
    final responseId = chunk['responseId'];
    if (responseId is String && responseId.isNotEmpty) {
      _state.responseId ??= responseId;
    }
  }

  /// Returns the first candidate of the chunk, or null when the `candidates`
  /// list is missing, empty, or its first entry is not an object.
  Map<String, dynamic>? _firstCandidate(Map<String, dynamic> chunk) {
    final candidates = chunk['candidates'];
    final candidate = candidates is List && candidates.isNotEmpty
        ? candidates.first
        : null;
    return candidate is Map<String, dynamic> ? candidate : null;
  }

  /// Translates one candidate: its content parts and its finish reason.
  void _processCandidate(Map<String, dynamic> candidate) {
    final content = candidate['content'];
    final parts = content is Map ? content['parts'] : null;
    if (parts is List) {
      for (final rawPart in parts) {
        if (rawPart is! Map<String, dynamic>) {
          continue;
        }
        _processPart(rawPart);
      }
    }

    final finishReason = candidate['finishReason'];
    if (finishReason is String) _processFinishReason(finishReason);
  }

  /// Translates a candidate's terminal finish reason. Terminal reasons that
  /// do not map onto [StopReason] are provider errors, never a silent
  /// success; the raw value stays diagnosable via
  /// [AssistantMessage.rawStopReason] and the error message.
  void _processFinishReason(String finishReason) {
    _state.rawStopReason = finishReason;
    final mapped = _mapStopReason(finishReason);
    if (mapped == StopReason.error) {
      _state.errorMessage ??= 'Provider finishReason: $finishReason';
    }
    _state.stopReason = mapped;
    if (_blocks.any((b) => b is ToolCallStreamingBlock)) {
      _state.stopReason = StopReason.toolUse;
    }
  }

  /// Translates one content part: a text/thought part and/or a function
  /// call part.
  void _processPart(Map<String, dynamic> rawPart) {
    final text = rawPart['text'];
    if (text is String) {
      _processTextPart(text, rawPart);
    }

    final functionCall = rawPart['functionCall'];
    if (functionCall is Map<String, dynamic>) {
      _processFunctionCallPart(rawPart, functionCall);
    }
  }

  /// Appends a text/thought delta, opening a fresh block when the block
  /// kind switches (text ↔ thinking) and retaining thought signatures.
  void _processTextPart(String text, Map<String, dynamic> rawPart) {
    final isThinking = rawPart['thought'] == true;
    // Some Gemma models return their reasoning as raw `<thought>…</thought>`
    // tags inside the plain-text body (no `thought: true` JSON marker).
    // Strip them and route the inner text to a ThinkingStreamingBlock so
    // the UI can render it as a collapsed thinking note instead of
    // leaking it into the assistant bubble.
    final thoughtSignature = rawPart['thoughtSignature'] as String?;
    final (plain, thoughts) = _splitThoughts(text);
    if (thoughts.isNotEmpty) {
      _processTextChunk(thoughts, isThinking: true, thoughtSignature: null);
    }
    if (plain.isNotEmpty || !isThinking) {
      _processTextChunk(
        plain,
        isThinking: isThinking,
        thoughtSignature: thoughtSignature,
      );
    }
  }

  /// Writes one chunk of text into the right block type.
  void _processTextChunk(
    String text, {
    required bool isThinking,
    String? thoughtSignature,
  }) {
    if (_currentBlock == null ||
        (isThinking && _currentBlock is! ThinkingStreamingBlock) ||
        (!isThinking && _currentBlock is! TextStreamingBlock)) {
      endCurrentBlock();
      _openTextBlock(isThinking);
    }
    _appendTextDelta(_currentBlock!, text, thoughtSignature);
  }

  /// Splits [text] on `<thought>…</thought>` tags. Returns the plain
  /// text (tags removed) and the concatenated thinking content.
  /// Unclosed tags are dropped (streaming can split them mid-tag).
  (String, String) _splitThoughts(String text) {
    final plain = StringBuffer();
    final thoughts = StringBuffer();
    var cursor = 0;
    while (true) {
      final open = text.indexOf('<thought>', cursor);
      if (open < 0) {
        plain.write(text.substring(cursor));
        break;
      }
      plain.write(text.substring(cursor, open));
      final close = text.indexOf('</thought>', open);
      if (close < 0) {
        // Unclosed tag — treat the remainder as plain text (Gemma
        // sometimes truncates mid-tag on short streams).
        plain.write(text.substring(open));
        break;
      }
      thoughts.write(text.substring(open + 9, close));
      cursor = close + 10;
    }
    return (plain.toString(), thoughts.toString());
  }

  /// Opens a fresh thinking or text block and pushes its start event.
  void _openTextBlock(bool isThinking) {
    if (isThinking) {
      _currentBlock = ThinkingStreamingBlock();
      _blocks.add(_currentBlock!);
      _eventStream.push(
        ThinkingStartEvent(
          contentIndex: _blockIndex(),
          partial: _state.snapshot(),
        ),
      );
    } else {
      _currentBlock = TextStreamingBlock();
      _blocks.add(_currentBlock!);
      _eventStream.push(
        TextStartEvent(contentIndex: _blockIndex(), partial: _state.snapshot()),
      );
    }
  }

  /// Writes [text] into the open block, retains its thought signature, and
  /// pushes the matching delta event.
  void _appendTextDelta(
    StreamingBlock block,
    String text,
    String? thoughtSignature,
  ) {
    if (block is ThinkingStreamingBlock) {
      block.thinking.write(text);
      block.signature = _retainThoughtSignature(
        block.signature,
        thoughtSignature,
      );
      _eventStream.push(
        ThinkingDeltaEvent(
          contentIndex: _blockIndex(),
          delta: text,
          partial: _state.snapshot(),
        ),
      );
    } else if (block is TextStreamingBlock) {
      block.text.write(text);
      block.textSignature = _retainThoughtSignature(
        block.textSignature,
        thoughtSignature,
      );
      _eventStream.push(
        TextDeltaEvent(
          contentIndex: _blockIndex(),
          delta: text,
          partial: _state.snapshot(),
        ),
      );
    }
  }

  /// Emits a complete tool-call block (start + args delta + end) for a
  /// `functionCall` part, closing the open text/thinking block first.
  void _processFunctionCallPart(
    Map<String, dynamic> rawPart,
    Map<String, dynamic> functionCall,
  ) {
    endCurrentBlock();

    // Generate a unique ID if not provided or if it's a duplicate (ported
    // from pi).
    final providedId = functionCall['id'] as String?;
    final needsNewId =
        providedId == null ||
        _blocks.any((b) => b is ToolCallStreamingBlock && b.id == providedId);
    final name = functionCall['name'] as String? ?? '';
    final toolCallId = needsNewId
        ? '${name}_${DateTime.now().millisecondsSinceEpoch}'
              '_${_toolCallCounter += 1}'
        : providedId;

    final arguments = functionCall['args'] is Map<String, dynamic>
        ? functionCall['args'] as Map<String, dynamic>
        : const <String, dynamic>{};
    final block = ToolCallStreamingBlock(id: toolCallId, name: name)
      ..thoughtSignature = rawPart['thoughtSignature'] as String?;
    final argsJson = jsonEncode(arguments);
    block.partialArgs.write(argsJson);

    _blocks.add(block);
    _eventStream.push(
      ToolCallStartEvent(
        contentIndex: _blockIndex(),
        partial: _state.snapshot(),
      ),
    );
    _eventStream.push(
      ToolCallDeltaEvent(
        contentIndex: _blockIndex(),
        delta: argsJson,
        partial: _state.snapshot(),
      ),
    );
    pushBlockEndEvent(_eventStream, _blocks, block, _state.snapshot);
  }

  /// Applies `usageMetadata` to the running usage/cost totals.
  void _processUsage(Map<String, dynamic> usageMetadata) {
    final prompt = usageMetadata['promptTokenCount'] as int? ?? 0;
    final cached = usageMetadata['cachedContentTokenCount'] as int? ?? 0;
    final candidatesTokens = usageMetadata['candidatesTokenCount'] as int? ?? 0;
    final thoughts = usageMetadata['thoughtsTokenCount'] as int? ?? 0;
    _state.usage = calculateCost(
      Usage(
        input: prompt - cached,
        output: candidatesTokens + thoughts,
        cacheRead: cached,
        cacheWrite: 0,
        reasoning: thoughts,
        totalTokens: usageMetadata['totalTokenCount'] as int? ?? 0,
        cost: const UsageCost(),
      ),
      _model,
    );
  }
}

/// Ported from pi's API-key requirement: an explicit API key wins; otherwise
/// the caller must have supplied an auth header themselves.
String? _getClientApiKey(
  String provider,
  String? apiKey,
  Map<String, String?>? headers,
) {
  if (apiKey != null) {
    return apiKey;
  }
  if (hasHeader(headers, 'x-goog-api-key') ||
      hasHeader(headers, 'authorization')) {
    return null;
  }
  throw StateError('No API key for provider: $provider');
}

Map<String, String> _buildHeaders(
  Model model,
  GoogleOptions? options,
  String? apiKey,
) {
  // Ported from pi's `createClient` (API-key path): the `@google/genai` SDK
  // injects the key as an `x-goog-api-key` header.
  return mergeProviderHeaders(
    {'content-type': 'application/json', 'x-goog-api-key': ?apiKey},
    model.headers,
    options?.headers,
  );
}

/// Ported from pi's `buildParams`. The SDK's flat `config` maps to the REST
/// body as `generationConfig` (temperature, maxOutputTokens, thinkingConfig)
/// plus top-level `systemInstruction`, `tools`, and `toolConfig`.
Map<String, dynamic> _buildParams(
  Model model,
  Context context,
  GoogleOptions? options,
) {
  final params = <String, dynamic>{
    'contents': _convertMessages(model, context),
  };

  if (context.systemPrompt != null) {
    params['systemInstruction'] = {
      'parts': [
        {'text': context.systemPrompt},
      ],
    };
  }

  _addToolsParams(params, context, options);

  final generationConfig = _buildGenerationConfig(model, options);
  if (generationConfig.isNotEmpty) {
    params['generationConfig'] = generationConfig;
  }

  return params;
}

/// Adds the top-level `tools` and `toolConfig` params (ported from pi's
/// `buildParams` tools branch).
void _addToolsParams(
  Map<String, dynamic> params,
  Context context,
  GoogleOptions? options,
) {
  final tools = context.tools;
  if (tools != null && tools.isNotEmpty) {
    params['tools'] = _convertTools(
      tools,
      useParameters: options?.useParameters ?? false,
    );
    if (options?.toolChoice != null) {
      params['toolConfig'] = {
        'functionCallingConfig': {'mode': _mapToolChoice(options!.toolChoice!)},
      };
    }
  }
}

/// Builds the `generationConfig` map: temperature, maxOutputTokens, and the
/// thinking config (ported from pi's `buildParams` config mapping).
Map<String, dynamic> _buildGenerationConfig(
  Model model,
  GoogleOptions? options,
) {
  final generationConfig = <String, dynamic>{};
  if (options?.temperature != null) {
    generationConfig['temperature'] = options!.temperature;
  }
  if (options?.maxTokens != null) {
    generationConfig['maxOutputTokens'] = options!.maxTokens;
  }

  final thinkingConfig = _buildThinkingConfig(model, options?.thinking);
  if (thinkingConfig != null) {
    generationConfig['thinkingConfig'] = thinkingConfig;
  }

  return generationConfig;
}

/// Builds the `thinkingConfig` map for a reasoning model, or null when no
/// thinking options apply (ported from pi's `buildParams` thinking branch).
Map<String, dynamic>? _buildThinkingConfig(
  Model model,
  GoogleThinking? thinking,
) {
  if (thinking == null || !model.reasoning) {
    return null;
  }
  if (!thinking.enabled) {
    return _getDisabledThinkingConfig(model);
  }
  return {
    'includeThoughts': true,
    if (thinking.level != null)
      'thinkingLevel': thinking.level
    else if (thinking.budgetTokens != null)
      'thinkingBudget': thinking.budgetTokens,
  };
}

/// Ported from pi's `isGemini3ProModel`.
bool _isGemini3ProModel(String modelId) {
  return RegExp(r'gemini-3(?:\.\d+)?-pro').hasMatch(modelId.toLowerCase());
}

/// Ported from pi's `isGemini3FlashModel`.
bool _isGemini3FlashModel(String modelId) {
  final id = modelId.toLowerCase();
  return RegExp(r'gemini-3(?:\.\d+)?-flash').hasMatch(id) ||
      id == 'gemini-flash-latest' ||
      id == 'gemini-flash-lite-latest';
}

/// Ported from pi's `isGemma4Model`.
bool _isGemma4Model(String modelId) {
  return RegExp(r'gemma-?4').hasMatch(modelId.toLowerCase());
}

/// Ported from pi's `getDisabledThinkingConfig`: Gemini 3 models cannot
/// fully disable thinking, so the lowest supported `thinkingLevel` is used
/// (without `includeThoughts`); Gemini 2.x supports `thinkingBudget: 0`.
Map<String, dynamic> _getDisabledThinkingConfig(Model model) {
  if (_isGemini3ProModel(model.id)) {
    return {'thinkingLevel': 'LOW'};
  }
  if (_isGemini3FlashModel(model.id) || _isGemma4Model(model.id)) {
    return {'thinkingLevel': 'MINIMAL'};
  }
  return {'thinkingBudget': 0};
}

/// Models via Google APIs that require explicit tool call IDs in function
/// calls/responses.
///
/// Ported from pi's `requiresToolCallId`.
bool _requiresToolCallId(String modelId) {
  return modelId.startsWith('claude-') || modelId.startsWith('gpt-oss-');
}

/// Ported from pi's `normalizeToolCallId` (applied inside
/// `transformMessages` there; applied at conversion time here).
String _normalizeToolCallId(String id) {
  final sanitized = id.replaceAll(RegExp('[^a-zA-Z0-9_-]'), '_');
  return sanitized.length > 64 ? sanitized.substring(0, 64) : sanitized;
}

int? _getGeminiMajorVersion(String modelId) {
  final match = RegExp(
    r'^gemini(?:-live)?-(\d+)',
  ).firstMatch(modelId.toLowerCase());
  if (match == null) {
    return null;
  }
  return int.tryParse(match.group(1)!);
}

/// Ported from pi's `supportsMultimodalFunctionResponse`.
bool _supportsMultimodalFunctionResponse(String modelId) {
  final geminiMajorVersion = _getGeminiMajorVersion(modelId);
  if (geminiMajorVersion != null) {
    return geminiMajorVersion >= 3;
  }
  return true;
}

// Thought signatures must be base64 for Google APIs (TYPE_BYTES).
final _base64SignaturePattern = RegExp(r'^[A-Za-z0-9+/]+={0,2}$');

/// Ported from pi's `isValidThoughtSignature`.
bool _isValidThoughtSignature(String? signature) {
  if (signature == null || signature.isEmpty) {
    return false;
  }
  if (signature.length % 4 != 0) {
    return false;
  }
  return _base64SignaturePattern.hasMatch(signature);
}

/// Only keep signatures from the same provider/model and with valid base64.
///
/// Ported from pi's `resolveThoughtSignature`.
String? _resolveThoughtSignature(bool isSameProviderAndModel, String? sig) {
  return isSameProviderAndModel && _isValidThoughtSignature(sig) ? sig : null;
}

/// Retain thought signatures during streaming: some backends only send
/// `thoughtSignature` on the first delta of a block; keep the last non-empty
/// one.
///
/// Ported from pi's `retainThoughtSignature`.
String? _retainThoughtSignature(String? existing, String? incoming) {
  if (incoming != null && incoming.isNotEmpty) {
    return incoming;
  }
  return existing;
}

/// Converts internal messages to Gemini `Content[]` format.
///
/// Ported from pi's `convertMessages`. The image-downgrade half of pi's
/// `transformMessages` pre-pass runs first via [downgradeUnsupportedImages];
/// the tool-call-id normalization half still happens at conversion time.
List<Map<String, dynamic>> _convertMessages(Model model, Context context) {
  final contents = <Map<String, dynamic>>[];
  final includeId = _requiresToolCallId(model.id);

  for (final message in downgradeUnsupportedImages(context.messages, model)) {
    if (message is UserMessage) {
      final content = _convertUserMessage(message);
      if (content != null) {
        contents.add(content);
      }
    } else if (message is AssistantMessage) {
      final content = _convertAssistantMessage(message, model, includeId);
      if (content != null) {
        contents.add(content);
      }
    } else if (message is ToolResultMessage) {
      _appendToolResultMessage(contents, message, model, includeId);
    }
  }

  return contents;
}

/// Converts a user message to a Gemini user `Content`, or null when it has
/// no convertible parts. Ported from pi's `convertMessages` user branch.
Map<String, dynamic>? _convertUserMessage(UserMessage message) {
  final content = message.content;
  if (content is String) {
    return {
      'role': 'user',
      'parts': [
        {'text': content},
      ],
    };
  }
  final parts = <Map<String, dynamic>>[];
  for (final item in content as List<ContentBlock>) {
    switch (item) {
      case TextContent():
        parts.add({'text': item.text});
      case ImageContent():
        parts.add(_convertImageContent(item));
      case ThinkingContent() || ToolCall():
        // Not valid in user messages; skip defensively.
        break;
    }
  }
  if (parts.isEmpty) {
    return null;
  }
  return {'role': 'user', 'parts': parts};
}

/// Converts an assistant message to a Gemini model `Content`, or null when
/// it has no convertible parts. Ported from pi's `convertMessages` assistant
/// branch.
Map<String, dynamic>? _convertAssistantMessage(
  AssistantMessage message,
  Model model,
  bool includeId,
) {
  final parts = <Map<String, dynamic>>[];
  // Only keep thinking blocks/signatures when the message is from the
  // same provider and model.
  final isSameProviderAndModel =
      message.provider == model.provider && message.model == model.id;

  for (final block in message.content) {
    final part = _convertAssistantBlock(
      block,
      isSameProviderAndModel,
      includeId,
    );
    if (part != null) {
      parts.add(part);
    }
  }

  if (parts.isEmpty) {
    return null;
  }
  return {'role': 'model', 'parts': parts};
}

/// Converts one assistant content block to a Gemini part, or null when the
/// block is skipped (empty text/thinking, invalid image). Ported from pi's
/// `convertMessages` assistant-block switch.
Map<String, dynamic>? _convertAssistantBlock(
  ContentBlock block,
  bool isSameProviderAndModel,
  bool includeId,
) {
  return switch (block) {
    TextContent() => _convertAssistantTextBlock(block, isSameProviderAndModel),
    ThinkingContent() => _convertAssistantThinkingBlock(
      block,
      isSameProviderAndModel,
    ),
    ToolCall() => _convertAssistantToolCallBlock(
      block,
      isSameProviderAndModel,
      includeId,
    ),
    // Not valid in assistant messages; skip defensively.
    ImageContent() => null,
  };
}

/// Ported from pi's assistant-block `TextContent` case.
Map<String, dynamic>? _convertAssistantTextBlock(
  TextContent block,
  bool isSameProviderAndModel,
) {
  final thoughtSignature = _resolveThoughtSignature(
    isSameProviderAndModel,
    block.textSignature,
  );
  // Skip empty text blocks — unless they carry a thought signature. Gemini
  // can attach the signature to a part whose visible text is empty and
  // requires it echoed back; dropping it breaks the reasoning chain and the
  // next request fails with the 400 'missing a thought_signature' on the
  // replayed functionCall (pi keeps such parts for the same reason).
  if (block.text.trim().isEmpty && thoughtSignature == null) {
    return null;
  }
  return {'text': block.text, 'thoughtSignature': ?thoughtSignature};
}

/// Ported from pi's assistant-block `ThinkingContent` case.
Map<String, dynamic>? _convertAssistantThinkingBlock(
  ThinkingContent block,
  bool isSameProviderAndModel,
) {
  if (isSameProviderAndModel) {
    final thoughtSignature = _resolveThoughtSignature(
      isSameProviderAndModel,
      block.thinkingSignature,
    );
    // Same rule as text blocks: an empty thinking block is dropped only
    // when it carries no signature — Gemini needs signature-bearing parts
    // echoed back verbatim (see _convertAssistantTextBlock).
    if (block.thinking.trim().isEmpty && thoughtSignature == null) {
      return null;
    }
    return {
      'thought': true,
      'text': block.thinking,
      'thoughtSignature': ?thoughtSignature,
    };
  }
  // Other provider/model: convert to plain text (no tags to
  // avoid the model mimicking them).
  return {'text': block.thinking};
}

/// Ported from pi's assistant-block `ToolCall` case.
Map<String, dynamic> _convertAssistantToolCallBlock(
  ToolCall block,
  bool isSameProviderAndModel,
  bool includeId,
) {
  final thoughtSignature = _resolveThoughtSignature(
    isSameProviderAndModel,
    block.thoughtSignature,
  );
  return {
    'functionCall': {
      'name': block.name,
      'args': block.arguments,
      if (includeId) 'id': _normalizeToolCallId(block.id),
    },
    'thoughtSignature': ?thoughtSignature,
  };
}

/// Extracts the joined text of a tool result (pi: text blocks joined with
/// newlines).
String _toolResultText(ToolResultMessage message) {
  return [
    for (final block in message.content)
      if (block is TextContent) block.text,
  ].join('\n');
}

/// Extracts the images of a tool result when the model accepts image input.
List<ImageContent> _toolResultImages(ToolResultMessage message, Model model) {
  return [
    for (final block in message.content)
      if (block is ImageContent && model.input.contains('image')) block,
  ];
}

/// Builds the `functionResponse` part for a tool result. Uses the "output"
/// key for success, the "error" key for errors, per the SDK documentation.
/// Ported from pi's `convertMessages` tool-result branch.
Map<String, dynamic> _buildFunctionResponsePart(
  ToolResultMessage message,
  String responseValue,
  List<Map<String, dynamic>> imageParts, {
  required bool hasImages,
  required bool multimodal,
  required bool includeId,
}) {
  return {
    'functionResponse': {
      'name': message.toolName,
      'response': message.isError
          ? {'error': responseValue}
          : {'output': responseValue},
      if (hasImages && multimodal) 'parts': imageParts,
      if (includeId) 'id': _normalizeToolCallId(message.toolCallId),
    },
  };
}

/// Cloud Code Assist requires all function responses in a single user
/// turn: merge into the previous user turn of function responses.
void _appendFunctionResponsePart(
  List<Map<String, dynamic>> contents,
  Map<String, dynamic> functionResponsePart,
) {
  final lastContent = contents.isNotEmpty ? contents.last : null;
  final lastParts = lastContent?['parts'];
  if (lastContent?['role'] == 'user' &&
      lastParts is List &&
      lastParts.any((p) => p is Map && p.containsKey('functionResponse'))) {
    lastParts.add(functionResponsePart);
  } else {
    contents.add({
      'role': 'user',
      'parts': [functionResponsePart],
    });
  }
}

/// Converts a tool result into Gemini function-response user turn(s):
/// merges into a previous function-response user turn and, for Gemini < 3,
/// appends images in a separate user message. Ported from pi's
/// `convertMessages` tool-result branch.
void _appendToolResultMessage(
  List<Map<String, dynamic>> contents,
  ToolResultMessage message,
  Model model,
  bool includeId,
) {
  final textResult = _toolResultText(message);
  final imageContent = _toolResultImages(message, model);

  final hasText = textResult.isNotEmpty;
  final hasImages = imageContent.isNotEmpty;

  // Gemini 3+ supports images nested inside functionResponse.parts;
  // Gemini < 3 needs a separate user image turn (ported from pi).
  final multimodal = _supportsMultimodalFunctionResponse(model.id);

  final responseValue = hasText
      ? textResult
      : hasImages
      ? '(see attached image)'
      : '';

  final imageParts = [
    for (final image in imageContent) _convertImageContent(image),
  ];

  final functionResponsePart = _buildFunctionResponsePart(
    message,
    responseValue,
    imageParts,
    hasImages: hasImages,
    multimodal: multimodal,
    includeId: includeId,
  );

  _appendFunctionResponsePart(contents, functionResponsePart);

  // For Gemini < 3, add images in a separate user message.
  if (hasImages && !multimodal) {
    contents.add({
      'role': 'user',
      'parts': [
        {'text': 'Tool result image:'},
        ...imageParts,
      ],
    });
  }
}

const _jsonSchemaMetaDeclarations = {
  r'$schema',
  r'$id',
  r'$anchor',
  r'$dynamicAnchor',
  r'$vocabulary',
  r'$comment',
  r'$defs',
  'definitions', // pre-draft-2019-09 equivalent of $defs
};

/// Strips JSON-Schema meta-declarations from a schema object.
///
/// Ported from pi's `sanitizeForOpenApi`.
Object? _sanitizeForOpenApi(Object? schema) {
  if (schema is! Map) {
    return schema;
  }
  final result = <String, dynamic>{};
  for (final entry in schema.entries) {
    if (entry.key is String &&
        _jsonSchemaMetaDeclarations.contains(entry.key)) {
      continue;
    }
    result[entry.key.toString()] = _sanitizeForOpenApi(entry.value);
  }
  return result;
}

/// Converts tools to Gemini function-declarations format.
///
/// Ported from pi's `convertTools`. By default uses `parametersJsonSchema`
/// (full JSON Schema); with `useParameters` the legacy `parameters` field
/// (sanitized OpenAPI 3.03 Schema) is used instead.
List<Map<String, dynamic>> _convertTools(
  List<Tool> tools, {
  bool useParameters = false,
}) {
  return [
    {
      'functionDeclarations': [
        for (final tool in tools)
          {
            'name': tool.name,
            'description': tool.description,
            if (useParameters)
              'parameters': _sanitizeForOpenApi(tool.parameters)
            else
              'parametersJsonSchema': tool.parameters,
          },
      ],
    },
  ];
}

/// Maps a tool-choice string to Gemini's `FunctionCallingConfigMode`.
///
/// Ported from pi's `mapToolChoice`.
String _mapToolChoice(String choice) {
  return switch (choice) {
    'auto' => 'AUTO',
    'none' => 'NONE',
    'any' => 'ANY',
    _ => 'AUTO',
  };
}

/// Maps a raw string finish reason to our [StopReason].
///
/// Ported from pi's `mapStopReasonString` (used for raw API responses).
StopReason _mapStopReason(String reason) {
  return switch (reason) {
    'STOP' => StopReason.stop,
    'MAX_TOKENS' => StopReason.length,
    _ => StopReason.error,
  };
}

/// Whether [error] is Gemini's undecodable-image rejection (HTTP 400 with
/// the fixed message `Unable to process input image`). Only this exact
/// failure justifies the placeholder-retry — every other 400 (bad schema,
/// thought-signature violations, …) must surface unchanged.
bool _isUndecodableImageError(ProviderHttpError error) =>
    error.statusCode == 400 &&
    error.body.contains('Unable to process input image');

/// Whether [error] is Gemini's missing-thought-signature rejection of a
/// replayed functionCall (HTTP 400, message `Function call is missing a
/// thought_signature …`). Only this exact failure justifies the
/// textify-retry below.
bool _isMissingThoughtSignatureError(ProviderHttpError error) =>
    error.statusCode == 400 &&
    error.body.contains('missing a thought_signature');

/// Whether [messages] holds an assistant tool call that would replay
/// WITHOUT a thought signature on its functionCall part: no signature, an
/// invalid (non-base64) one, or one from a different provider/model — such
/// signatures are dropped by [_convertAssistantToolCallBlock], and Gemini 3
/// rejects the replay with [_isMissingThoughtSignatureError].
bool _hasUnreplayableToolCall(List<Message> messages, Model model) {
  for (final message in messages) {
    if (message is! AssistantMessage) continue;
    final sameProviderAndModel =
        message.provider == model.provider && message.model == model.id;
    for (final block in message.content) {
      if (block is ToolCall &&
          !(sameProviderAndModel &&
              _isValidThoughtSignature(block.thoughtSignature))) {
        return true;
      }
    }
  }
  return false;
}

/// Rewrites [messages] so no unreplayable tool call survives as a native
/// functionCall part: the [ToolCall] block becomes a text note on the
/// assistant message, and its [ToolResultMessage] becomes a user message
/// carrying the tool output as text. Signed, same-model tool calls stay
/// native. The model keeps full knowledge of what was called and what came
/// back, so the turn can continue (it may simply re-call the tool) instead
/// of dying with Gemini's missing-thought-signature 400.
List<Message> _textifyUnreplayableToolCalls(
  List<Message> messages,
  Model model,
) {
  final droppedCallIds = <String>{};
  final result = <Message>[];
  for (final message in messages) {
    if (message is AssistantMessage) {
      final sameProviderAndModel =
          message.provider == model.provider && message.model == model.id;
      var changed = false;
      final content = <ContentBlock>[];
      for (final block in message.content) {
        if (block is ToolCall &&
            !(sameProviderAndModel &&
                _isValidThoughtSignature(block.thoughtSignature))) {
          droppedCallIds.add(block.id);
          changed = true;
          content.add(
            TextContent(
              text:
                  '(tool call omitted: ${block.name}'
                  '(${jsonEncode(block.arguments)}) — its thought signature '
                  'was not replayable)',
            ),
          );
        } else {
          content.add(block);
        }
      }
      result.add(
        changed
            ? AssistantMessage(
                content: content,
                api: message.api,
                provider: message.provider,
                model: message.model,
                responseModel: message.responseModel,
                responseId: message.responseId,
                usage: message.usage,
                stopReason: message.stopReason,
                rawStopReason: message.rawStopReason,
                errorMessage: message.errorMessage,
                timestamp: message.timestamp,
              )
            : message,
      );
    } else if (message is ToolResultMessage &&
        droppedCallIds.contains(message.toolCallId)) {
      // Tool results always follow their assistant message, so a single
      // pass suffices. The functionResponse would reference a functionCall
      // that no longer exists — convert it to a user-turn text note.
      final text = [
        for (final block in message.content)
          if (block is TextContent) block.text,
      ].join('\n');
      final images = [
        for (final block in message.content)
          if (block is ImageContent) block,
      ];
      result.add(
        UserMessage(
          content: [
            TextContent(
              text:
                  '(result of the omitted ${message.toolName} tool call:)'
                  '\n$text',
            ),
            ...images,
          ],
          timestamp: message.timestamp,
        ),
      );
    } else {
      result.add(message);
    }
  }
  return result;
}

/// Converts one [ImageContent] to a Gemini `inlineData` part. PNG images
/// are re-encoded as JPEG (quality 95) — Gemma's vision encoder rejects
/// PNGs with alpha channels or EXIF orientation metadata; JPEG strips
/// both. Non-PNG images pass through unchanged.
Map<String, dynamic> _convertImageContent(ImageContent item) {
  final mimeType = item.mimeType.toLowerCase();
  if (mimeType != 'image/png') {
    return {
      'inlineData': {'mimeType': item.mimeType, 'data': item.data},
    };
  }
  try {
    final decoded = img.decodePng(base64Decode(item.data));
    if (decoded == null) return _passthrough(item);
    final jpegBytes = img.encodeJpg(decoded, quality: 95);
    return {
      'inlineData': {'mimeType': 'image/jpeg', 'data': base64Encode(jpegBytes)},
    };
  } on Object {
    return _passthrough(item);
  }
}

Map<String, dynamic> _passthrough(ImageContent item) => {
  'inlineData': {'mimeType': item.mimeType, 'data': item.data},
};
