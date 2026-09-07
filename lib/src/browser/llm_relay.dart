/// Keyless-proxy LLM relay (issue #34 item 3, §S6): the extension sends an
/// `llmReq` frame; the bridge resolves the provider key SERVER-SIDE (the
/// key never appeared in any frame), streams the completion through the
/// provider, and answers with correlated `llmRes` frames — `{delta}` per
/// chunk, then `{done: true}`, or `{error}`.
///
/// Pure Dart: the frame glue ([BridgeLlmRelay]) never touches dart:io or
/// a key store — key resolution and the actual provider call are injected.
/// [relayOpenAiCompletion] is the real transport, built on the provider
/// path's own primitives (`sendProviderRequest` + `createSseIterator`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../providers/provider_common.dart';
import '../sse_decoder.dart';
import 'bridge_protocol.dart';

/// One decoded relay request: `{req: {baseUrl, model, messages, provider?}}`.
/// [provider] (the saved entry name) disambiguates the key slot when
/// several accounts share an endpoint.
final class LlmRelayRequest {
  LlmRelayRequest({
    required this.baseUrl,
    required this.model,
    required this.messages,
    this.provider,
  });

  /// Total decode: null on a shape it cannot trust; unknown fields
  /// ignored (additive versioning).
  static LlmRelayRequest? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final baseUrl = json['baseUrl'];
    final model = json['model'];
    final messages = json['messages'];
    if (baseUrl is! String || baseUrl.isEmpty) return null;
    if (model is! String || model.isEmpty) return null;
    if (messages is! List) return null;
    return LlmRelayRequest(
      baseUrl: baseUrl,
      model: model,
      messages: [
        for (final m in messages)
          if (m is Map<String, dynamic>) m,
      ],
      provider: json['provider'] is String ? json['provider'] as String : null,
    );
  }

  final String baseUrl;
  final String model;
  final List<Map<String, dynamic>> messages;

  /// The saved custom-provider name (key-slot hint), when known.
  final String? provider;

  /// The API key, injected server-side by [BridgeLlmRelay] right before
  /// [relay] runs. Never serialized onto a frame.
  String? key;
}

/// Streams one relayed completion, calling [onDelta] per text chunk. A
/// throw fails the relay with an `llmRes` error — error messages MUST NOT
/// embed the key.
typedef LlmRelayStream =
    Future<void> Function(
      LlmRelayRequest request,
      void Function(String delta) onDelta,
    );

/// Resolves the stored key for an endpoint (env-first, then the secure
/// store — mirroring the CLI's `envVarValue` order). Null = no key.
typedef LlmKeyResolver = String? Function(String baseUrl, String? providerName);

/// The `llmReq` → `llmRes` frame glue. Shared per server; stateless.
final class BridgeLlmRelay {
  BridgeLlmRelay({required this.relay, required this.resolveKey});

  final LlmRelayStream relay;
  final LlmKeyResolver resolveKey;

  /// Handles one `llmReq` frame, streaming `llmRes` frames back through
  /// [send]. Never throws: every failure path becomes an `llmRes` error
  /// frame (the extension stays alive).
  Future<void> handle(
    BridgeFrame request,
    Future<void> Function(BridgeFrame) send,
  ) async {
    final req = LlmRelayRequest.fromJson(request.fields['req']);
    if (req == null) {
      await _sendError(
        request,
        send,
        'llmReq needs req{baseUrl, model, messages}',
      );
      return;
    }
    final key = resolveKey(req.baseUrl, req.provider);
    if (key == null || key.isEmpty) {
      await _sendError(
        request,
        send,
        'no key for ${Uri.tryParse(req.baseUrl)?.host ?? req.baseUrl} '
        '- save one with /provider or /key',
      );
      return;
    }
    req.key = key;
    try {
      await relay(req, (delta) async {
        await send(
          BridgeFrame(
            id: request.id,
            op: BridgeOps.llmRes,
            fields: {'delta': delta},
          ),
        );
      });
      await send(
        BridgeFrame(
          id: request.id,
          op: BridgeOps.llmRes,
          fields: {'done': true},
        ),
      );
    } on Object catch (error) {
      await _sendError(request, send, 'relay failed: $error');
    }
  }

  Future<void> _sendError(
    BridgeFrame request,
    Future<void> Function(BridgeFrame) send,
    String message,
  ) => send(
    BridgeFrame(
      id: request.id,
      op: BridgeOps.llmRes,
      fields: {'error': message},
    ),
  );
}

/// The real relay transport: one OpenAI-completions-dialect streaming
/// call — POST `{baseUrl}/chat/completions` with the injected key, SSE
/// deltas forwarded per chunk.
///
/// ponytail: openai-completions dialect only (the default custom-provider
/// norm — openai/openrouter/zai/minimax/aiin/kimi endpoints); other
/// apiTypes answer with a clean llmRes error until a second dialect is
/// actually needed.
Future<void> relayOpenAiCompletion(
  LlmRelayRequest request,
  void Function(String delta) onDelta, {
  http.Client? client,
  Duration? idleTimeout,
}) async {
  final key = request.key;
  if (key == null || key.isEmpty) {
    throw StateError('relayOpenAiCompletion needs an injected key');
  }
  // No injected client: the shared keep-alive client (never closed per
  // call — same as every streaming adapter).
  final response = await sendProviderRequest(
    client ?? sharedProviderHttpClient(),
    _relayCall(request, key),
    null,
  );
  await _forwardDeltas(
    createSseIterator(response, null, idleTimeout: idleTimeout),
    onDelta,
  );
}

/// Builds the one streaming POST the relay sends: `{baseUrl}/chat/completions`
/// with the injected key and `stream: true`.
http.Request _relayCall(LlmRelayRequest request, String key) {
  final base = request.baseUrl.endsWith('/')
      ? request.baseUrl.substring(0, request.baseUrl.length - 1)
      : request.baseUrl;
  return http.Request('POST', Uri.parse('$base/chat/completions'))
    ..headers['authorization'] = 'Bearer $key'
    ..headers['content-type'] = 'application/json'
    ..body = jsonEncode({
      'model': request.model,
      'messages': request.messages,
      'stream': true,
    });
}

/// Drives the SSE stream to completion, forwarding each text delta.
///
/// Tolerant parse: keepalives/non-JSON chunks are skipped, a broken stream
/// ends the relay (the done frame follows normally).
Future<void> _forwardDeltas(
  StreamIterator<ServerSentEvent> iterator,
  void Function(String delta) onDelta,
) async {
  while (await iterator.moveNext()) {
    final data = iterator.current.data;
    if (data == '[DONE]') break;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      continue;
    }
    if (decoded is! Map<String, dynamic>) continue;
    final choices = decoded['choices'];
    if (choices is! List || choices.isEmpty) continue;
    final delta = (choices.first as Map<String, dynamic>)['delta'];
    if (delta is Map<String, dynamic> && delta['content'] is String) {
      onDelta(delta['content'] as String);
    }
  }
}
