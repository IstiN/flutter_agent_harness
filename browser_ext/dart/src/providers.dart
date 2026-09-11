// Provider stream construction + the synced-provider registry for the
// extension agent: an OpenAI-like streaming function over the core
// `streamOpenAICompletions` adapter (pure and web-safe), resolution for
// the deterministic `fake:` provider (fake_provider.dart — pure Dart,
// VM-testable; re-exported here so the agent host keeps a single import),
// and the `faProviders` registry that the bridge `providersSync` frame
// fills (issue #34 item 3, §S6) with `.fahx` imports and panel edits.
//
// Everything here is pure Dart: the JS glue lives in bridge_relay.dart
// (faSw.bridge) and agent_main.dart. The core sse_decoder is reused
// INSIDE the core adapter — nothing here parses SSE by hand; the only
// web-specific piece is the fetch-backed http.Client (see fetch_client.dart)
// installed once at boot.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_agent_harness/src/agent/agent_loop.dart'
    show StreamFunction;
import 'package:flutter_agent_harness/src/cancel_token.dart';
import 'package:flutter_agent_harness/src/context.dart';
import 'package:flutter_agent_harness/src/event_stream.dart';
import 'package:flutter_agent_harness/src/model.dart';
import 'package:flutter_agent_harness/src/providers/openai_completions.dart';
import 'package:flutter_agent_harness/src/providers/provider_common.dart'
    show providerHttpClientFactory;
import 'package:flutter_agent_harness/src/types.dart';

import 'fake_provider.dart' show fakeStream;
import 'fetch_client.dart';

export 'fake_provider.dart' show fakeStream;

/// Resolved provider settings (the shape the agent host streams with).
typedef ProviderConfig = ({String baseUrl, String apiKey, String model});

/// Provenance of an entry the user (or the panel import) owns locally.
/// Re-pairing NEVER overwrites local entries (UT-S2/E27).
const String localProvenance = 'local';

/// Provenance prefix the CLI stamps on synced entries:
/// `synced-from-cli@<host>`.
const String syncedProvenancePrefix = 'synced-from-cli@';

bool isSyncedProvenance(String provenance) =>
    provenance.startsWith(syncedProvenancePrefix);

/// One `faProviders` registry entry (chrome.storage.local). [apiKey] is
/// '' for keyless entries: proxy-mode syncs (the key lives on the CLI and
/// calls relay through the bridge) and intentionally keyless endpoints.
typedef ProviderEntry = ({
  String name,
  String apiType,
  String baseUrl,
  String modelId,
  String provenance,
  String apiKey,
});

/// The [ProviderConfig] the host streams with for [entry].
ProviderConfig configOfEntry(ProviderEntry entry) =>
    (baseUrl: entry.baseUrl, apiKey: entry.apiKey, model: entry.modelId);

/// Parses the stored `faProviders` doc ({version, mode, host, providers})
/// into normalized entries; null when the shape cannot be trusted.
/// Unknown fields ignored; malformed entries skipped (additive versioning).
List<ProviderEntry>? parseProvidersDoc(Object? doc) {
  if (doc is! Map) return null;
  final rawProviders = doc['providers'];
  if (rawProviders is! List) return null;
  final entries = <ProviderEntry>[];
  for (final raw in rawProviders) {
    if (raw is! Map) continue;
    final name = raw['name'];
    final baseUrl = raw['baseUrl'];
    if (name is! String || name.isEmpty) continue;
    if (baseUrl is! String || baseUrl.isEmpty) continue;
    final provenance = raw['provenance'];
    final key = raw['apiKey'];
    entries.add((
      name: name,
      baseUrl: baseUrl,
      apiType: raw['apiType'] is String ? raw['apiType'] as String : '',
      modelId: raw['modelId'] is String ? raw['modelId'] as String : '',
      provenance: provenance is String && provenance.isNotEmpty
          ? provenance
          : localProvenance,
      apiKey: key is String ? key : '',
    ));
  }
  return entries;
}

/// Merges an incoming `providersSync` payload into the stored registry
/// doc (both as raw JSON maps). Pure and total: returns a well-formed doc
/// even for a null/absent previous state.
///
/// - Synced entries replace ALL previous synced entries wholesale.
/// - Entries whose provenance is NOT synced (panel edits, .fahx imports —
///   provenance `local`) survive untouched: re-pairing never clobbers
///   local edits (UT-S2/E27).
/// - Copy-mode `keys` flatten onto their entry as `apiKey`; a proxy-mode
///   payload's `keys` field is dropped — key bytes never reach storage
///   (UT-S1).
Map<String, dynamic> mergeSyncedProviders(
  Map<Object?, Object?>? existing,
  Map<Object?, Object?> sync,
) {
  final host = '${sync['host'] ?? ''}';
  final mode = sync['mode'];
  final copyKeys = <String, String>{};
  if (mode == 'copy' && sync['keys'] is Map) {
    (sync['keys'] as Map).forEach((name, key) {
      if (name is String && key is String && key.isNotEmpty) {
        copyKeys[name] = key;
      }
    });
  }
  String provenanceOf(Map raw) {
    final p = raw['provenance'];
    return p is String && p.isNotEmpty ? p : '$syncedProvenancePrefix$host';
  }

  ProviderEntry entryOf(Map raw) => (
    name: raw['name'] as String,
    apiType: raw['apiType'] is String ? raw['apiType'] as String : '',
    baseUrl: raw['baseUrl'] as String,
    modelId: raw['modelId'] is String ? raw['modelId'] as String : '',
    provenance: provenanceOf(raw),
    apiKey: copyKeys[raw['name'] as String] ?? '',
  );

  final incoming = <ProviderEntry>[];
  final rawProviders = sync['providers'];
  if (rawProviders is List) {
    for (final raw in rawProviders) {
      if (raw is Map &&
          raw['name'] is String &&
          (raw['name'] as String).isNotEmpty &&
          raw['baseUrl'] is String &&
          (raw['baseUrl'] as String).isNotEmpty) {
        incoming.add(entryOf(raw));
      }
    }
  }

  final locals = parseProvidersDoc(
    existing,
  )?.where((entry) => !isSyncedProvenance(entry.provenance)).toList();
  return {
    'version': 1,
    'mode': mode is String ? mode : 'proxy',
    'host': host,
    'providers': [
      for (final entry in [...incoming, ...?locals]) _entryJson(entry),
    ],
  };
}

Map<String, dynamic> _entryJson(ProviderEntry entry) => {
  'name': entry.name,
  'apiType': entry.apiType,
  'baseUrl': entry.baseUrl,
  'modelId': entry.modelId,
  'provenance': entry.provenance,
  if (entry.apiKey.isNotEmpty) 'apiKey': entry.apiKey,
};

/// Merges locally-owned entries (panel import / edit) into the registry:
/// same-name entries are replaced (an explicit local import wins over a
/// synced row), new names append, provenance stamps `local`.
Map<String, dynamic> mergeLocalProviders(
  Map<Object?, Object?>? existing,
  Iterable<ProviderEntry> imported,
) {
  final stamped = [
    for (final entry in imported)
      (
        name: entry.name,
        apiType: entry.apiType,
        baseUrl: entry.baseUrl,
        modelId: entry.modelId,
        provenance: localProvenance,
        apiKey: entry.apiKey,
      ),
  ];
  final byName = {for (final entry in stamped) entry.name: entry};
  final kept = parseProvidersDoc(
    existing,
  )?.where((entry) => !byName.containsKey(entry.name)).toList();
  return {
    'version': 1,
    'mode': existing?['mode'] is String ? existing!['mode'] : 'copy',
    'host': existing?['host'] is String ? existing!['host'] : '',
    'providers': [
      for (final entry in [...?kept, ...stamped]) _entryJson(entry),
    ],
  };
}

/// Drops one entry by name (panel remove button). Pure.
Map<String, dynamic> removeProvider(
  Map<Object?, Object?>? existing,
  String name,
) {
  final kept = parseProvidersDoc(existing)?.where((entry) {
    return entry.name != name;
  }).toList();
  return {
    'version': 1,
    'mode': existing?['mode'] is String ? existing!['mode'] : 'copy',
    'host': existing?['host'] is String ? existing!['host'] : '',
    'providers': [
      for (final entry in kept ?? const <ProviderEntry>[]) _entryJson(entry),
    ],
  };
}

/// Picks the entry the agent runs on: the synced list is primary (a
/// legacy-form model id pins the match when it names one), the legacy
/// single `faProvider` map is the fallback, null when neither exists.
/// Entries without a model id are unusable and skipped.
ProviderEntry? pickActiveEntry({Object? legacy, Object? doc}) {
  final entries = parseProvidersDoc(
    doc,
  )?.where((entry) => entry.modelId.isNotEmpty).toList();
  if (entries != null && entries.isNotEmpty) {
    final legacyModel = legacy is Map ? '${legacy['model'] ?? ''}'.trim() : '';
    if (legacyModel.isNotEmpty) {
      for (final entry in entries) {
        if (entry.modelId == legacyModel) return entry;
      }
    }
    return entries.first;
  }
  if (legacy is Map) {
    final baseUrl = '${legacy['baseUrl'] ?? ''}'.trim();
    final model = '${legacy['model'] ?? ''}'.trim();
    if (model.isNotEmpty) {
      return (
        name: 'provider',
        apiType: 'openai',
        baseUrl: baseUrl,
        modelId: model,
        provenance: localProvenance,
        apiKey: '${legacy['apiKey'] ?? ''}',
      );
    }
  }
  return null;
}

/// How the ACTIVE provider reaches its endpoint (E26 semantics):
/// - fake: scripted provider, no network.
/// - relay: a SYNCED entry with no local key rides the bridge llmReq
///   relay — the key stays on the CLI. Bridge down = clean
///   `desktop link is down` error, never a hang.
/// - direct: keyed entries and keyless LOCAL endpoints (llama.cpp,
///   Ollama) fetch straight from the extension.
enum ProviderRoute { fake, relay, direct }

ProviderRoute routeFor(ProviderEntry entry) {
  if (isFakeModel(entry.modelId)) return ProviderRoute.fake;
  if (entry.apiKey.isEmpty && isSyncedProvenance(entry.provenance)) {
    return ProviderRoute.relay;
  }
  return ProviderRoute.direct;
}

/// The live relay routing for the ACTIVE provider, installed by
/// agent_main whenever a config resolves (boot / reconfigure / sync).
/// Null = stream directly (or scripted fake). Pure Dart so VM tests fake
/// the relay; the js_interop implementation is bridge_relay.dart.
abstract interface class BridgeLlmRelay {
  /// Whether the bridge WebSocket is currently connected.
  bool get connected;

  /// Streams one relayed completion; text deltas arrive as events, the
  /// terminal event is DoneEvent(stop) or ErrorEvent (never throws).
  AssistantMessageEventStream stream(
    Model model,
    Context context, {
    CancelToken? cancelToken,
    String? providerName,
  });
}

/// Set together with every active-provider resolution. ponytail: one
/// mutable binding instead of threading a relay handle through
/// HostConfig — the SW is a singleton and the host re-reads its stream
/// function on every reconfigure.
({BridgeLlmRelay relay, String providerName})? activeRelay;

/// Panel-visible diagnostics sink, set by the agent host to its event
/// sink so provider diagnostics ride the relay into the PANEL console —
/// the SW's own console is a separate DevTools window nobody opens, and
/// an empty turn otherwise has zero observable cause. Events use the
/// `debug` type (the panel prints them and never renders them).
void Function(Map<String, dynamic> event)? hostEventSink;

/// Emits one diagnostic line to the SW console AND the panel relay.
void providerDebug(String line) {
  print(line);
  hostEventSink?.call({'type': 'debug', 'text': line});
}

/// Model ids starting with `fake:` select the deterministic CI provider.
bool isFakeModel(String model) => model.startsWith('fake:');

/// Whether [url] points at a CodeMie deployment (the cookie-auth host:
/// the user's browser jar already carries the session — an API key or a
/// localhost SSO dance is never needed). Pure so the panel and the SW
/// agree on the classification.
bool isCookieAuthUrl(String url) =>
    Uri.tryParse(url)?.host.contains('codemie') ?? false;

/// Builds the [Model] spec sent with every request (and persisted in
/// `model_change` session records).
Model modelForConfig(ProviderConfig config) => Model(
  id: config.model,
  name: config.model,
  api: 'openai-completions',
  provider: isFakeModel(config.model) ? 'fake' : 'openai-like',
  baseUrl: config.baseUrl,
  contextWindow: 128000,
  maxTokens: 8192,
);

/// Streams via the core openai-completions adapter using the platform
/// `fetch` (MV3 service workers have no XHR for package:http's default
/// client). The api key rides [OpenAICompletionsOptions] and never leaves
/// the service worker (AC8).
StreamFunction openAiLikeStream(ProviderConfig config) {
  providerHttpClientFactory = () => FetchClient();
  return (model, context, {cancelToken}) {
    final inner = streamOpenAICompletions(
      model,
      context,
      OpenAICompletionsOptions(
        apiKey: config.apiKey.isEmpty ? null : config.apiKey,
        cancelToken: cancelToken,
        // Response diagnostics: an expired CodeMie session arrives as a
        // silently-followed redirect (200 + text/html login page) — this
        // log line proves which answer the endpoint gave when a turn comes
        // back empty, instead of guessing from the transcript.
        onResponse: (statusCode, headers, _) {
          providerDebug(
            '[provider] response $statusCode '
            'content-type=${headers['content-type'] ?? '—'} '
            'url=${config.baseUrl}',
          );
        },
      ),
    );
    // Terminal-event diagnostics: an empty turn must name its cause in
    // the SW console — done-with-no-content (empty SSE stream) and
    // error look identical downstream ("empty response" bubble).
    final outer = createAssistantMessageEventStream();
    inner.listen((event) {
      switch (event) {
        case DoneEvent(:final reason, :final message):
          final textLen = message.content.whereType<TextContent>().fold<int>(
            0,
            (sum, block) => sum + block.text.length,
          );
          final toolCalls = message.content.whereType<ToolCall>().length;
          providerDebug(
            '[provider] done reason=$reason '
            'textLen=$textLen toolCalls=$toolCalls '
            'stopReason=${message.stopReason}',
          );
        case ErrorEvent(:final reason, :final error):
          providerDebug(
            '[provider] error reason=$reason '
            'message=${error.errorMessage}',
          );
        default:
      }
      outer.push(event);
    }, onDone: outer.end);
    return outer;
  };
}

/// Resolves the stream function for the ACTIVE [config]: `fake:*` →
/// scripted provider; a relay-routed entry (installed as [activeRelay]
/// when the config resolved) → the bridge llmReq relay; anything else →
/// the openai-like adapter over `fetch`.
StreamFunction resolveStreamFn(ProviderConfig config) {
  providerHttpClientFactory = () => FetchClient();
  if (isFakeModel(config.model)) return fakeStream;
  final relay = activeRelay;
  if (relay != null &&
      config.apiKey.isEmpty &&
      // A cookie-auth host streams DIRECT: the SW fetch carries the
      // browser jar (FetchClient credentials:include) — routing it
      // through the bridge relay would strip the cookies and 401.
      !isCookieAuthUrl(config.baseUrl)) {
    return (model, context, {cancelToken}) => relay.relay.stream(
      model,
      context,
      cancelToken: cancelToken,
      providerName: relay.providerName,
    );
  }
  return openAiLikeStream(config);
}

/// Builds the OpenAI chat-completions `messages` array the relay request
/// carries. The server posts it verbatim (`relayOpenAiCompletion`), so
/// the dialect conversion happens here: neutral content blocks flatten to
/// text, tool calls/results map to `tool_calls`/`role:"tool"` rows.
/// ponytail: images and thinking blocks are dropped — the relay targets
/// the openai-completions norm, and the direct adapter keeps full fidelity.
List<Map<String, dynamic>> openAiRelayMessages(Context context) {
  String textOf(Object content) => switch (content) {
    String text => text,
    List<ContentBlock> blocks => [
      for (final block in blocks)
        if (block is TextContent) block.text,
    ].join('\n'),
    _ => '',
  };
  final messages = <Map<String, dynamic>>[];
  final systemPrompt = context.systemPrompt;
  if (systemPrompt != null && systemPrompt.isNotEmpty) {
    messages.add({'role': 'system', 'content': systemPrompt});
  }
  for (final message in context.messages) {
    switch (message) {
      case UserMessage():
        messages.add({'role': 'user', 'content': textOf(message.content)});
      case AssistantMessage():
        final text = [
          for (final block in message.content)
            if (block is TextContent) block.text,
        ].join('\n');
        final calls = [
          for (final block in message.content)
            if (block is ToolCall)
              {
                'id': block.id,
                'type': 'function',
                'function': {
                  'name': block.name,
                  'arguments': jsonEncode(block.arguments),
                },
              },
        ];
        messages.add({
          'role': 'assistant',
          if (text.isNotEmpty || calls.isEmpty) 'content': text,
          if (calls.isNotEmpty) 'tool_calls': calls,
        });
      case ToolResultMessage():
        messages.add({
          'role': 'tool',
          'tool_call_id': message.toolCallId,
          'content': textOf(message.content),
        });
    }
  }
  return messages;
}

/// Drives the relay's delta stream into the provider event contract
/// (errors-as-events — never throws). The terminal event is DoneEvent on
/// a clean stream end, ErrorEvent on a stream error (bridge down, relay
/// failure), or ErrorEvent(aborted) when [cancelToken] fires.
AssistantMessageEventStream relayTextStream(
  Model model,
  Stream<String> deltas, {
  CancelToken? cancelToken,
}) {
  final events = AssistantMessageEventStream();
  var text = '';
  var closed = false;
  AssistantMessage partial() => AssistantMessage(
    content: [TextContent(text: text)],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: StopReason.stop,
    timestamp: DateTime.now(),
  );
  AssistantMessage errorOf(String message) => AssistantMessage(
    content: const [],
    api: model.api,
    provider: model.provider,
    model: model.id,
    usage: Usage.zero,
    stopReason: StopReason.error,
    errorMessage: message,
    timestamp: DateTime.now(),
  );
  StreamSubscription<String>? subscription;
  void finish(AssistantMessageEvent terminal) {
    if (closed) return;
    closed = true;
    unawaited(subscription?.cancel());
    events.push(terminal);
    events.end();
  }

  if (cancelToken != null) {
    unawaited(
      cancelToken.onCancel.then((_) {
        finish(
          ErrorEvent(
            reason: StopReason.aborted,
            error: errorOf('relay stream cancelled'),
          ),
        );
      }),
    );
  }
  subscription = deltas.listen(
    (delta) {
      if (closed) return;
      text += delta;
      events.push(
        TextDeltaEvent(contentIndex: 0, delta: delta, partial: partial()),
      );
    },
    onDone: () =>
        finish(DoneEvent(reason: StopReason.stop, message: partial())),
    onError: (Object error) =>
        finish(ErrorEvent(reason: StopReason.error, error: errorOf('$error'))),
  );
  return events;
}
