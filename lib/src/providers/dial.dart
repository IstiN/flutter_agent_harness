/// EPAM AI DIAL provider adapter — an OpenAI-compatible dialect where the
/// deployment (model id) is part of the URL path and authentication rides an
/// `Api-Key` header instead of `Authorization: Bearer`:
///
/// ```
/// POST {baseUrl}/openai/deployments/{model}/chat/completions[?api-version=…]
/// Api-Key: <key>
/// ```
///
/// The request/response payloads are the OpenAI chat-completions shape, so
/// the stream itself is [streamOpenAICompletions] with a custom
/// [OpenAICompletionsOptions.urlBuilder] and header set.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../cancel_token.dart';
import '../context.dart';
import '../event_stream.dart';
import '../model.dart';
import '../types.dart';
import 'models_endpoint.dart';
import 'openai_completions.dart';

/// The ids from a DIAL `/openai/models` response whose `features.cache`
/// flag is on (manual `cache_breakpoint` markers are honored for them),
/// plus the per-deployment reported limits (context window / max output —
/// from `limits.max_total_tokens`/`max_prompt_tokens` and
/// `limits.max_completion_tokens`).
typedef DialModelsInfo = (
  List<String> ids,
  Set<String> cacheSupported,
  Map<String, int> contextWindows,
  Map<String, int> maxTokens,
);

/// Options for [streamDial].
final class DialOptions {
  /// Creates DIAL options.
  const DialOptions({
    required this.apiKey,
    this.apiVersion,
    this.cancelToken,
    this.sessionId,
    this.cacheRetention,
    this.cacheMarkersSupported,
  });

  /// DIAL API key, sent as the `Api-Key` header. Empty sends no auth header
  /// (a keyless local DIAL Core then simply serves the request).
  final String apiKey;

  /// Optional DIAL API version, appended as the `api-version` query
  /// parameter (Azure-style versioning). Current DIAL Core accepts requests
  /// without it, so the default is to omit the parameter.
  final String? apiVersion;

  /// Cancels the in-flight request when triggered.
  final CancelToken? cancelToken;

  /// Session id used as the prompt-cache affinity key (see
  /// [OpenAICompletionsOptions.sessionId]).
  final String? sessionId;

  /// Prompt-cache retention (see [OpenAICompletionsOptions.cacheRetention]).
  final String? cacheRetention;

  /// Whether the deployment honors manual `cache_breakpoint` markers (the
  /// DIAL `/openai/models` `features.cache` flag; see [fetchDialModelsInfo]).
  /// Null = unknown — the adapter optimistically sends markers and falls
  /// back marker-less on a 4xx/5xx answer. False = the endpoint reported
  /// the deployment as cache-unsupported; markers are never sent.
  final bool? cacheMarkersSupported;
}

/// Builds the DIAL chat-completions URL:
/// `{baseUrl}/openai/deployments/{deployment}/chat/completions`, with the
/// `api-version` query parameter appended when [apiVersion] is non-empty.
Uri dialCompletionsUri(
  String baseUrl,
  String deployment, {
  String? apiVersion,
}) {
  final normalized = baseUrl.replaceAll(RegExp(r'/+$'), '');
  final uri = Uri.parse(
    '$normalized/openai/deployments/$deployment/chat/completions',
  );
  final version = apiVersion?.trim();
  if (version == null || version.isEmpty) return uri;
  return uri.replace(queryParameters: {'api-version': version});
}

/// Streams an assistant message from a DIAL Core deployment.
///
/// Same errors-as-events invariant as [streamOpenAICompletions]: this
/// function never throws; failures terminate the stream with an error event.
///
/// Prompt caching: DIAL Core only caches prefixes that end at an explicit
/// `custom_fields.cache_breakpoint` marker (manual caching — verified
/// against live deployments: identical prompts without a marker never hit).
/// The [onPayload] hook adds a breakpoint to the system message and the
/// last tool definition. Not every deployment enables caching, though —
/// some answer `502` to marker-carrying requests (no `cacheSupported`
/// flag upstream); the first such failure flips a process-wide switch and
/// every later request goes marker-less (they still work, just uncached).
AssistantMessageEventStream streamDial(
  Model model,
  Context context, [
  DialOptions? options,
  http.Client? client,
]) {
  final markersOff =
      _dialCacheMarkersDisabled ||
      options?.cacheRetention == 'none' ||
      options?.cacheMarkersSupported == false;
  if (markersOff) {
    return _streamDialOnce(
      model,
      context,
      options,
      client,
      cacheMarkers: false,
    );
  }
  // Optimistic pass with markers; a cache-unsupported deployment answers
  // 4xx/5xx. The injected client wrapper records the failing status, the
  // error-event handler flips the kill switch and replays marker-less.
  final probe = _DialCacheProbeClient(client);
  final outer = AssistantMessageEventStream();
  final inner = _streamDialOnce(
    model,
    context,
    options,
    probe,
    cacheMarkers: true,
  );
  var retried = false;
  late StreamSubscription<AssistantMessageEvent> sub;
  sub = inner.listen(
    (event) {
      if (!retried &&
          event is ErrorEvent &&
          event.reason == StopReason.error &&
          probe.lastStatus != null &&
          probe.lastStatus! >= 400) {
        retried = true;
        _dialCacheMarkersDisabled = true;
        sub.cancel();
        _streamDialOnce(
          model,
          context,
          options,
          client,
          cacheMarkers: false,
        ).listen(outer.push, onDone: outer.end, onError: (_) {});
        return;
      }
      outer.push(event);
    },
    onDone: outer.end,
    onError: (_) {},
  );
  return outer;
}

/// Pass-through HTTP client that records the last response status seen, so
/// the dial retry logic can distinguish "markers rejected" (4xx/5xx) from
/// streaming/SSE failures. Forwards everything to the wrapped client; owns
/// nothing (close is a no-op — the wrapped client's owner keeps control).
final class _DialCacheProbeClient implements http.Client {
  _DialCacheProbeClient(this._inner);

  final http.Client? _inner;
  int? lastStatus;

  http.Client get _client => _inner ?? http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final response = await _client.send(request);
    lastStatus = response.statusCode;
    return response;
  }

  @override
  void close() {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Function.apply(_client.send, [invocation]);
}

/// Process-wide kill switch set when a deployment rejects cache markers.
var _dialCacheMarkersDisabled = false;

/// One dial attempt: [streamOpenAICompletions] with the DIAL URL/auth and
/// (optionally) the cache-breakpoint payload hook.
AssistantMessageEventStream _streamDialOnce(
  Model model,
  Context context,
  DialOptions? options,
  http.Client? client, {
  required bool cacheMarkers,
}) {
  final apiKey = options?.apiKey ?? '';
  return streamOpenAICompletions(
    model,
    context,
    OpenAICompletionsOptions(
      // DIAL authenticates via the Api-Key header; a null key keeps the
      // OpenAI adapter from adding `Authorization: Bearer`.
      apiKey: null,
      headers: {if (apiKey.isNotEmpty) 'Api-Key': apiKey},
      cancelToken: options?.cancelToken,
      sessionId: options?.sessionId,
      cacheRetention: options?.cacheRetention,
      urlBuilder: (m) =>
          dialCompletionsUri(m.baseUrl, m.id, apiVersion: options?.apiVersion),
      onPayload: cacheMarkers ? _addDialCacheBreakpoints : null,
    ),
    client,
  );
}

/// Adds `custom_fields.cache_breakpoint` markers for DIAL manual prompt
/// caching: one on the system message (the stable, re-sent prefix) and one
/// on the last tool definition. Returns a new payload map; never mutates
/// the input.
Future<Map<String, dynamic>?> _addDialCacheBreakpoints(
  Map<String, dynamic> payload,
  Model model,
) async {
  final next = Map<String, dynamic>.of(payload);
  final messages = payload['messages'];
  if (messages is List && !_hasSystemBreakpoint(messages)) {
    next['messages'] = _markedSystemMessage(messages);
  }
  // The tools prefix is stable across turns: a breakpoint on the LAST tool
  // definition makes the whole tool block cacheable.
  final tools = next['tools'];
  if (tools is List && tools.isNotEmpty) {
    next['tools'] = _markedLastTool(tools);
  }
  return next;
}

/// Whether any system message already carries a breakpoint.
bool _hasSystemBreakpoint(List<Object?> messages) {
  return messages.any(
    (m) =>
        m is Map &&
        m['role'] == 'system' &&
        (m['custom_fields'] as Map?)?['cache_breakpoint'] != null,
  );
}

/// The message list with a breakpoint on the first system message.
List<Object> _markedSystemMessage(List<Object?> messages) {
  final marked = <Object>[];
  var systemMarked = false;
  for (final m in messages) {
    if (!systemMarked && m is Map && m['role'] == 'system') {
      marked.add(_withBreakpoint(m));
      systemMarked = true;
    } else {
      marked.add(m as Object);
    }
  }
  return marked;
}

/// The tool list with a breakpoint on its last definition (no-op copy of
/// the same list when there is nothing to mark).
List<Object> _markedLastTool(List<Object?> tools) {
  final last = tools.last;
  final alreadyMarked =
      last is Map &&
      (last['custom_fields'] as Map?)?['cache_breakpoint'] != null;
  if (alreadyMarked || last is! Map) {
    return [for (final t in tools) t as Object];
  }
  final markedTools = <Object>[for (final t in tools) t as Object];
  markedTools[markedTools.length - 1] = _withBreakpoint(last);
  return markedTools;
}

/// A shallow copy of [entry] carrying `custom_fields.cache_breakpoint`
/// (existing custom_fields are preserved).
Map<String, dynamic> _withBreakpoint(Map<dynamic, dynamic> entry) {
  final copy = Map<String, dynamic>.from(entry);
  copy['custom_fields'] = <String, dynamic>{
    ...((entry['custom_fields'] as Map?)?.cast<String, dynamic>() ??
        const <String, dynamic>{}),
    'cache_breakpoint': const <String, dynamic>{},
  };
  return copy;
}

/// Fetches the deployment ids from `{baseUrl}/openai/models` (OpenAI-shaped
/// `{"data": [{"id": …}]}` response), authenticating with the `Api-Key`
/// header. Any failure answers an empty list — callers keep their hardcoded
/// fallback model list.
Future<List<String>> fetchDialModels(
  String baseUrl,
  String apiKey, {
  http.Client? client,
}) async {
  final (ids, _, _, _) = await fetchDialModelsInfo(
    baseUrl,
    apiKey,
    client: client,
  );
  return ids;
}

/// [fetchDialModels] plus the DIAL-specific deployment features: the second
/// component carries the ids whose `features.cache` flag is on (manual
/// `cache_breakpoint` markers are honored). `features.auto_caching` models
/// cache on their own and need no markers; they are NOT in the set.
Future<DialModelsInfo> fetchDialModelsInfo(
  String baseUrl,
  String apiKey, {
  http.Client? client,
}) async {
  final httpClient = client ?? http.Client();
  final ownsClient = client == null;
  try {
    final normalized = baseUrl.replaceAll(RegExp(r'/+$'), '');
    final response = await httpClient
        .get(
          Uri.parse('$normalized/openai/models'),
          headers: {
            'Accept': 'application/json',
            if (apiKey.isNotEmpty) 'Api-Key': apiKey,
          },
        )
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      return (
        const <String>[],
        const <String>{},
        const <String, int>{},
        const <String, int>{},
      );
    }
    final (ids, windows, maxTokens) = parseModelsResponse(response.body);
    final cacheSupported = _dialCacheSupportedIds(response.body);
    return (ids, cacheSupported, windows, maxTokens);
  } on Object {
    return (
      const <String>[],
      const <String>{},
      const <String, int>{},
      const <String, int>{},
    );
  } finally {
    if (ownsClient) httpClient.close();
  }
}

/// The ids with `features.cache == true` in a DIAL `/openai/models` body.
Set<String> _dialCacheSupportedIds(String body) {
  try {
    final decoded = jsonDecode(body);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is! List) return const {};
    return {
      for (final entry in data)
        if (entry is Map)
          if ((entry['id'] ?? entry['alias'] ?? entry['name']) is String &&
              ((entry['features'] as Map?)?['cache']) == true)
            (entry['id'] ?? entry['alias'] ?? entry['name']) as String,
    };
  } on Object {
    return const {};
  }
}
