/// Keyless-proxy LLM relay (issue #34 item 3, §S6): the extension sends an
/// `llmReq` frame; the bridge resolves the provider key SERVER-SIDE (the
/// key never appeared in any frame), streams the completion through the
/// provider, and answers with correlated `llmRes` frames — `{delta}` per
/// chunk, then `{done: true}`, or `{error}`.
///
/// **Trust boundary (SEC-01, security review 2026-09-22): the client
/// chooses WHAT (provider id); the server alone decides WHERE (endpoint)
/// and WITH WHAT (key).** A named provider resolves BOTH the endpoint and
/// the key from the same saved record — the client's `baseUrl` must
/// byte-equal the record's and is checked BEFORE any network call; an
/// unknown name is a named rejection; the anonymous (unnamed) mode is
/// relayed with NO stored key attached. A compromised extension can name
/// providers, never pocket them.
///
/// Pure Dart: the frame glue ([BridgeLlmRelay]) never touches dart:io or
/// a key store — target/key resolution and the actual provider call are
/// injected. [relayOpenAiCompletion] is the real transport, built on the
/// provider path's own primitives (`sendProviderRequest` +
/// `createSseIterator`).
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cli/custom_providers.dart';
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
  /// ignored (additive versioning). An empty `provider` string decodes as
  /// absent (the extension glue only sends it when non-empty).
  static LlmRelayRequest? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final baseUrl = json['baseUrl'];
    final model = json['model'];
    final messages = json['messages'];
    if (baseUrl is! String || baseUrl.isEmpty) return null;
    if (model is! String || model.isEmpty) return null;
    if (messages is! List) return null;
    final provider = json['provider'];
    return LlmRelayRequest(
      baseUrl: baseUrl,
      model: model,
      messages: [
        for (final m in messages)
          if (m is Map<String, dynamic>) m,
      ],
      provider: provider is String && provider.isNotEmpty ? provider : null,
    );
  }

  final String baseUrl;
  final String model;
  final List<Map<String, dynamic>> messages;

  /// The saved custom-provider name (key-slot hint), when known.
  final String? provider;

  /// The API key, injected server-side by [BridgeLlmRelay] right before
  /// [relay] runs. Never serialized onto a frame. Null = anonymous mode:
  /// the transport sends no Authorization header at all.
  String? key;
}

/// The server-resolved target for one `llmReq` (SEC-01): WHERE the request
/// goes and WITH WHAT key — both decided from the server's own records,
/// never from client fields.
final class LlmRelayTarget {
  const LlmRelayTarget({required this.baseUrl, this.key}) : error = null;

  /// A named rejection: the request never leaves the machine.
  const LlmRelayTarget.reject(this.error) : baseUrl = '', key = null;

  /// The endpoint the stored key may travel to — the record's own
  /// baseUrl, verbatim.
  final String baseUrl;

  /// The record's key. Null = keyless record (the frame glue turns this
  /// into a named no-key rejection).
  final String? key;

  /// Non-null on a named rejection; the message names the provider.
  final String? error;

  bool get rejected => error != null;
}

/// Streams one relayed completion, calling [onDelta] per text chunk. A
/// throw fails the relay with an `llmRes` error — error messages MUST NOT
/// embed the key.
typedef LlmRelayStream =
    Future<void> Function(
      LlmRelayRequest request,
      void Function(String delta) onDelta,
    );

/// Resolves the server-side target for one relay request (SEC-01).
///
/// Returns null → anonymous mode: the request's own `baseUrl` is honored
/// and NO stored key is ever attached. A non-null [LlmRelayTarget] is
/// either the record-backed endpoint+key pair or a named rejection.
typedef LlmRelayResolver = LlmRelayTarget? Function(LlmRelayRequest request);

/// The SEC-01 resolution over the saved-provider table (pure; hosts inject
/// the key lookup): a named provider resolves endpoint AND key from the
/// SAME record — a client `baseUrl` that is not byte-equal to the record's
/// is a rejection checked BEFORE any network call; an unknown name is a
/// named rejection; a non-openai record is rejected by dialect (the relay
/// transport speaks openai-completions only); no name at all → null
/// (anonymous, keyless) — unless the unnamed baseUrl byte-matches a KEYED
/// saved record, which answers a migration hint instead (legacy clients
/// named no provider; the old URL-keyed branch served them, and a raw
/// endpoint 401 is not actionable).
LlmRelayTarget? resolveLlmRelayTarget(
  LlmRelayRequest request, {
  required Iterable<CustomProviderEntry> providers,
  String? Function(CustomProviderEntry entry)? resolveKey,
}) {
  final name = request.provider;
  if (name == null) {
    // Narrow path: the key lookup only runs when the baseUrl byte-matches
    // a saved record (never per unnamed frame).
    final keyedRecord = providers.any(
      (e) => e.baseUrl == request.baseUrl && (resolveKey?.call(e) != null),
    );
    if (keyedRecord) {
      return LlmRelayTarget.reject(
        'keyless relay to a saved provider - update the extension / '
        're-pair (/browser connect) so llmReq names its provider',
      );
    }
    return null;
  }
  final entry = providers.where((e) => e.name == name).firstOrNull;
  if (entry == null) {
    return LlmRelayTarget.reject(
      'unknown provider "$name" - re-pair (/browser connect) to refresh '
      'the provider list',
    );
  }
  if (entry.apiType != 'openai') {
    return LlmRelayTarget.reject(
      'provider "$name" uses the "${entry.apiType}" dialect - the relay '
      'speaks openai-completions only',
    );
  }
  // Byte-equality BEFORE any network call: a client-chosen baseUrl can
  // never steer a stored key to another address.
  if (request.baseUrl != entry.baseUrl) {
    return LlmRelayTarget.reject(
      'provider "$name" is served at ${entry.baseUrl} - the relay sends '
      'stored keys only to the saved record\'s own endpoint '
      '(got ${Uri.tryParse(request.baseUrl)?.host ?? request.baseUrl})',
    );
  }
  return LlmRelayTarget(baseUrl: entry.baseUrl, key: resolveKey?.call(entry));
}

/// The `llmReq` → `llmRes` frame glue. Shared per server; stateless.
final class BridgeLlmRelay {
  BridgeLlmRelay({required this.relay, required this.resolveTarget});

  final LlmRelayStream relay;

  /// The SEC-01 target resolver (see [resolveLlmRelayTarget]).
  final LlmRelayResolver resolveTarget;

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
    final target = resolveTarget(req);
    LlmRelayRequest effective;
    if (target == null) {
      // Anonymous mode: the client's own baseUrl, keyless by construction.
      effective = req;
    } else {
      if (target.rejected) {
        await _sendError(request, send, target.error!);
        return;
      }
      if (target.key == null || target.key!.isEmpty) {
        await _sendError(
          request,
          send,
          'no key for provider "${req.provider}" - save one with /provider '
          'or /key',
        );
        return;
      }
      // Server decides WHERE and WITH WHAT: endpoint and key both come
      // from the record.
      effective = LlmRelayRequest(
        baseUrl: target.baseUrl,
        model: req.model,
        messages: req.messages,
      )..key = target.key;
    }
    try {
      await relay(effective, (delta) async {
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
/// call — POST `{baseUrl}/chat/completions` with the injected key (none
/// for the anonymous mode), SSE deltas forwarded per chunk.
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
  // The key is injected server-side; a null key is the ANONYMOUS relay
  // mode — the call goes out with no Authorization header and can never
  // carry a stored key (SEC-01).
  final response = await sendProviderRequest(
    client ?? sharedProviderHttpClient(),
    _relayCall(request, request.key),
    null,
  );
  await _forwardDeltas(
    createSseIterator(response, null, idleTimeout: idleTimeout),
    onDelta,
  );
}

/// Builds the one streaming POST the relay sends: `{baseUrl}/chat/completions`
/// with the injected key (omitted entirely for the anonymous mode) and
/// `stream: true`.
http.Request _relayCall(LlmRelayRequest request, String? key) {
  final base = request.baseUrl.endsWith('/')
      ? request.baseUrl.substring(0, request.baseUrl.length - 1)
      : request.baseUrl;
  final call = http.Request('POST', Uri.parse('$base/chat/completions'))
    ..headers['content-type'] = 'application/json'
    ..body = jsonEncode({
      'model': request.model,
      'messages': request.messages,
      'stream': true,
    });
  if (key != null && key.isNotEmpty) {
    call.headers['authorization'] = 'Bearer $key';
  }
  return call;
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
