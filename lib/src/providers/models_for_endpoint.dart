/// One shared "which models does this endpoint serve" dispatch for every
/// model picker (CLI settings flows, the app's chat/media/agent model
/// pages). Each wire dialect is its own class — add a new provider by
/// implementing [ModelListDialect] and registering it in
/// [modelListDialects], never by adding a branch here.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../session/uuid.dart';
import 'chatgpt_codex_models.dart';
import 'chatgpt_oauth.dart';
import 'codemie_sso.dart';
import 'codex_transport.dart';
import 'dial.dart';
import 'models_endpoint.dart';
import 'remote_catalog.dart';

/// One provider's "how to list models" implementation. Each dialect
/// encapsulates its own detection (does this endpoint belong to me?) and
/// its own fetch (what URL, what auth, what shape the response has, how
/// to normalise ids). Pickers never see the internals — they just call
/// [fetchModelsForEndpoint] which delegates.
abstract final class ModelListDialect {
  /// Whether this dialect handles [baseUrl] (optionally with the
  /// provider's hint from the caller).
  bool matches(String baseUrl, String? provider);

  /// Fetches the model list. Implementations must answer an empty
  /// [ModelsEndpointInfo] on any error — the manual-entry fallback in
  /// the pickers depends on it.
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  });
}

/// The registered dialects, in precedence order. First match wins.
/// Adding a new provider = one new class + one entry here.
final List<ModelListDialect> modelListDialects = [
  _CodeMieDialect(),
  _DialDialect(),
  _CodexDialect(),
  _GoogleDialect(),
  _OpenAiCompatibleDialect(), // default — must stay last
];

/// Fetches the model list of [baseUrl], picking the wire dialect by
/// registration order. Any failure answers an empty info — callers always
/// keep their manual-entry fallback.
Future<ModelsEndpointInfo> fetchModelsForEndpoint(
  String baseUrl, {
  required String apiKey,
  String? provider,
  http.Client? client,
}) async {
  for (final dialect in modelListDialects) {
    if (dialect.matches(baseUrl, provider)) {
      return dialect.fetch(baseUrl, apiKey, client: client);
    }
  }
  return (const <String>[], const <String, int>{}, const <String, int>{});
}

// ── CodeMie (LiteLLM-shaped /llm_models over a cookie/token) ───────────

final class _CodeMieDialect extends ModelListDialect {
  @override
  bool matches(String baseUrl, String? provider) =>
      baseUrl.contains('/code-assistant-api/');

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  }) async {
    try {
      final ids = await fetchCodeMieModels(baseUrl, apiKey, client: client);
      return (ids, const <String, int>{}, const <String, int>{});
    } on Object {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }
  }
}

// ── DIAL (deployments endpoint) ─────────────────────────────────────────

final class _DialDialect extends ModelListDialect {
  @override
  bool matches(String baseUrl, String? provider) => provider == 'dial';

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  }) async {
    try {
      final (ids, _, windows, maxTokens) = await fetchDialModelsInfo(
        baseUrl,
        apiKey,
        client: client,
      );
      return (ids, windows, maxTokens);
    } on Object {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    }
  }
}

// ── ChatGPT Codex (GET /models over the ChatGPT backend) ────────────────

final class _CodexDialect extends ModelListDialect {
  @override
  bool matches(String baseUrl, String? provider) {
    if (provider == 'chatgpt' || provider == 'chatgpt-codex') return true;
    final uri = Uri.parse(baseUrl);
    return isAllowedChatgptHost(uri.host) &&
        uri.path.startsWith('/backend-api/codex');
  }

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  }) async {
    final codexClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
      final response = await codexClient
          .get(uri, headers: _headers(apiKey))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return _bundled();
      final ids = _idsFrom(response.body);
      if (ids.isEmpty) return _bundled();
      return (
        ids,
        _knownLimits(ids, chatGptCodexContextWindows),
        _knownLimits(ids, chatGptCodexMaxTokens),
      );
    } on Object {
      return _bundled();
    } finally {
      if (ownsClient) codexClient.close();
    }
  }

  /// The bundled catalog (regenerated from codex-rs/models-manager/
  /// models.json via scripts/sync_codex_models.dart) — the never-empty
  /// fallback the pickers rely on.
  ModelsEndpointInfo _bundled() => (
    chatGptCodexModels,
    Map<String, int>.from(chatGptCodexContextWindows),
    Map<String, int>.from(chatGptCodexMaxTokens),
  );

  /// Codex backend headers: [apiKey] for chatgpt accounts is the encoded
  /// OAuth blob when it decodes, else a raw bearer token.
  Map<String, String> _headers(String apiKey) {
    var accessToken = apiKey;
    String? accountId;
    try {
      final credentials = ChatGptOAuthCredentials.decode(apiKey);
      accessToken = credentials.accessToken;
      accountId = credentials.accountId;
    } on Object {
      // Raw bearer token — sent as-is.
    }
    return {
      'accept': 'application/json',
      ...codexRequestHeaders(
        accessToken: accessToken,
        accountId: accountId,
        sessionId: uuidv7(),
        threadId: uuidv7(),
      ),
    };
  }

  /// Ids from a `{"data": [{"id": ...}]}` payload, tolerating a top-level
  /// list; non-empty string ids only, sorted.
  List<String> _idsFrom(String body) {
    final decoded = jsonDecode(body);
    final entries = decoded is Map ? decoded['data'] : decoded;
    if (entries is! List) return const [];
    final ids = <String>[
      for (final entry in entries)
        if (entry case {'id': final String id} when id.isNotEmpty) id,
    ];
    ids.sort();
    return ids;
  }

  /// The bundled limits for the live ids the catalog knows.
  Map<String, int> _knownLimits(List<String> ids, Map<String, int> bundled) => {
    for (final id in ids) id: ?bundled[id],
  };
}

// ── Google (Gemini generateContent API) ─────────────────────────────────

final class _GoogleDialect extends ModelListDialect {
  @override
  bool matches(String baseUrl, String? provider) =>
      baseUrl.contains('generativelanguage.googleapis.com');

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  }) async {
    // x-goog-api-key header (NOT Bearer); response is
    // {"models": [{"name": "models/gemini-…"}]} — strip the prefix.
    final gClient = client ?? http.Client();
    final gOwnsClient = client == null;
    try {
      final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
      final response = await gClient
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'x-goog-api-key': apiKey,
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return (const <String>[], const <String, int>{}, const <String, int>{});
      }
      final (ids, windows, maxTokens) = parseModelsResponse(response.body);
      final stripped = [for (final id in ids) id.replaceFirst('models/', '')];
      final strippedWindows = {
        for (final entry in windows.entries)
          entry.key.replaceFirst('models/', ''): entry.value,
      };
      final strippedMaxTokens = {
        for (final entry in maxTokens.entries)
          entry.key.replaceFirst('models/', ''): entry.value,
      };
      return (stripped, strippedWindows, strippedMaxTokens);
    } on Object {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    } finally {
      if (gOwnsClient) gClient.close();
    }
  }
}

// ── OpenAI-compatible (Bearer + /models) — the default fallback ────────

final class _OpenAiCompatibleDialect extends ModelListDialect {
  @override
  bool matches(String baseUrl, String? provider) => true; // fallback

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
  }) async {
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
      final response = await httpClient
          .get(
            uri,
            headers: {
              'Accept': 'application/json',
              if (apiKey.isNotEmpty) 'authorization': 'Bearer $apiKey',
            },
          )
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        return (const <String>[], const <String, int>{}, const <String, int>{});
      }
      return parseModelsResponse(response.body);
    } on Object {
      return (const <String>[], const <String, int>{}, const <String, int>{});
    } finally {
      if (ownsClient) httpClient.close();
    }
  }
}

/// Holds the preloaded [RemoteModelsCatalog] for the lifetime of the
/// process. Hosts (CLI startup, app boot) inject the catalog once; the
/// rest of the code calls [mergeFor] and [mediaFor] to fold catalog
/// hints into the endpoint-reported model list without re-fetching.
final class RemoteCatalogEnrichment {
  RemoteModelsCatalog? _cached;

  /// Returns the live parsed catalog (or null when no preload ran).
  RemoteModelsCatalog? get cached => _cached;

  /// Loads the catalog via [fetchRemoteModelsCatalog]. Failures (any
  /// network, timeout, or parse error) leave [_cached] untouched so a
  /// later preload can recover without surfacing prior failures.
  Future<void> preload({Uri? url, http.Client? client}) async {
    final loaded = await fetchRemoteModelsCatalog(url: url, client: client);
    if (loaded != null) _cached = loaded;
  }

  /// Merges the cached catalog into [info] for [providerKind]. Used by
  /// hosts that want the merged view directly (pickers, settings flows)
  /// rather than going through the dispatcher twice.
  ///
  /// [mediaSlot] opts into seeding catalog media ids into the merged
  /// list — chat slots leave it empty, media pickers pass the slot name
  /// so the empty endpoint result gets the catalog defaults.
  ModelsEndpointInfo mergeFor(
    ModelsEndpointInfo info,
    String? providerKind, {
    List<String> mediaSlot = const [],
  }) {
    return mergeWithRemoteCatalog(
      endpointInfo: info,
      providerKind: providerKind,
      catalog: _cached,
      mediaSlot: mediaSlot,
    );
  }

  /// Media-model ids the catalog lists for [providerKind]/[slot], or an
  /// empty list when the catalog has no opinion.
  List<String> mediaFor(String? providerKind, String slot) {
    return remoteMediaModelsFor(
      providerKind: providerKind,
      slot: slot,
      catalog: _cached,
    );
  }
}

/// Process-wide [RemoteCatalogEnrichment] singleton. Hosts preload once
/// at boot and the rest of the code reads from this instance. Tests swap
/// it via [setRemoteCatalogEnrichmentForTesting].
RemoteCatalogEnrichment remoteCatalogEnrichment = RemoteCatalogEnrichment();

/// Test seam — swap in a fake enrichment so unit tests don't need a
/// real HTTP client. Not part of the public API.
@visibleForTesting
void setRemoteCatalogEnrichmentForTesting(RemoteCatalogEnrichment fake) {
  remoteCatalogEnrichment = fake;
}
