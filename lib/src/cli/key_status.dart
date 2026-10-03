/// Key-status and error-line rendering for the CLI REPL's `AgentCli`
/// (`agent_cli.dart`), split into pure form to keep that file under the
/// repo's 2800-line size gate. A [KeyStatusRenderer] is an immutable
/// snapshot of the host's config-backed key resolution inputs; the host
/// builds one per render so live state (a `/provider` switch, the active
/// saved entry) is always current. Key material is never rendered — names
/// and sources only.
library;

import '../model.dart';
import '../model_roles/provider_catalog.dart';
import '../secrets/secure_key_store.dart';
import 'custom_providers.dart';
import 'provider_error_text.dart';

/// The env-vs-store shadowing rule (gh-1000 E2), shared by the boot note
/// (bin/fah.dart), the restore note (session_commands
/// `_noteKeyShadowing`), and the banner hint ([KeyStatusRenderer
/// .envKeyHint]): the slot holds DIFFERENT values in the environment and
/// the store, and the env value is the one sent. One provenance rule —
/// three call sites used to carry three drifting copies (round-3 review).
bool envShadowsStoredKey(String? envValue, String? storedValue) =>
    envValue != null &&
    envValue.isNotEmpty &&
    storedValue != null &&
    storedValue != envValue;

/// The provenance note for a shadowed slot (null when the env value is
/// absent, empty, or agrees with the store): names the variable and the
/// provenance order. Callers style it (`note: …`) for their surface.
String? envShadowingNote(
  String keyName,
  String? envValue,
  String? storedValue,
) => envShadowsStoredKey(envValue, storedValue)
    ? 'the environment variable $keyName shadows a DIFFERENT '
          'stored key — the env value is the one sent'
    : null;

/// Renders the banner's key-status line and `error:` diagnostics from a
/// snapshot of the host CLI's key inputs.
final class KeyStatusRenderer {
  /// Creates a renderer over the host's live key inputs.
  const KeyStatusRenderer({
    required this.rolesDriven,
    required this.providerKind,
    required this.explicitToken,
    required this.activeCustomName,
    required this.red,
    this.secureKeys,
    this.customProviders,
    this.envVarIsSet,
    this.envVarValue,
  });

  /// Whether roles mode drives the session (its keys come from the chain
  /// environment only, never the secure store).
  final bool rolesDriven;

  /// The live provider adapter kind.
  final String providerKind;

  /// Whether the live key came from an explicit `/provider` token.
  final bool explicitToken;

  /// The active saved custom provider's entry name, or null.
  final String? activeCustomName;

  /// The secure-key cache, or null when secure storage is unavailable.
  final SecureKeyCache? secureKeys;

  /// The saved custom-provider registry, or null.
  final CustomProviderRegistry? customProviders;

  /// Whether an environment variable is set, or null when the host cannot
  /// check.
  final bool Function(String)? envVarIsSet;

  /// Reads an environment variable's value, or null when the host has no
  /// environment.
  final String? Function(String)? envVarValue;

  /// Styles a diagnostic line red (the host's ANSI styling).
  final String Function(String) red;

  /// The banner's key-status line: the name of the env var supplying the
  /// provider key (never the value), or a "no key set" warning when the
  /// provider expects a key the host does not have. Null when the provider
  /// declares no key env vars (custom/test providers) — no warning then —
  /// and null for a custom endpoint (base URL other than the catalog
  /// default), which may legitimately run keyless (local llama.cpp/Ollama/
  /// LM Studio servers).
  ///
  /// Legacy mode reads the names by provider KIND, matching the executable's
  /// key lookup: `openai-completions` accepts OPENROUTER_API_KEY/
  /// OPENAI_API_KEY on the catalog default endpoint; on a custom endpoint
  /// only endpoint-scoped store keys count (the env names describe the
  /// default endpoint — issue #40). Roles mode keys per resolved chain
  /// entry, so the live model's provider names are the right ones there. An
  /// explicit `/provider` token has no env var to name and reads as
  /// "provided" — the value is never printed.
  String? keyStatusLine(Model model) {
    final spec = resolveCliProviderSpec(
      rolesDriven ? model.provider : providerKind,
      honorBuildFilter: true,
    );
    final names = spec?.apiKeyEnvNames;
    if (names == null || names.isEmpty) return null;
    // An explicit /provider token (or a saved custom entry's key) IS the
    // active key: name its store slot. The value is never printed.
    if (!rolesDriven && explicitToken) return explicitTokenKeyStatus(model);
    return resolvedKeyStatus(model, spec, names);
  }

  /// Key status when an explicit token or saved-entry key is in play.
  String explicitTokenKeyStatus(Model model) {
    final entryKey = activeCustomKeyName();
    if (hasStoredKey(entryKey)) return 'key: $entryKey';
    return scopedTokenKeyStatus(model);
  }

  /// Whether [name] names a key present in the secure store.
  bool hasStoredKey(String? name) =>
      name != null && secureKeys?.read(name) != null;

  /// Key status fallback for an explicit token: the host-scoped store slot,
  /// or the anonymous "provided" marker.
  String scopedTokenKeyStatus(Model model) {
    final scoped = CustomProviderRegistry.keyNameFor(model.baseUrl);
    if (secureKeys?.read(scoped) != null) return 'key: $scoped';
    return 'key: provided';
  }

  /// Key status from the resolution order: on the spec's DEFAULT endpoint
  /// genuine environment values first (they differ from the store's
  /// entry); then the active custom entry's slot (multi-account entries
  /// use name-scoped ones), the host-scoped slot, and legacy env-name
  /// entries (env or store — indistinguishable here). On a custom endpoint
  /// the catalog env names are never in play (they describe the default
  /// endpoint — the same rule [optionalProviderApiKey] enforces at boot),
  /// so only the store slots can be the source.
  String? resolvedKeyStatus(
    Model model,
    ProviderSpec? spec,
    List<String> names,
  ) {
    final keys = secureKeys;
    if (!_legacyCustomEndpoint(model, spec)) {
      final envKey = envKeyStatus(names);
      if (envKey != null) return envKey;
    }
    final entryKey = activeCustomKeyName();
    if (entryKey != null && keys?.read(entryKey) != null) {
      return 'key: $entryKey';
    }
    final scopedName = CustomProviderRegistry.keyNameFor(model.baseUrl);
    if (keys?.read(scopedName) != null) return 'key: $scopedName';
    return fallbackKeyStatus(model, spec, names);
  }

  /// Whether legacy mode resolves on a CUSTOM endpoint (base URL other than
  /// the catalog default). Roles mode is exempt: its keys live in the
  /// environment by design.
  bool _legacyCustomEndpoint(Model model, ProviderSpec? spec) =>
      !rolesDriven && spec != null && model.baseUrl != spec.defaultBaseUrl;

  /// Key status fallback: any legacy env-name entry, else the "no key set"
  /// guidance (null for non-default endpoints without a key — they may
  /// legitimately run keyless).
  String? fallbackKeyStatus(
    Model model,
    ProviderSpec? spec,
    List<String> names,
  ) {
    if (_legacyCustomEndpoint(model, spec)) return null;
    final set = names
        .where((name) => envVarIsSet?.call(name) ?? false)
        .firstOrNull;
    if (set != null) return 'key: $set';
    return 'key: no key set (want ${names.first})';
  }

  /// The first env-name holding a genuine environment value (differs from
  /// the store's entry), as a `key: <name>` status, or null.
  String? envKeyStatus(List<String> names) {
    final keys = secureKeys;
    for (final name in names) {
      final value = envVarValue?.call(name);
      if (value != null && value.isNotEmpty && value != keys?.read(name)) {
        return 'key: $name';
      }
    }
    return null;
  }

  /// The active saved custom provider's secure-store key name, or null when
  /// none is active (or the entry is keyless).
  String? activeCustomKeyName() {
    final name = activeCustomName;
    if (name == null) return null;
    return customProviders?.find(name)?.keyName;
  }

  /// The `error:` diagnostic line for a failed run. [baseUrl] is the
  /// effective endpoint of the model the run used. Provider JSON blobs
  /// (OpenRouter wraps upstream errors in nested JSON) are compacted to the
  /// most specific message. A connection-level failure ("Connection
  /// refused" — a SocketException, or a package:http ClientException
  /// wrapping one; the provider adapters reduce both to their message
  /// string, so detection is textual) appends the endpoint hint: the
  /// effective base URL from the config or `--base-url` is almost always
  /// the thing to fix then. A 401-class auth failure appends the key
  /// diagnostic: which env var is in play, whether an environment value is
  /// shadowing a DIFFERENT stored key (env wins over the secure store — the
  /// classic stale-export footgun), or that no key resolved at all.
  String errorLine(String message, String baseUrl) {
    final compact = compactProviderError(message);
    if (isAuthError(compact)) {
      return red('error: $compact${authHint(baseUrl)}');
    }
    if (!compact.toLowerCase().contains('connection refused')) {
      return red('error: $compact');
    }
    return red(
      'error: $compact — check the endpoint in ~/.fah/config.yaml '
      '(baseUrl: $baseUrl) or pass --base-url',
    );
  }

  /// 401-class detection across provider wordings (OpenAI/OpenRouter "401:
  /// API Key invalid", Anthropic "authentication_error", plain
  /// "Unauthorized").
  static final _authErrorCode = RegExp(r'\b401\b');

  bool isAuthError(String compact) {
    final lower = compact.toLowerCase();
    return _authErrorCode.hasMatch(compact) ||
        lower.contains('unauthorized') ||
        lower.contains('authentication_error') ||
        (lower.contains('api key') && lower.contains('invalid'));
  }

  /// The ` — ...` suffix for [errorLine] on auth failures. Never prints key
  /// material — names and sources only. Mirrors the provider key resolution
  /// order: on the spec's DEFAULT endpoint a genuine environment value →
  /// endpoint-scoped store entry → legacy env-name store entry; on a custom
  /// endpoint only the endpoint-scoped store entries can be the source (the
  /// boot resolver never probes the catalog env names there — issue #40).
  ///
  /// Roles mode gets the generic env-only hint ONLY for its genuine chain
  /// failures (a catalog-default endpoint). A custom endpoint under roles
  /// mode is a provider-binding failure — the hint names the saved entry,
  /// the expected key slot, and the one-line fix (gh-1000 AC2): a restored
  /// session or pinned role re-resolved onto a custom provider whose key
  /// did not follow.
  String authHint(String baseUrl) {
    if (rolesDriven) {
      final customHint = customEndpointAuthHint(baseUrl);
      if (customHint != null) return customHint;
      return ' — roles mode reads keys from the environment only; check '
          'the chain env vars in ~/.fah/config.yaml';
    }
    final spec = resolveCliProviderSpec(providerKind, honorBuildFilter: true);
    if (spec == null || spec.apiKeyEnvNames.isEmpty) {
      return ' — check the credentials for $baseUrl';
    }
    final names = spec.apiKeyEnvNames;
    final scopedName = CustomProviderRegistry.keyNameFor(baseUrl);
    // Trailing-slash-normalized (the shared sameEndpoint rule) — one
    // endpoint-equality rule with _isCatalogDefaultEndpoint (round-3
    // review).
    final onDefaultEndpoint = sameEndpoint(baseUrl, spec.defaultBaseUrl);
    if (onDefaultEndpoint) {
      // A genuine environment key in play: warn when it shadows a different
      // same-name store entry, else name it as the source.
      final envHint = envActiveHint(names, baseUrl);
      if (envHint != null) return envHint;
    }
    // Endpoint-scoped store key (what /provider and the wizard write): the
    // active custom entry's name-scoped slot first, then the host-scoped
    // one.
    final entryKey = activeCustomKeyName();
    final scoped = entryKey ?? scopedName;
    final storedHint = storedKeyHint(scoped, baseUrl);
    if (storedHint != null) return storedHint;
    if (onDefaultEndpoint) {
      // Legacy env-name store key (older versions wrote these).
      final legacy = names
          .where((name) => (envVarValue?.call(name) ?? '').isNotEmpty)
          .firstOrNull;
      if (legacy != null) return storeHintMessage(legacy, baseUrl);
    }
    return noKeyHint(entryKey, baseUrl, spec, scopedName, names);
  }

  /// The hint naming a secure-store key as the source.
  String storeHintMessage(String name, String baseUrl) {
    final label = secureKeys?.label ?? 'secure store';
    return ' — the key came from the $label ($name); verify it is valid '
        'for $baseUrl or replace it with /key set $name <value>';
  }

  /// The fallback hint when no key resolved (or the token was rejected).
  String noKeyHint(
    String? entryKey,
    String baseUrl,
    ProviderSpec? spec,
    String scopedName,
    List<String> names,
  ) {
    final suggested =
        entryKey ??
        (baseUrl != spec?.defaultBaseUrl ? scopedName : names.first);
    return explicitToken
        ? ' — the /provider token was rejected; set a fresh one with '
              '/key set $suggested <value>'
        : ' — no key set; store one with /key set $suggested <value>';
  }

  /// The hint for a genuine environment key, or null when none is in play.
  String? envActiveHint(List<String> names, String baseUrl) {
    final envActive = activeEnvKeyName(names);
    if (envActive == null) return null;
    return envKeyHint(envActive, baseUrl);
  }

  /// The first env-name holding a genuine environment key (differs from the
  /// same-name store entry), or null.
  String? activeEnvKeyName(List<String> names) {
    final keys = secureKeys;
    return names.where((name) {
      final value = envVarValue?.call(name);
      return value != null && value.isNotEmpty && value != keys?.read(name);
    }).firstOrNull;
  }

  /// The hint for a genuine environment key: the shadowing warning when a
  /// DIFFERENT same-name store entry exists, else the source note. The
  /// shadowing detection is the shared [envShadowsStoredKey] rule (the
  /// boot and restore notes use the same one). An UNWIRED [envVarValue]
  /// (embedded hosts may omit it) degrades conservatively: with a store
  /// twin present the warning still fires — this hint only renders when
  /// the env value is the one actually sent, so an uncompared twin is a
  /// real shadow (the pre-round-3 availability); without a twin there is
  /// nothing to shadow.
  String envKeyHint(String envActive, String baseUrl) {
    final keys = secureKeys;
    final storedTwin = keys?.read(envActive);
    final envValue = envVarValue?.call(envActive);
    final shadowed = envValue != null
        ? envShadowsStoredKey(envValue, storedTwin)
        : storedTwin != null && storedTwin.isNotEmpty;
    if (shadowed) {
      final label = keys?.label ?? 'secure store';
      return ' — the environment variable $envActive shadows a DIFFERENT '
          'key in the $label; the env value is the one sent — fix or '
          'unset it, or /key delete $envActive';
    }
    return ' — the key came from the environment ($envActive); verify it '
        'is valid for $baseUrl or replace it with '
        '/key set $envActive <value>';
  }

  /// The hint for a key read from the secure store, or null when the slot is
  /// empty.
  String? storedKeyHint(String name, String baseUrl) {
    if (secureKeys?.read(name) == null) return null;
    return storeHintMessage(name, baseUrl);
  }

  /// The auth hint for a CUSTOM endpoint (no catalog spec's default URL)
  /// — roles mode included, which otherwise shows its generic env-only
  /// hint for genuine chain failures. Null for catalog-default endpoints.
  ///
  /// Names the failing provider (the saved entry serving the endpoint, or
  /// the endpoint itself), the expected source (the entry's key slot or
  /// the endpoint-scoped store slot), and the one-line fix — never the
  /// bare roles-mode hint (gh-1000 AC2/AC5).
  String? customEndpointAuthHint(String baseUrl) {
    if (_isCatalogDefaultEndpoint(baseUrl)) return null;
    final entry = _entryForEndpoint(baseUrl);
    final keyName =
        entry?.keyName ?? CustomProviderRegistry.keyNameFor(baseUrl);
    final storedHint = storedKeyHint(keyName, baseUrl);
    if (storedHint != null) return storedHint;
    final target = entry != null ? 'provider "${entry.name}"' : baseUrl;
    final login = entry != null ? ' (or /provider ${entry.name})' : '';
    return ' — no key resolved for $target; set it with '
        '/key set $keyName <value>$login';
  }

  /// Whether [baseUrl] IS the current provider kind's own default
  /// endpoint. ONLY there is the generic roles hint honest: a
  /// catalog-default pin resolves through the provider's env-name chain
  /// (no endpoint slot — mirroring the resolver). Any other endpoint is a
  /// custom binding whose endpoint-scoped slot the resolver actually
  /// probes (gh-1000 AC2/AC5) — the hint must name that slot, not claim
  /// "environment only". Trailing-slash-normalized (the shared
  /// [sameEndpoint] rule): a default endpoint saved with a trailing slash
  /// must not masquerade as a custom slot (round-3 review).
  bool _isCatalogDefaultEndpoint(String baseUrl) {
    final spec = resolveCliProviderSpec(providerKind, honorBuildFilter: true);
    return spec != null && sameEndpoint(spec.defaultBaseUrl, baseUrl);
  }

  /// The saved custom entry serving [baseUrl]: the active entry when it
  /// matches (two accounts can share one endpoint — the active one is the
  /// one in play), else the first endpoint match.
  CustomProviderEntry? _entryForEndpoint(String baseUrl) {
    final registry = customProviders;
    if (registry == null) return null;
    final active = activeCustomName == null
        ? null
        : registry.find(activeCustomName!);
    if (active != null && _sameEndpoint(active.baseUrl, baseUrl)) {
      return active;
    }
    for (final entry in registry.entries) {
      if (_sameEndpoint(entry.baseUrl, baseUrl)) return entry;
    }
    return null;
  }

  /// Endpoint equality ignoring a trailing slash — delegates to the shared
  /// [sameEndpoint] rule (custom_providers.dart), so every endpoint
  /// comparison in the CLI and the roles resolver stays one rule.
  bool _sameEndpoint(String a, String b) => sameEndpoint(a, b);
}
