/// Shared internals for provider adapters: request-header merging, HTTP
/// error carriers, error formatting, the mutable stream state, the HTTP
/// send/abort race, SSE wiring, block-end dispatch, and the terminal error
/// event — everything that is identical across the pi provider ports.
///
/// Internal to the package: not exported from `flutter_agent_harness.dart`.
/// Extracted so the provider ports stay mechanically close to their pi
/// originals without duplicating code (the pre-commit duplication gate is
/// < 1%).
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

/// Placeholder substituted for user-message images when the target model has
/// no `image` input (pi's `NON_VISION_USER_IMAGE_PLACEHOLDER`).
const nonVisionUserImagePlaceholder =
    '(image omitted: model does not support images)';

/// Placeholder substituted for tool-result images when the target model has
/// no `image` input (pi's `NON_VISION_TOOL_IMAGE_PLACEHOLDER`).
const nonVisionToolImagePlaceholder =
    '(tool image omitted: model does not support images)';

/// pi's `replaceImagesWithPlaceholder`: consecutive images collapse into a
/// single placeholder, and a text block already equal to the placeholder
/// suppresses a duplicate.
List<ContentBlock> _replaceImagesWithPlaceholder(
  List<ContentBlock> content,
  String placeholder,
) {
  final result = <ContentBlock>[];
  var previousWasPlaceholder = false;
  for (final block in content) {
    if (block is ImageContent) {
      if (!previousWasPlaceholder) {
        result.add(TextContent(text: placeholder));
      }
      previousWasPlaceholder = true;
      continue;
    }
    result.add(block);
    previousWasPlaceholder = block is TextContent && block.text == placeholder;
  }
  return result;
}

/// Replaces image blocks with explicit placeholder text when [model] has no
/// `image` input, so nothing is dropped silently at request time.
///
/// Ported from the `downgradeUnsupportedImages` half of pi's
/// `transformMessages` pre-pass (transform-messages.ts): user messages and
/// tool results get distinct placeholders; the image bytes stay in the
/// session transcript, only the request payload is rewritten. Each adapter
/// runs this at the top of its message conversion.
List<Message> downgradeUnsupportedImages(List<Message> messages, Model model) {
  if (model.input.contains('image')) {
    return messages;
  }
  return [
    for (final message in messages)
      if (message is UserMessage && message.content is List<ContentBlock>)
        UserMessage(
          content: _replaceImagesWithPlaceholder(
            message.content as List<ContentBlock>,
            nonVisionUserImagePlaceholder,
          ),
          timestamp: message.timestamp,
        )
      else if (message is ToolResultMessage)
        ToolResultMessage(
          toolCallId: message.toolCallId,
          toolName: message.toolName,
          content: _replaceImagesWithPlaceholder(
            message.content,
            nonVisionToolImagePlaceholder,
          ),
          isError: message.isError,
          timestamp: message.timestamp,
        )
      else
        message,
  ];
}

/// Whether [headers] contains a non-empty value for [name]
/// (case-insensitive).
///
/// Ported from pi's `hasHeader`.
bool hasHeader(Map<String, String?>? headers, String name) {
  if (headers == null) {
    return false;
  }
  final expected = name.toLowerCase();
  for (final entry in headers.entries) {
    final value = entry.value;
    if (entry.key.toLowerCase() == expected &&
        value != null &&
        value.trim().isNotEmpty) {
      return true;
    }
  }
  return false;
}

/// Merges request headers: [defaults] first, then [modelHeaders], then
/// [optionsHeaders]. An option header with a `null` value suppresses the
/// header with the same name (pi's `ProviderHeaders` semantics).
Map<String, String> mergeProviderHeaders(
  Map<String, String> defaults,
  Map<String, String>? modelHeaders,
  Map<String, String?>? optionsHeaders,
) {
  final headers = <String, String>{...defaults, ...?modelHeaders};
  if (optionsHeaders != null) {
    for (final entry in optionsHeaders.entries) {
      final value = entry.value;
      if (value == null) {
        headers.remove(entry.key);
      } else {
        headers[entry.key] = value;
      }
    }
  }
  return headers;
}

/// Runs an adapter's `onPayload` hook, returning the replacement payload or
/// [params] unchanged when the hook is absent or returns `null`.
Future<Map<String, dynamic>> applyPayloadHook(
  Map<String, dynamic> params,
  Model model,
  FutureOr<Map<String, dynamic>?> Function(Map<String, dynamic>, Model)?
  onPayload,
) async {
  final nextParams = await onPayload?.call(params, model);
  return nextParams ?? params;
}

/// Thrown internally when a `CancelToken` fires; caught and converted into an
/// aborted `ErrorEvent`. Never escapes an adapter.
final class AbortedError implements Exception {
  /// Creates an abort marker error.
  const AbortedError();
}

/// A non-200 HTTP response, carrying the status and raw body for error
/// reporting (the Dart counterpart of the SDK error objects pi normalizes).
final class ProviderHttpError implements Exception {
  /// Creates an HTTP error with [statusCode] and raw response [body].
  ///
  /// [retryAfter] is the provider-suggested wait parsed from the
  /// `Retry-After` response header, when present and parseable.
  const ProviderHttpError(this.statusCode, this.body, {this.retryAfter});

  /// The HTTP status code.
  final int statusCode;

  /// The raw response body.
  final String body;

  /// The provider-suggested delay before retrying (parsed from the
  /// `Retry-After` header), typically set on HTTP 429 responses.
  final Duration? retryAfter;
}

/// Parses a `Retry-After` header value into a [Duration].
///
/// Supports both forms defined by RFC 9110 (and handled by pi's
/// `getRetryAfterDelayMs`): delta-seconds (`"120"`) and an HTTP date
/// (`"Wed, 21 Oct 2015 07:28:00 GMT"`, also ISO-8601 as a fallback). The
/// result is clamped to be non-negative. Returns `null` for absent or
/// unparseable values.
Duration? parseRetryAfter(String? value, {DateTime? now}) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  final seconds = int.tryParse(trimmed);
  if (seconds != null) {
    return Duration(seconds: seconds < 0 ? 0 : seconds);
  }
  final date = _parseHttpDate(trimmed) ?? DateTime.tryParse(trimmed);
  if (date == null) {
    return null;
  }
  final delta = date.difference(now ?? DateTime.now());
  return delta.isNegative ? Duration.zero : delta;
}

const _httpMonths = {
  'jan': 1,
  'feb': 2,
  'mar': 3,
  'apr': 4,
  'may': 5,
  'jun': 6,
  'jul': 7,
  'aug': 8,
  'sep': 9,
  'oct': 10,
  'nov': 11,
  'dec': 12,
};

final _httpDatePattern = RegExp(
  r'^[A-Za-z]{3}, (\d{2}) ([A-Za-z]{3}) (\d{4}) (\d{2}):(\d{2}):(\d{2}) GMT$',
);

/// Parses the IMF-fixdate form of an HTTP date
/// (`Wed, 21 Oct 2015 07:28:00 GMT`). Returns `null` for anything else.
DateTime? _parseHttpDate(String value) {
  final match = _httpDatePattern.firstMatch(value);
  if (match == null) {
    return null;
  }
  final month = _httpMonths[match[2]!.toLowerCase()];
  if (month == null) {
    return null;
  }
  return DateTime.utc(
    int.parse(match[3]!),
    month,
    int.parse(match[1]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}

/// Composes the display string for an `ErrorEvent.errorMessage`.
///
/// Simplified port of pi's `formatProviderError(normalizeProviderError(e))`:
/// there is no SDK whose error shapes need probing here.
String formatProviderError(Object error) {
  if (error is ProviderHttpError) {
    final body = error.body.trim();
    if (body.isEmpty) {
      return 'Request failed with status ${error.statusCode}';
    }
    return '${error.statusCode}: $body';
  }
  if (error is http.ClientException) {
    return error.message;
  }
  if (error is StateError) {
    return error.message;
  }
  if (error is FormatException) {
    return error.message;
  }
  return error.toString();
}

/// Sends [request], racing [cancelToken] (abort wins), and validates the
/// response status.
///
/// Throws [AbortedError] when the token fires before the headers arrive and
/// [ProviderHttpError] on a non-200 status (with the body consumed for the
/// error message). The adapter's try/catch turns both into error events.
Future<http.StreamedResponse> sendProviderRequest(
  http.Client httpClient,
  http.Request request,
  CancelToken? cancelToken,
) async {
  final responseFuture = httpClient.send(request);
  final http.StreamedResponse response;
  if (cancelToken == null) {
    response = await responseFuture;
  } else {
    response = await Future.any([
      responseFuture,
      cancelToken.onCancel.then<http.StreamedResponse>(
        (_) => throw const AbortedError(),
      ),
    ]);
  }

  if (response.statusCode != 200) {
    final body = await response.stream.bytesToString();
    throw ProviderHttpError(
      response.statusCode,
      body,
      retryAfter: parseRetryAfter(response.headers['retry-after']),
    );
  }
  return response;
}

/// Wires an SSE [StreamIterator] over [response]'s body, cancelling the
/// subscription when [cancelToken] fires so the connection closes promptly.
///
/// Cancellation through the `async*` [SseDecoder] is lazy: the cancel future
/// only completes once the generator body resumes, so the response-body
/// subscription can still be active when `runProviderStream` force-closes
/// the owned HTTP client on abort. The injected "connection closed" error
/// is therefore swallowed here whenever [cancelToken] is cancelled; real
/// mid-stream errors (token not cancelled) propagate to the adapter's
/// try/catch unchanged.
StreamIterator<ServerSentEvent> createSseIterator(
  http.StreamedResponse response,
  CancelToken? cancelToken,
) {
  Stream<List<int>> stream = response.stream;
  if (cancelToken != null) {
    stream = stream.handleError((Object error) {
      if (!cancelToken.isCancelled) {
        throw error;
      }
    });
  }
  final iterator = StreamIterator(
    stream.transform(utf8.decoder).transform(const SseDecoder()),
  );
  if (cancelToken != null) {
    unawaited(cancelToken.onCancel.then((_) => unawaited(iterator.cancel())));
  }
  return iterator;
}

/// Mutable accumulation state for one streamed assistant message.
///
/// pi mutates a single `output` object; Dart types are immutable, so adapters
/// keep the pieces here and build an immutable [snapshot] per event instead
/// (same partial-first contract).
final class ProviderStreamState {
  /// Creates stream state for [model].
  ProviderStreamState(this.model);

  /// The model being called.
  final Model model;

  /// Ordered content blocks accumulated so far.
  final blocks = <StreamingBlock>[];

  /// When the stream started (pi stores Unix milliseconds).
  final timestamp = DateTime.now();

  /// Token/cost accounting as last reported by the provider.
  var usage = Usage.zero;

  /// Why the stream terminated (best guess until the terminal event).
  var stopReason = StopReason.stop;

  /// Failure description for error/aborted terminal events.
  String? errorMessage;

  /// Provider-specific response/message identifier, when exposed upstream.
  String? responseId;

  /// Concrete model id reported by the provider, when different from the
  /// requested one (e.g. OpenRouter `auto` routing).
  String? responseModel;

  /// Builds the immutable [AssistantMessage] carried by event snapshots.
  ///
  /// With [finalize] the blocks strip streaming scratch state (used for the
  /// terminal error snapshot after an abort or failure mid-stream).
  AssistantMessage snapshot({bool finalize = false}) => AssistantMessage(
    content: [
      for (final block in blocks) block.toContentBlock(finalize: finalize),
    ],
    api: model.api,
    provider: model.provider,
    model: model.id,
    responseModel: responseModel,
    responseId: responseId,
    usage: usage,
    stopReason: stopReason,
    errorMessage: errorMessage,
    timestamp: timestamp,
  );
}

/// Mutable streaming accumulation for one content block. Converted into an
/// immutable [ContentBlock] for every event snapshot.
sealed class StreamingBlock {
  /// Converts to the immutable [ContentBlock] carried by event snapshots.
  ///
  /// With [finalize] the block strips streaming scratch state (used for the
  /// terminal error snapshot after an abort or failure mid-stream).
  ContentBlock toContentBlock({bool finalize = false});
}

/// Accumulating text content block.
final class TextStreamingBlock extends StreamingBlock {
  /// Provider-specific opaque signature for this block (Google
  /// `thoughtSignature` on a text part), when reported.
  String? textSignature;

  /// The accumulated text.
  final text = StringBuffer();

  @override
  ContentBlock toContentBlock({bool finalize = false}) {
    return TextContent(text: text.toString(), textSignature: textSignature);
  }
}

/// Accumulating thinking (reasoning) content block.
final class ThinkingStreamingBlock extends StreamingBlock {
  /// Creates a thinking block.
  ///
  /// [signature] is the provider-specific thinking signature, when known up
  /// front (OpenAI-style reasoning field name); Anthropic accumulates it via
  /// `signature_delta` events instead and mutates [signature]. [initialText]
  /// seeds fixed text (Anthropic redacted thinking).
  ThinkingStreamingBlock({
    this.signature,
    this.redacted = false,
    String initialText = '',
  }) {
    thinking.write(initialText);
  }

  /// The thinking signature, if any.
  String? signature;

  /// Whether the thinking content was redacted by safety filters (Anthropic
  /// `redacted_thinking`; the opaque payload sits in [signature]).
  final bool redacted;

  /// The accumulated thinking text.
  final thinking = StringBuffer();

  @override
  ContentBlock toContentBlock({bool finalize = false}) {
    return ThinkingContent(
      thinking: thinking.toString(),
      thinkingSignature: signature,
      redacted: redacted,
    );
  }
}

/// Accumulating tool-call block with partial JSON arguments.
final class ToolCallStreamingBlock extends StreamingBlock {
  /// Creates a tool-call block.
  ToolCallStreamingBlock({
    required this.id,
    required this.name,
    this.streamIndex,
    this.initialArguments,
  });

  /// Provider-assigned tool call id.
  String id;

  /// Name of the tool to invoke.
  String name;

  /// The provider's stream index for this call (OpenAI `tool_calls[].index`),
  /// when the protocol identifies blocks by index rather than id.
  int? streamIndex;

  /// Provider-specific opaque thought signature (OpenRouter encrypted
  /// reasoning detail attached to this call).
  String? thoughtSignature;

  /// Arguments already parsed by the provider at block start (Anthropic
  /// `tool_use` blocks can carry a complete `input`). Used when no argument
  /// deltas ever arrive.
  final Map<String, dynamic>? initialArguments;

  /// The accumulated raw JSON argument text.
  final partialArgs = StringBuffer();

  /// Parsed arguments, filled in by [finish].
  Map<String, dynamic> arguments = const <String, dynamic>{};

  /// Whether [finish] has run (the block's end event was seen).
  var finished = false;

  /// Parses the accumulated [partialArgs] into [arguments] and marks the
  /// block finished. Called when the provider signals the block's end.
  void finish() {
    arguments = partialArgs.isEmpty && initialArguments != null
        ? initialArguments!
        : parseStreamingJson(partialArgs.toString());
    finished = true;
  }

  @override
  ContentBlock toContentBlock({bool finalize = false}) {
    if (finalize && !finished) {
      // Stream ended before the block's end event (error/abort): best-effort
      // parse and strip the scratch buffer, mirroring pi's catch block.
      return ToolCall(
        id: id,
        name: name,
        arguments: partialArgs.isEmpty && initialArguments != null
            ? initialArguments!
            : parseStreamingJson(partialArgs.toString()),
        thoughtSignature: thoughtSignature,
      );
    }
    if (finished) {
      return ToolCall(
        id: id,
        name: name,
        arguments: arguments,
        thoughtSignature: thoughtSignature,
      );
    }
    return ToolCall(
      id: id,
      name: name,
      arguments: const <String, dynamic>{},
      thoughtSignature: thoughtSignature,
      partialArguments: partialArgs.toString(),
    );
  }
}

/// Pushes the end event for [block] (text, thinking, or tool call) at its
/// position in [blocks].
///
/// Shared by the adapters: pi fires `text_end` / `thinking_end` /
/// `toolcall_end` identically across providers.
void pushBlockEndEvent(
  AssistantMessageEventStream eventStream,
  List<StreamingBlock> blocks,
  StreamingBlock block,
  AssistantMessage Function() snapshot,
) {
  final index = blocks.indexOf(block);
  if (index == -1) {
    return;
  }
  switch (block) {
    case TextStreamingBlock():
      eventStream.push(
        TextEndEvent(
          contentIndex: index,
          content: block.text.toString(),
          partial: snapshot(),
        ),
      );
    case ThinkingStreamingBlock():
      eventStream.push(
        ThinkingEndEvent(
          contentIndex: index,
          content: block.thinking.toString(),
          partial: snapshot(),
        ),
      );
    case ToolCallStreamingBlock():
      block.finish();
      final partial = snapshot();
      eventStream.push(
        ToolCallEndEvent(
          contentIndex: index,
          toolCall: partial.content[index] as ToolCall,
          partial: partial,
        ),
      );
  }
}

/// Converts a caught [error] into the terminal `ErrorEvent`
/// (errors-as-events invariant): aborts get [StopReason.aborted], everything
/// else [StopReason.error].
void pushStreamErrorEvent(
  AssistantMessageEventStream eventStream,
  ProviderStreamState state,
  Object error,
  CancelToken? cancelToken,
) {
  final aborted =
      error is AbortedError ||
      error is CancelledException ||
      (cancelToken?.isCancelled ?? false);
  final reason = aborted ? StopReason.aborted : StopReason.error;
  state.stopReason = reason;
  state.errorMessage = aborted
      ? 'Request was aborted'
      : formatProviderError(error);
  final retryAfter = !aborted && error is ProviderHttpError
      ? error.retryAfter
      : null;
  eventStream.push(
    ErrorEvent(
      reason: reason,
      error: state.snapshot(finalize: true),
      retryAfter: retryAfter,
    ),
  );
}

/// Runs a provider adapter's streaming [body] under the shared terminal
/// protocol: any caught error becomes an `ErrorEvent` via
/// [pushStreamErrorEvent] (errors-as-events invariant), the stream is always
/// ended, and the owned HTTP client is closed.
///
/// pi wraps each adapter body in the same try/catch; the wrapper exists so
/// the adapters do not duplicate it.
Future<void> runProviderStream(
  AssistantMessageEventStream eventStream,
  ProviderStreamState state,
  CancelToken? cancelToken,
  http.Client httpClient, {
  required bool ownsClient,
  required Future<void> Function() body,
}) async {
  try {
    await body();
  } catch (error) {
    pushStreamErrorEvent(eventStream, state, error, cancelToken);
  } finally {
    eventStream.end();
    if (ownsClient) {
      httpClient.close();
    }
  }
}

/// Sends [request] (via [sendProviderRequest]), runs the adapter's
/// `onResponse` hook, and pushes the `StartEvent` with the initial snapshot.
///
/// Shared by the adapters: pi fires `start` right after the response headers
/// arrive, before the body stream is consumed.
Future<http.StreamedResponse> startProviderResponse(
  AssistantMessageEventStream eventStream,
  ProviderStreamState state,
  http.Client httpClient,
  http.Request request,
  CancelToken? cancelToken,
  FutureOr<void> Function(int statusCode, Map<String, String> headers, Model)?
  onResponse,
) async {
  final response = await sendProviderRequest(httpClient, request, cancelToken);
  await onResponse?.call(response.statusCode, response.headers, state.model);
  eventStream.push(StartEvent(partial: state.snapshot()));
  return response;
}
