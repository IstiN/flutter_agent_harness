/// One shared "which models does this endpoint serve" dispatch for every
/// model picker (CLI settings flows, the app's chat/media/agent model
/// pages). Each wire dialect is its own class — add a new provider by
/// implementing [ModelListDialect] and registering it in
/// [modelListDialects], never by adding a branch here.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../session/uuid.dart';
import 'chatgpt_codex_models.dart';
import 'chatgpt_oauth.dart';
import 'codemie_sso.dart';
import 'codex_transport.dart';
import 'copilot_oauth.dart';
import 'dial.dart';
import 'models_endpoint.dart';
import 'provider_common.dart' show effectiveProviderConnectTimeout, providerTimeoutsOverride;
import 'remote_catalog.dart';

/// The [fetchModelsForEndpoint] `provider` hints the dialects match on.
/// Connect flows persist these on registry entries (`CustomProvider.kind`)
/// so identity survives URL edits; [modelsDispatchHintFor]-style URL
/// mappers return the same values.
const String chatgptCodexDispatchHint = 'chatgpt-codex';
const String copilotDispatchHint = 'copilot';
const String dialDispatchHint = 'dial';

/// One provider's "how to list models" implementation. Each dialect
/// encapsulates its own detection (does this endpoint belong to me?) and
/// its own fetch (what URL, what auth, what shape the response has, how
/// to normalise ids). Pickers never see the internals — they just call
/// [fetchModelsForEndpoint] which delegates.
///
/// The [ModelListDialect.fetch] `onBundledFallback` parameter is optional
/// for dialects without a bundled offline catalog: keep it in the
/// override's signature and simply ignore it — only dialects that answer
/// from a bundled catalog when the live fetch fails ever invoke it.
/// (Adding the parameter is a breaking change for out-of-tree
/// implementers; called out in CHANGELOG.md.)
abstract final class ModelListDialect {
  /// Whether this dialect handles [baseUrl] (optionally with the
  /// provider's hint from the caller).
  bool matches(String baseUrl, String? provider);

  /// Fetches the model list. Implementations must answer an empty
  /// [ModelsEndpointInfo] on any error — the manual-entry fallback in
  /// the pickers depends on it. A dialect that answers from a bundled
  /// catalog because the live fetch failed (the Codex catalog today)
  /// invokes [onBundledFallback] so pickers can surface the provenance.
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
    void Function()? onBundledFallback,
  });

  /// Fetches the model list WITH the empty-answer diagnostic (gh-1990):
  /// the same answer as [fetch], carrying WHY it is empty when it is.
  /// The default wraps [fetch] with no diagnostic; dialects with named
  /// failure branches override it. [fetchModelsForEndpointReport]
  /// dispatches here.
  Future<ModelsFetchReport> fetchReport(
    String baseUrl,
    String apiKey, {
    http.Client? client,
    void Function()? onBundledFallback,
  }) async => ModelsFetchReport(
    info: await fetch(
      baseUrl,
      apiKey,
      client: client,
      onBundledFallback: onBundledFallback,
    ),
  );
}

/// The registered dialects, in precedence order. First match wins.
/// Adding a new provider = one new class + one entry here.
final List<ModelListDialect> modelListDialects = [
  _CodeMieDialect(),
  _DialDialect(),
  _CodexDialect(),
  _CopilotDialect(),
  _GoogleDialect(),
  _OpenAiCompatibleDialect(), // default — must stay last
];

/// Fetches the model list of [baseUrl], picking the wire dialect by
/// registration order. Any failure answers an empty info — callers always
/// keep their manual-entry fallback. When a dialect answers from its
/// bundled catalog instead of the live endpoint ([onBundledFallback]), the
/// picker can surface the provenance (the bundled-catalog note).
Future<ModelsEndpointInfo> fetchModelsForEndpoint(
  String baseUrl, {
  required String apiKey,
  String? provider,
  http.Client? client,
  void Function()? onBundledFallback,
}) async {
  final report = await fetchModelsForEndpointReport(
    baseUrl,
    apiKey: apiKey,
    provider: provider,
    client: client,
    onBundledFallback: onBundledFallback,
  );
  return report.info;
}

/// Why a `/models` fetch answered empty — the named failure branch
/// (gh-1990): no picker may show a bare empty list again, every
/// silent-empty exit (token exchange / HTTP / tier routing / filter)
/// carries its reason.
@immutable
final class ModelsFetchDiagnostic {
  /// Creates the diagnostic; [stage] and [message] are the contract, the
  /// rest is best-effort structure for programmatic surfacing.
  const ModelsFetchDiagnostic({
    required this.stage,
    required this.message,
    this.path,
    this.httpStatus,
    this.timedOut = false,
    this.pathFailed = true,
    this.fetchedCount = 0,
    this.filteredCount = 0,
    this.hint,
  });

  /// The stage that produced this: the token exchange, the `/models`
  /// HTTP call, or the picker filter.
  final String stage;

  /// The exchange stage — `copilot_internal/v2/token` failed.
  static const stageExchange = 'exchange';

  /// The models stage — the `/models` HTTP call failed or answered empty.
  static const stageModels = 'models';

  /// The filter stage — `/models` answered, the picker filter dropped
  /// every entry.
  static const stageFilter = 'filter';

  /// Which credential path produced this: the exchanged-token path or
  /// the raw-PAT path (the dual-path provenance, gh-1606).
  final String? path;

  /// The exchanged-token path (the default credential route).
  static const pathExchange = 'exchange';

  /// The raw-PAT path (fine-grained PATs, the gh-1606 PAT mode).
  static const pathPatDirect = 'pat-direct';

  /// The one-line user-facing reason.
  final String message;

  /// The HTTP status when a request failed with one.
  final int? httpStatus;

  /// Whether the failure was the watchdog firing instead of an answer.
  final bool timedOut;

  /// Whether THIS path failed (exchange throw, non-200, timeout,
  /// transport) — as opposed to answering and the filter dropping the
  /// entries. The dual-path fallback retries only failed paths.
  final bool pathFailed;

  /// Entries the payload carried (the filter stage).
  final int fetchedCount;

  /// Entries the picker filter dropped (the filter stage).
  final int filteredCount;

  /// Optional remediation hint (tier host, PAT remedies, seat check).
  final String? hint;

  @override
  String toString() => message;
}

/// A `/models` fetch answer plus its provenance (gh-1990): the parsed
/// [ModelsEndpointInfo], the empty-answer [diagnostic] (null exactly when
/// models were listed), an optional human-facing [note] (path fallback,
/// partial filtering), and the per-model filter drops.
@immutable
final class ModelsFetchReport {
  /// Creates the report; [diagnostic] must be non-null exactly when
  /// [info].$1 is empty — an empty answer always names its reason.
  const ModelsFetchReport({
    required this.info,
    this.diagnostic,
    this.note,
    this.droppedModels = const <(String, String)>[],
  });

  /// The parsed model list (ids, context windows, output caps).
  final ModelsEndpointInfo info;

  /// Why the answer is empty — null exactly when models were listed.
  final ModelsFetchDiagnostic? diagnostic;

  /// Optional provenance note even on success: the dual-path fallback
  /// note (which credential path answered), a partial-filter summary.
  final String? note;

  /// Per-model filter drops as (model id, drop reason) — populated even
  /// when some models were listed (AC2 transparency).
  final List<(String, String)> droppedModels;

  /// Whether the fetch answered no models.
  bool get isEmpty => info.$1.isEmpty;

  /// The one-line user-facing reason for an empty answer, with the
  /// remediation hint appended when present.
  String get reasonText {
    final d = diagnostic;
    if (d == null) return '';
    return d.hint == null ? d.message : '${d.message} — ${d.hint}';
  }
}

/// Fetches the model list of [baseUrl] WITH the empty-answer diagnostic
/// (gh-1990): the same dispatch as [fetchModelsForEndpoint], but the
/// answer carries WHY it is empty — the failed stage (token exchange /
/// HTTP / filter), the HTTP status, the timeout flag, the per-model
/// filter drops, and any remediation hint.
Future<ModelsFetchReport> fetchModelsForEndpointReport(
  String baseUrl, {
  required String apiKey,
  String? provider,
  http.Client? client,
  void Function()? onBundledFallback,
}) async {
  final effectiveClient = client ?? _dispatchHttpClientForTesting;
  for (final dialect in modelListDialects) {
    if (dialect.matches(baseUrl, provider)) {
      return dialect.fetchReport(
        baseUrl,
        apiKey,
        client: effectiveClient,
        onBundledFallback: onBundledFallback,
      );
    }
  }
  return ModelsFetchReport(
    info: (const <String>[], const <String, int>{}, const <String, int>{}),
    diagnostic: ModelsFetchDiagnostic(
      stage: ModelsFetchDiagnostic.stageModels,
      message: 'no model-list dialect handles this endpoint',
    ),
  );
}

http.Client? _dispatchHttpClientForTesting;

/// Test seam — routes every dialect's HTTP through [client] so widget
/// tests can pump the production dispatch path (no [ModelsEndpointFetcher]
/// override, real routing) without network. Null restores the per-dialect
/// default. Not part of the public API.
@visibleForTesting
void setModelsDispatchClientForTesting(http.Client? client) {
  _dispatchHttpClientForTesting = client;
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
    void Function()? onBundledFallback,
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
  bool matches(String baseUrl, String? provider) =>
      provider == dialDispatchHint;

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
    void Function()? onBundledFallback,
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
    // Identity first — a codex entry stays on the codex wire even when
    // its baseUrl was edited (proxy, path prefix).
    if (provider == chatgptCodexDispatchHint || provider == 'chatgpt') {
      return true;
    }
    return isChatGptCodexEndpoint(baseUrl);
  }

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
    void Function()? onBundledFallback,
  }) async {
    final codexClient = client ?? http.Client();
    final ownsClient = client == null;
    try {
      final uri = Uri.parse('${baseUrl.replaceAll(RegExp(r'/+$'), '')}/models');
      final response = await codexClient
          .get(uri, headers: _headers(apiKey))
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        onBundledFallback?.call();
        return _bundled();
      }
      final ids = _idsFrom(response.body);
      if (ids.isEmpty) {
        onBundledFallback?.call();
        return _bundled();
      }
      return (
        ids,
        _knownLimits(ids, chatGptCodexContextWindows),
        _knownLimits(ids, chatGptCodexMaxTokens),
      );
    } on Object {
      onBundledFallback?.call();
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
    void Function()? onBundledFallback,
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

// ── GitHub Copilot (token exchange + Bearer /models) ───────────────────

/// The /models GET watchdog (gh-1990): 15 s by default — a model picker
/// must never hang the flow — tightened by the ops/test fetch-read
/// override ([providerTimeoutsOverride], the documented "model lists"
/// scope of FA_PROVIDER_TIMEOUT_SECONDS).
Duration get _copilotModelsFetchTimeout =>
    providerTimeoutsOverride?.fetchRead ?? const Duration(seconds: 15);

final _copilotTrailingSlashes = RegExp(r'/+$');

final class _CopilotDialect extends ModelListDialect {
  @override
  bool matches(String baseUrl, String? provider) =>
      provider == copilotDispatchHint || isCopilotBaseUrl(baseUrl);

  @override
  Future<ModelsEndpointInfo> fetch(
    String baseUrl,
    String apiKey, {
    http.Client? client,
    void Function()? onBundledFallback,
  }) async => (await fetchReport(baseUrl, apiKey, client: client)).info;

  @override
  Future<ModelsFetchReport> fetchReport(
    String baseUrl,
    String apiKey, {
    http.Client? client,
    void Function()? onBundledFallback,
  }) async {
    final gClient = client ?? http.Client();
    final gOwnsClient = client == null;
    try {
      return await _fetchWithDualPath(baseUrl, apiKey, gClient);
    } finally {
      if (gOwnsClient) gClient.close();
    }
  }

  /// One credential path with the other as the fallback (gh-1990 AC3):
  /// PAT-shaped keys try PAT-direct first (the exchange is known-dead for
  /// them), everything else tries the exchange first. A FAILED primary
  /// path gets exactly one attempt on the other path before the combined
  /// reason is reported; an OAuth token never retries as a direct PAT
  /// Bearer, and a fine-grained PAT never retries into the exchange
  /// (GitHub 404s every PAT exchange by design — see
  /// [fetchCopilotApiToken]).
  Future<ModelsFetchReport> _fetchWithDualPath(
    String baseUrl,
    String apiKey,
    http.Client client,
  ) async {
    final configuredBase = baseUrl.replaceAll(_copilotTrailingSlashes, '');
    final patDirectFirst = isFineGrainedGitHubPat(apiKey);
    Future<ModelsFetchReport> runPath({required bool patDirect}) => patDirect
        ? _fetchModelsDirectPat(configuredBase, apiKey, client)
        : _fetchModelsViaExchange(configuredBase, apiKey, client);

    final primary = await runPath(patDirect: patDirectFirst);
    if (!(primary.diagnostic?.pathFailed ?? false)) return primary;

    // The primary credential route is dead — the other path gets one
    // attempt when the key could plausibly work on it.
    final canFallback = !patDirectFirst && !isOAuthShapedGitHubToken(apiKey);
    if (!canFallback) return primary;

    final secondary = await _fetchModelsDirectPat(
      configuredBase,
      apiKey,
      client,
    );
    if (!(secondary.diagnostic?.pathFailed ?? false)) {
      final failedReason = primary.diagnostic!.message;
      return ModelsFetchReport(
        info: secondary.info,
        note: 'models via the pat-direct fallback (the exchange path '
            'failed: $failedReason)',
        droppedModels: secondary.droppedModels,
      );
    }
    // Both paths failed — one combined reason (AC3), never a bare empty.
    final a = primary.diagnostic!;
    final b = secondary.diagnostic!;
    return ModelsFetchReport(
      info: secondary.info,
      diagnostic: ModelsFetchDiagnostic(
        stage: '${a.stage}+${b.stage}',
        path: a.path,
        httpStatus: a.httpStatus ?? b.httpStatus,
        timedOut: a.timedOut || b.timedOut,
        message: '${a.path} path: ${a.message}; '
            '${b.path} path: ${b.message}',
        hint: a.hint ?? b.hint,
      ),
    );
  }

  /// The exchange path: the GitHub key is worthless to the Copilot API
  /// itself — exchange it for the short-lived Copilot token first
  /// (goal/copilot_provider.md, /models section), then follow the token's
  /// proxy-ep host with the configured tier host as the fallback.
  Future<ModelsFetchReport> _fetchModelsViaExchange(
    String configuredBase,
    String apiKey,
    http.Client client,
  ) async {
    final CopilotApiToken apiToken;
    try {
      apiToken = await fetchCopilotApiToken(
        githubToken: apiKey,
        client: client,
      );
    } on CopilotAuthException catch (error) {
      return ModelsFetchReport(
        info: _emptyCopilotInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageExchange,
          path: ModelsFetchDiagnostic.pathExchange,
          httpStatus: error.statusCode,
          message: 'token exchange failed: ${error.message}',
          hint: _exchangeFailureHint(apiKey),
        ),
      );
    } on TimeoutException {
      return ModelsFetchReport(
        info: _emptyCopilotInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageExchange,
          path: ModelsFetchDiagnostic.pathExchange,
          timedOut: true,
          message: 'token exchange timed out after '
              '${effectiveProviderConnectTimeout.inSeconds}s',
          hint: _exchangeFailureHint(apiKey),
        ),
      );
    } on Object catch (error) {
      return ModelsFetchReport(
        info: _emptyCopilotInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageExchange,
          path: ModelsFetchDiagnostic.pathExchange,
          message: 'token exchange failed: $error',
          hint: _exchangeFailureHint(apiKey),
        ),
      );
    }
    // Same proxy-ep derivation as the chat path: the token names the
    // tenant's API host; the configured tier host is only the fallback.
    final tokenBase = copilotApiBaseUrlFromToken(apiToken.token);
    final effectiveBase = (tokenBase ?? configuredBase).replaceAll(
      _copilotTrailingSlashes,
      '',
    );
    // Tier sanity (gh-1990): a no-proxy-ep token (individual, by design)
    // aimed at a business/enterprise configured host is the classic
    // misrouting — name it instead of letting the wrong host 404 silently.
    final String? tierHint = tokenBase == null &&
            Uri.tryParse(configuredBase)?.host != _individualApiHost
        ? 'this token carries no proxy-ep (individual tokens serve from '
            '$copilotIndividualBaseUrl) — check the configured base URL '
            '($configuredBase)'
        : null;
    return _fetchModelsList(
      effectiveBase,
      copilotApiHeaders(copilotToken: apiToken.token),
      client,
      path: ModelsFetchDiagnostic.pathExchange,
      extraHint: tierHint,
    );
  }

  /// The PAT-direct path (gh-1606): a fine-grained PAT IS the Copilot API
  /// credential — no exchange, no proxy-ep; the configured base URL (the
  /// seat's tier host) is the target.
  Future<ModelsFetchReport> _fetchModelsDirectPat(
    String configuredBase,
    String pat,
    http.Client client,
  ) => _fetchModelsList(
    configuredBase.replaceAll(_copilotTrailingSlashes, ''),
    copilotPatApiHeaders(pat: pat),
    client,
    path: ModelsFetchDiagnostic.pathPatDirect,
  );

  /// GETs `{base}/models` under [headers] and parses the answer with the
  /// per-model filter diagnostics (AC2) — never a bare empty answer.
  Future<ModelsFetchReport> _fetchModelsList(
    String base,
    Map<String, String> headers,
    http.Client client, {
    required String path,
    String? extraHint,
  }) async {
    final uri = Uri.parse('$base/models');
    final http.Response response;
    try {
      response = await client
          .get(uri, headers: headers)
          .timeout(_copilotModelsFetchTimeout);
    } on TimeoutException {
      return ModelsFetchReport(
        info: _emptyCopilotInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageModels,
          path: path,
          timedOut: true,
          message: '$base/models timed out after '
              '${_copilotModelsFetchTimeout.inSeconds}s',
          hint: extraHint,
        ),
      );
    } on Object catch (error) {
      return ModelsFetchReport(
        info: _emptyCopilotInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageModels,
          path: path,
          message: '$base/models request failed: $error',
          hint: extraHint,
        ),
      );
    }
    if (response.statusCode != 200) {
      return ModelsFetchReport(
        info: _emptyCopilotInfo,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageModels,
          path: path,
          httpStatus: response.statusCode,
          message: '$base/models answered HTTP ${response.statusCode}',
          hint: _modelsFailureHint(path, extraHint),
        ),
      );
    }
    final (info, fetchedCount, dropped) = _parseCopilotModelsResponse(
      response.body,
    );
    if (info.$1.isNotEmpty) {
      // Models listed — the partial-filter summary rides the note.
      return ModelsFetchReport(
        info: info,
        note: dropped.isEmpty
            ? null
            : '${dropped.length} of $fetchedCount models filtered '
                '(${_filterReasonSummary(dropped)})',
        droppedModels: dropped,
      );
    }
    if (dropped.isEmpty && fetchedCount == 0) {
      // HTTP 200 with no entries at all — an honest empty from the
      // endpoint (a filtered answer reports below instead). A payload
      // with no "data" list at all is the shape drift the diagnostic
      // names.
      final shaped = _copilotModelsShapeValid(response.body);
      final message = shaped
          ? '$base/models answered with no models (HTTP 200, empty list)'
          : '$base/models answered an unexpected payload shape — no '
              '"data" list (HTTP 200)';
      return ModelsFetchReport(
        info: info,
        diagnostic: ModelsFetchDiagnostic(
          stage: ModelsFetchDiagnostic.stageModels,
          path: path,
          pathFailed: false,
          message: message,
          hint: extraHint,
        ),
      );
    }
    // The filter dropped EVERY entry (AC2) — the counts name the reasons.
    return ModelsFetchReport(
      info: info,
      diagnostic: ModelsFetchDiagnostic(
        stage: ModelsFetchDiagnostic.stageFilter,
        path: path,
        pathFailed: false,
        fetchedCount: fetchedCount,
        filteredCount: dropped.length,
        message: '$fetchedCount models fetched, ${dropped.length} filtered '
            '(${_filterReasonSummary(dropped)})',
        hint: extraHint,
      ),
      droppedModels: dropped,
    );
  }

  /// Remediation for a failed token exchange: classic PATs are the known
  /// dead shape — name the two remedies fa supports (gh-1606). OAuth
  /// tokens get the remedy from the [CopilotAuthException] message.
  String? _exchangeFailureHint(String apiKey) =>
      isClassicGitHubPat(apiKey)
      ? 'classic PATs (ghp_…) are not accepted by the Copilot token '
          'exchange — use the OAuth device flow (/provider copilot) or a '
          'fine-grained PAT (github_pat_…) with the "Copilot Requests" '
          'permission'
      : null;

  /// Remediation for a failed /models call: the seat and the per-tier
  /// hosts (PAT mode adds the permission check).
  String _modelsFailureHint(String path, String? extraHint) {
    final hints = [
      if (path == ModelsFetchDiagnostic.pathPatDirect)
        'check the PAT\'s "Copilot Requests" permission '
            '(github.com/settings/personal-access-tokens → edit → '
            'Permissions) and the account\'s Copilot seat'
      else
        'check the Copilot seat (github.com/settings/copilot) and the '
            'configured base URL — individual: $copilotIndividualBaseUrl, '
            'business: $copilotBusinessBaseUrl, enterprise: '
            '$copilotEnterpriseBaseUrl',
      ?extraHint,
    ];
    return hints.join('; ');
  }
}

const _emptyCopilotInfo = (<String>[], <String, int>{}, <String, int>{});

/// The individual-tier API host (no-proxy-ep tokens serve from here).
final _individualApiHost = Uri.parse(copilotIndividualBaseUrl).host;

/// Whether the /models body at least carries a "data" list (the shape
/// check behind the empty-list vs unexpected-shape reasons).
bool _copilotModelsShapeValid(String body) {
  final decoded = jsonDecode(body);
  return decoded is Map<String, dynamic> && decoded['data'] is List;
}

/// Maps the Copilot `{data: [{id, capabilities.limits.{max_context_window_
/// tokens, max_output_tokens}}]}` shape into [ModelsEndpointInfo] (the
/// limits are nested, so [parseModelsResponse] reads only the ids).
/// Non-chat entries are filtered out — see [_copilotModelDropReason].
/// Alongside the info it answers the entry count and the per-model
/// (id, drop reason) pairs for the filter transparency (gh-1990 AC2).
(ModelsEndpointInfo, int, List<(String, String)>)
_parseCopilotModelsResponse(String body) {
  final decoded = jsonDecode(body);
  final data = decoded is Map<String, dynamic> ? decoded['data'] : null;
  if (data is! List) {
    const dropped = <(String, String)>[];
    return (_emptyCopilotInfo, 0, dropped);
  }
  final ids = <String>[];
  final windows = <String, int>{};
  final maxTokens = <String, int>{};
  final dropped = <(String, String)>[];
  for (final entry in data) {
    if (entry is! Map<String, dynamic>) {
      dropped.add(const ('(malformed entry)', 'malformed entry'));
      continue;
    }
    final id = entry['id'];
    if (id is! String || id.isEmpty) {
      dropped.add(const ('(no id)', 'no id'));
      continue;
    }
    final dropReason = _copilotModelDropReason(entry);
    if (dropReason != null) {
      dropped.add((id, dropReason));
      continue;
    }
    ids.add(id);
    final limits =
        ((entry['capabilities'] as Map<String, dynamic>?)?['limits']
            as Map<String, dynamic>?);
    final window = (limits?['max_context_window_tokens'] as num?)?.toInt();
    if (window != null) windows[id] = window;
    final cap = (limits?['max_output_tokens'] as num?)?.toInt();
    if (cap != null) maxTokens[id] = cap;
  }
  ids.sort();
  return ((ids, windows, maxTokens), data.length, dropped);
}

/// WHY [entry] is not picker-eligible — the reason strings of the gh-1990
/// filter transparency. Null = selectable. The criteria are pi-mono
/// parity (`packages/ai/src/auth/oauth/github-copilot.ts`
/// `isSelectableCopilotModel`): the entry must be picker-enabled, not
/// policy-disabled, and tool-call capable (embeddings and completion-only
/// entries carry `model_picker_enabled: false` already). On top of pi:
/// when the payload declares `supported_endpoints`, `/chat/completions`
/// must be among them — our provider streams there, and responses-only
/// models (e.g. `gpt-5.6-sol` on `["/responses", "ws:/responses"]`) 400
/// with "not accessible via the /chat/completions endpoint". Payloads
/// without the field (older/self-hosted proxies) are kept — they read as
/// "picker flag absent", the reason AC2 pins for the individual-tier
/// shapes. This only NAMES which criterion fired; the criteria themselves
/// are unchanged.
String? _copilotModelDropReason(Map<String, dynamic> entry) {
  final picker = entry['model_picker_enabled'];
  if (picker == null) return 'picker flag absent';
  if (picker != true) return 'picker flag false';
  final policy = entry['policy'];
  if (policy is Map && policy['state'] == 'disabled') return 'policy disabled';
  final capabilities = entry['capabilities'];
  final supports = capabilities is Map ? capabilities['supports'] : null;
  if (supports is Map && supports['tool_calls'] == false) {
    return 'no tool_calls';
  }
  final endpoints = entry['supported_endpoints'];
  if (endpoints is List && !endpoints.contains('/chat/completions')) {
    return 'endpoint unsupported';
  }
  return null;
}

/// The grouped drop-reason summary for the filter messages: one distinct
/// reason reads bare («picker flag absent»), several carry counts
/// («picker flag absent ×10, policy disabled ×2»).
String _filterReasonSummary(List<(String, String)> dropped) {
  final counts = <String, int>{};
  for (final (_, reason) in dropped) {
    counts[reason] = (counts[reason] ?? 0) + 1;
  }
  return counts.entries
      .map(
        (entry) => entry.value == 1
            ? entry.key
            : '${entry.key} ×${entry.value}',
      )
      .join(', ');
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
    void Function()? onBundledFallback,
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
    if (loaded != null) {
      _cached = loaded;
      return;
    }
    // Network unavailable / 404 / timeout — seed the bundled fallback so
    // pickers still get catalog metadata + the data-driven chat id
    // fallback chain. The remote URL remains the source of truth when
    // it answers.
    _cached ??= bundledRemoteModelsCatalog;
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

  /// Flat per-Mtok pricing the catalog lists for [providerKind]/[modelId],
  /// or null when the catalog ships no number — the picker renders `—`
  /// (never 0.00) on a miss (issue #278 E3).
  RemoteModelPricing? pricingFor(String? providerKind, String modelId) {
    final entry = _cached?.providers[providerKind ?? ''];
    return entry?.pricing[modelId];
  }

  /// Chat model ids the catalog knows about for [providerKind] — the
  /// LAST-RESORT fallback the picker uses when the live `/v1/models`
  /// fetch is empty. Endpoint-reported ids always win; this list is
  /// only consulted on the empty-result branch so the picker stays
  /// useful when the endpoint can't answer.
  List<String> chatFallbackFor(String? providerKind) {
    return remoteChatModelsFor(providerKind: providerKind, catalog: _cached);
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
