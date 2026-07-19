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
  final httpClient = client ?? http.Client();

  // Blocks accumulate in the shared state holder; each event carries a
  // fresh immutable snapshot of them (pi mutates one `output` object).
  final state = ProviderStreamState(model);
  final blocks = state.blocks;

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
        final params = await applyPayloadHook(
          _buildParams(model, context, options),
          model,
          options?.onPayload,
        );

        cancelToken?.throwIfCancelled();

        final request =
            http.Request(
                'POST',
                Uri.parse(
                  '${model.baseUrl}/models/${model.id}'
                  ':streamGenerateContent?alt=sse',
                ),
              )
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

        // pi tracks `currentBlock` (the open text/thinking block); tool-call
        // parts close it and emit their events immediately.
        StreamingBlock? currentBlock;
        int blockIndex() => blocks.length - 1;

        void endCurrentBlock() {
          final block = currentBlock;
          if (block != null) {
            pushBlockEndEvent(eventStream, blocks, block, state.snapshot);
            currentBlock = null;
          }
        }

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

          final error = chunk['error'];
          if (error is Map) {
            final message = error['message'];
            throw StateError(message is String ? message : jsonEncode(error));
          }

          // Keep the first non-empty response id (pi: `output.responseId ||=
          // chunk.responseId`).
          final responseId = chunk['responseId'];
          if (responseId is String && responseId.isNotEmpty) {
            state.responseId ??= responseId;
          }

          final candidates = chunk['candidates'];
          final candidate = candidates is List && candidates.isNotEmpty
              ? candidates.first
              : null;
          if (candidate is Map<String, dynamic>) {
            final content = candidate['content'];
            final parts = content is Map ? content['parts'] : null;
            if (parts is List) {
              for (final rawPart in parts) {
                if (rawPart is! Map<String, dynamic>) {
                  continue;
                }

                final text = rawPart['text'];
                if (text is String) {
                  final isThinking = rawPart['thought'] == true;
                  if (currentBlock == null ||
                      (isThinking && currentBlock is! ThinkingStreamingBlock) ||
                      (!isThinking && currentBlock is! TextStreamingBlock)) {
                    endCurrentBlock();
                    if (isThinking) {
                      currentBlock = ThinkingStreamingBlock();
                      blocks.add(currentBlock!);
                      eventStream.push(
                        ThinkingStartEvent(
                          contentIndex: blockIndex(),
                          partial: state.snapshot(),
                        ),
                      );
                    } else {
                      currentBlock = TextStreamingBlock();
                      blocks.add(currentBlock!);
                      eventStream.push(
                        TextStartEvent(
                          contentIndex: blockIndex(),
                          partial: state.snapshot(),
                        ),
                      );
                    }
                  }
                  final thoughtSignature =
                      rawPart['thoughtSignature'] as String?;
                  final block = currentBlock!;
                  if (block is ThinkingStreamingBlock) {
                    block.thinking.write(text);
                    block.signature = _retainThoughtSignature(
                      block.signature,
                      thoughtSignature,
                    );
                    eventStream.push(
                      ThinkingDeltaEvent(
                        contentIndex: blockIndex(),
                        delta: text,
                        partial: state.snapshot(),
                      ),
                    );
                  } else if (block is TextStreamingBlock) {
                    block.text.write(text);
                    block.textSignature = _retainThoughtSignature(
                      block.textSignature,
                      thoughtSignature,
                    );
                    eventStream.push(
                      TextDeltaEvent(
                        contentIndex: blockIndex(),
                        delta: text,
                        partial: state.snapshot(),
                      ),
                    );
                  }
                }

                final functionCall = rawPart['functionCall'];
                if (functionCall is Map<String, dynamic>) {
                  endCurrentBlock();

                  // Generate a unique ID if not provided or if it's a
                  // duplicate (ported from pi).
                  final providedId = functionCall['id'] as String?;
                  final needsNewId =
                      providedId == null ||
                      blocks.any(
                        (b) =>
                            b is ToolCallStreamingBlock && b.id == providedId,
                      );
                  final name = functionCall['name'] as String? ?? '';
                  final toolCallId = needsNewId
                      ? '${name}_${DateTime.now().millisecondsSinceEpoch}'
                            '_${_toolCallCounter += 1}'
                      : providedId;

                  final arguments = functionCall['args'] is Map<String, dynamic>
                      ? functionCall['args'] as Map<String, dynamic>
                      : const <String, dynamic>{};
                  final block = ToolCallStreamingBlock(
                    id: toolCallId,
                    name: name,
                  )..thoughtSignature = rawPart['thoughtSignature'] as String?;
                  final argsJson = jsonEncode(arguments);
                  block.partialArgs.write(argsJson);

                  blocks.add(block);
                  eventStream.push(
                    ToolCallStartEvent(
                      contentIndex: blockIndex(),
                      partial: state.snapshot(),
                    ),
                  );
                  eventStream.push(
                    ToolCallDeltaEvent(
                      contentIndex: blockIndex(),
                      delta: argsJson,
                      partial: state.snapshot(),
                    ),
                  );
                  pushBlockEndEvent(eventStream, blocks, block, state.snapshot);
                }
              }
            }

            final finishReason = candidate['finishReason'];
            if (finishReason is String) {
              state.stopReason = _mapStopReason(finishReason);
              if (blocks.any((b) => b is ToolCallStreamingBlock)) {
                state.stopReason = StopReason.toolUse;
              }
            }
          }

          final usageMetadata = chunk['usageMetadata'];
          if (usageMetadata is Map<String, dynamic>) {
            final prompt = usageMetadata['promptTokenCount'] as int? ?? 0;
            final cached =
                usageMetadata['cachedContentTokenCount'] as int? ?? 0;
            final candidatesTokens =
                usageMetadata['candidatesTokenCount'] as int? ?? 0;
            final thoughts = usageMetadata['thoughtsTokenCount'] as int? ?? 0;
            state.usage = calculateCost(
              Usage(
                input: prompt - cached,
                output: candidatesTokens + thoughts,
                cacheRead: cached,
                cacheWrite: 0,
                reasoning: thoughts,
                totalTokens: usageMetadata['totalTokenCount'] as int? ?? 0,
                cost: const UsageCost(),
              ),
              model,
            );
          }
        }

        endCurrentBlock();

        if (cancelToken?.isCancelled ?? false) {
          throw const AbortedError();
        }
        if (state.stopReason == StopReason.aborted ||
            state.stopReason == StopReason.error) {
          throw StateError('An unknown error occurred');
        }

        eventStream.push(
          DoneEvent(reason: state.stopReason, message: state.snapshot()),
        );
      },
    ),
  );

  return eventStream;
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

  final generationConfig = <String, dynamic>{};
  if (options?.temperature != null) {
    generationConfig['temperature'] = options!.temperature;
  }
  if (options?.maxTokens != null) {
    generationConfig['maxOutputTokens'] = options!.maxTokens;
  }

  if (context.systemPrompt != null) {
    params['systemInstruction'] = {
      'parts': [
        {'text': context.systemPrompt},
      ],
    };
  }

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

  final thinking = options?.thinking;
  if (thinking != null && model.reasoning) {
    if (thinking.enabled) {
      generationConfig['thinkingConfig'] = {
        'includeThoughts': true,
        if (thinking.level != null)
          'thinkingLevel': thinking.level
        else if (thinking.budgetTokens != null)
          'thinkingBudget': thinking.budgetTokens,
      };
    } else {
      generationConfig['thinkingConfig'] = _getDisabledThinkingConfig(model);
    }
  }

  if (generationConfig.isNotEmpty) {
    params['generationConfig'] = generationConfig;
  }

  return params;
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
  String normalizeId(String id) => includeId ? _normalizeToolCallId(id) : id;

  for (final message in downgradeUnsupportedImages(context.messages, model)) {
    if (message is UserMessage) {
      final content = message.content;
      if (content is String) {
        contents.add({
          'role': 'user',
          'parts': [
            {'text': content},
          ],
        });
      } else {
        final parts = <Map<String, dynamic>>[];
        for (final item in content as List<ContentBlock>) {
          switch (item) {
            case TextContent():
              parts.add({'text': item.text});
            case ImageContent():
              parts.add({
                'inlineData': {'mimeType': item.mimeType, 'data': item.data},
              });
            case ThinkingContent() || ToolCall():
              // Not valid in user messages; skip defensively.
              break;
          }
        }
        if (parts.isEmpty) {
          continue;
        }
        contents.add({'role': 'user', 'parts': parts});
      }
    } else if (message is AssistantMessage) {
      final parts = <Map<String, dynamic>>[];
      // Only keep thinking blocks/signatures when the message is from the
      // same provider and model.
      final isSameProviderAndModel =
          message.provider == model.provider && message.model == model.id;

      for (final block in message.content) {
        switch (block) {
          case TextContent():
            // Skip empty text blocks.
            if (block.text.trim().isEmpty) {
              continue;
            }
            final thoughtSignature = _resolveThoughtSignature(
              isSameProviderAndModel,
              block.textSignature,
            );
            parts.add({
              'text': block.text,
              'thoughtSignature': ?thoughtSignature,
            });
          case ThinkingContent():
            // Skip empty thinking blocks.
            if (block.thinking.trim().isEmpty) {
              continue;
            }
            if (isSameProviderAndModel) {
              final thoughtSignature = _resolveThoughtSignature(
                isSameProviderAndModel,
                block.thinkingSignature,
              );
              parts.add({
                'thought': true,
                'text': block.thinking,
                'thoughtSignature': ?thoughtSignature,
              });
            } else {
              // Other provider/model: convert to plain text (no tags to
              // avoid the model mimicking them).
              parts.add({'text': block.thinking});
            }
          case ToolCall():
            final thoughtSignature = _resolveThoughtSignature(
              isSameProviderAndModel,
              block.thoughtSignature,
            );
            parts.add({
              'functionCall': {
                'name': block.name,
                'args': block.arguments,
                if (includeId) 'id': normalizeId(block.id),
              },
              'thoughtSignature': ?thoughtSignature,
            });
          case ImageContent():
            // Not valid in assistant messages; skip defensively.
            break;
        }
      }

      if (parts.isEmpty) {
        continue;
      }
      contents.add({'role': 'model', 'parts': parts});
    } else if (message is ToolResultMessage) {
      final textResult = [
        for (final block in message.content)
          if (block is TextContent) block.text,
      ].join('\n');
      final imageContent = [
        for (final block in message.content)
          if (block is ImageContent && model.input.contains('image')) block,
      ];

      final hasText = textResult.isNotEmpty;
      final hasImages = imageContent.isNotEmpty;

      // Gemini 3+ supports images nested inside functionResponse.parts;
      // Gemini < 3 needs a separate user image turn (ported from pi).
      final multimodal = _supportsMultimodalFunctionResponse(model.id);

      // Use "output" key for success, "error" key for errors, per the SDK
      // documentation.
      final responseValue = hasText
          ? textResult
          : hasImages
          ? '(see attached image)'
          : '';

      final imageParts = [
        for (final image in imageContent)
          {
            'inlineData': {'mimeType': image.mimeType, 'data': image.data},
          },
      ];

      final functionResponsePart = {
        'functionResponse': {
          'name': message.toolName,
          'response': message.isError
              ? {'error': responseValue}
              : {'output': responseValue},
          if (hasImages && multimodal) 'parts': imageParts,
          if (includeId) 'id': normalizeId(message.toolCallId),
        },
      };

      // Cloud Code Assist requires all function responses in a single user
      // turn: merge into the previous user turn of function responses.
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
  }

  return contents;
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
