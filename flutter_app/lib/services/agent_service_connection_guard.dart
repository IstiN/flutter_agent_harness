part of 'agent_service.dart';

// Part of agent_service (issue #327): the provider connection guard -
// model/auth must resolve from the SAME registry row - plus the auth
// error decoration that names the row a 401 went out with. Extracted to
// keep agent_service.dart under the 2800-line gate.

/// the adapter skips `Authorization: Bearer` when the key is empty.
bool isCodeMieProvider(String baseUrl) =>
    baseUrl.contains('/code-assistant-api/');

/// Thrown when a would-be connection assembles model and auth from
/// DIFFERENT provider rows, or rides a hosted/CodeMie endpoint with no
/// resolvable credential on this surface (issue #327). The message is
/// user-facing: it names the owning rows so the fix is obvious.
class ProviderConnectionException implements Exception {
  ProviderConnectionException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The display name of the row serving [baseUrl]: the custom registry
/// entry, else the built-in hosted preset (name capitalized), else null.
String? _connectionDisplayName(ProviderRegistry? registry, String baseUrl) {
  final provider = providerForBaseUrl(baseUrl, registry);
  if (provider == null) return null;
  return switch (provider) {
    ProviderPreset preset => switch (preset) {
      ProviderPreset.openrouter => 'OpenRouter',
      ProviderPreset.ollamaCloud => 'Ollama Cloud',
      ProviderPreset.gemini => 'Google Gemini',
      ProviderPreset.aiin => 'AIIN',
      ProviderPreset.dial => 'DIAL',
      ProviderPreset.minimax => 'MiniMax',
      _ => preset.name,
    },
    final CustomProvider custom => custom.name,
    _ => provider.toString(),
  };
}

/// Issue #327: `null` when [config] can assemble model AND auth from the
/// same provider row on this surface; otherwise a user-facing reason
/// naming the broken row(s). Pure: no I/O, safe from boot and pickers.
String? providerConnectionProblem(
  ProviderRegistry? registry,
  AgentConfig config, {
  bool extensionHost = false,
}) {
  if (AgentService._isOnDeviceKind(config.providerKind)) return null;
  return _modelRowMismatch(registry, config) ??
      _missingCredential(registry, config, extensionHost: extensionHost);
}

/// The registry-row half of the guard only (issue #327 review MAJOR 2):
/// boot restore DEGRADES on this half (warn + refuse the request at send
/// time), while the credential half still refuses the boot outright - a
/// keyless credential-bearing endpoint has nothing to send with.
String? modelRowMismatch(ProviderRegistry? registry, AgentConfig config) =>
    _modelRowMismatch(registry, config);

/// Fails when [config.modelId] is owned by a registry row OTHER than the
/// one serving [config.baseUrl] — the #327 fingerprint: an OpenRouter
/// model id riding a CodeMie (or any other) endpoint sends the request to
/// an endpoint/auth pair that never heard of the model.
String? _modelRowMismatch(ProviderRegistry? registry, AgentConfig config) {
  if (registry == null) return null;
  final entries = registry.providers;
  final serving = entries.where((e) => e.baseUrl == config.baseUrl);
  if (serving.any((e) => e.modelId == config.modelId)) return null;
  final owners = entries
      .where((e) => e.modelId == config.modelId && e.baseUrl != config.baseUrl)
      .toList();
  if (owners.isEmpty) return null;
  // Same-host rows are ONE provider infrastructure — path variants,
  // duplicates, self-hosted gateways (issue #327 review MAJOR 3): a model
  // id reused between them is the endpoint's own business, not a
  // mixed-row assembly. Only a DIFFERENT host owning the id stays
  // suspicious (the #327 fingerprint: an OpenRouter-format id riding a
  // CodeMie endpoint).
  final host = _hostOf(config.baseUrl);
  if (owners.every((e) => _hostOf(e.baseUrl) == host)) return null;
  final servingName =
      _connectionDisplayName(registry, config.baseUrl) ?? config.baseUrl;
  final ownerNames = owners.map((e) => e.name).toSet().join("', '");
  // When the endpoint has no registry row the display name IS the url -
  // appending it again reads "url (url)" (issue #327 relay-path guard).
  final servingRef = servingName == config.baseUrl
      ? servingName
      : '$servingName (${config.baseUrl})';
  return "Model ${config.modelId} belongs to provider '$ownerNames' "
      '(${owners.first.baseUrl}), active connection is $servingRef. '
      'Pick the model from the SAME provider row as the endpoint you '
      'are connecting to.';
}

/// The host of [url] — the comparison key for "same provider
/// infrastructure". Unparseable urls compare verbatim.
String _hostOf(String url) => Uri.tryParse(url)?.host ?? url;

/// Fails when a hosted-preset or CodeMie endpoint has no key/sign-in on
/// THIS surface (per-surface partitions, issue #221 D2): an empty key on
/// those endpoints is a guaranteed 401 ("No cookie auth credentials
/// found" for CodeMie). Custom self-hosted endpoints (localhost Ollama,
/// private gateways) stay keyless-legal.
String? _missingCredential(
  ProviderRegistry? registry,
  AgentConfig config, {
  bool extensionHost = false,
}) {
  if (config.apiKey.isNotEmpty) return null;
  final baseUrl = config.baseUrl;
  if (isCodeMieProvider(baseUrl)) {
    // Issue #327 review MAJOR 1: the extension's cookie sign-in
    // deliberately saves an EMPTY key — the service worker's streaming
    // fetch attaches the shared browser jar, a bearer key never exists.
    // A keyless CodeMie row is the DESIGNED state there, not a 401.
    if (extensionHost) return null;
    final name = _connectionDisplayName(registry, baseUrl) ?? 'CodeMie';
    return '$name: no sign-in on this surface — sign in here or sync the '
        'account from a surface that has it.';
  }
  for (final preset in hostedProviderPresets) {
    if (preset.baseUrl != null && preset.baseUrl == baseUrl) {
      final name = _connectionDisplayName(registry, baseUrl) ?? preset.name;
      final keyName = hostedProviderKeyName(preset) ?? 'API key';
      return '$name: no API key on this surface — add $keyName here or '
          'sync it from a surface that has it.';
    }
  }
  return null;
}

/// Wraps [inner] so HTTP auth failures (401/403, key/cookie/credentials
/// wording) carry a `'[<entry>] '` prefix naming the provider row the
/// request went out with. [label] resolving to null (no known row)
/// leaves every event untouched. Pure stream plumbing — visible for the
/// issue #327 decoration tests.
StreamFunction decorateAuthErrors(
  StreamFunction inner,
  String? Function() label,
) {
  final authFailure = RegExp(r'^40[13]:|^[45]\d\d:?.*(unauthorized|api key|credentials|sign in)', caseSensitive: false);
  return (model, context, {cancelToken}) {
    final owner = label();
    final stream = inner(model, context, cancelToken: cancelToken);
    if (owner == null || owner.isEmpty) return stream;
    final controller = AssistantMessageEventStream();
    Future<void> pump() async {
      try {
        await for (final event in stream) {
          var outgoing = event;
          if (event is ErrorEvent) {
            final text = event.error.errorMessage ?? '';
            if (authFailure.hasMatch(text.trim())) {
              final patched = event.error.copyWith(
                errorMessage: '[$owner] $text',
              );
              outgoing = ErrorEvent(
                reason: event.reason,
                error: patched,
              );
            }
          }
          controller.push(outgoing);
        }
      } on Object catch (error) {
        controller.push(
          ErrorEvent(
            reason: StopReason.error,
            error: AssistantMessage(
              content: const [],
              api: model.api,
              provider: model.provider,
              model: model.id,
              usage: Usage.zero,
              stopReason: StopReason.error,
              errorMessage: '[internal] $error',
              timestamp: DateTime.now(),
            ),
          ),
        );
      }
      controller.end();
    }
    unawaited(pump());
    return controller;
  };
}

/// Send-path guard members: same library, extension keeps the
/// unqualified call sites inside [AgentService] untouched.
extension _AgentServiceSendGuard on AgentService {
  /// Issue #327 review MAJOR 2: a boot-restored connection never runs
  /// [reconfigure], so the registry-row half of the guard runs here — at
  /// request time. The session boots (transcript visible), but a request
  /// on mismatched rows is refused with the row-naming message instead of
  /// 401-ing through the wrong provider. (The credential half stays in
  /// reconfigure/boot: the service cannot see surface-stored keys to
  /// re-check them per request.)
  String? _liveConnectionRowProblem() {
    final registry = _providerRegistry;
    if (registry == null) return null;
    if (AgentService._isOnDeviceKind(_providerKind)) return null;
    return _modelRowMismatch(
      registry,
      AgentConfig(
        providerKind: _providerKind,
        modelId: _agent.state.model.id,
        baseUrl: _activeBaseUrl,
        apiKey: _activeApiKey,
      ),
    );
  }
}
