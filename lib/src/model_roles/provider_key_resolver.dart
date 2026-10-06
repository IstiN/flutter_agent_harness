/// The ONE provider-key resolution chain, shared by the CLI and the apps.
///
/// For a catalog spec's DEFAULT hosted endpoint, in order:
/// 1. a genuine environment value of the catalog env names (one that
///    differs from the store's entry, so it came from the actual
///    environment — the ecosystem convention stays first);
/// 2. the endpoint-scoped secure-store entry (`FA_KEY_<HOST>` — what both
///    the CLI's `/provider` flow and the app's provider registry write);
/// 3. legacy env-name store entries, written by older versions.
///
/// For ANY OTHER endpoint only endpoint-scoped store entries resolve (the
/// active custom entry's key name, then the host-scoped one) — the catalog
/// env names (`OPENROUTER_API_KEY` & friends) describe the default endpoint
/// and must never hijack a custom one (the user's OpenRouter key silently
/// serving api.acme.example).
///
/// Pure Dart: the caller supplies the env and store readers, so the CLI
/// (env vars + SecureKeyCache) and the Flutter app (dart-defines/dotenv +
/// session-keys store) share the ordering without sharing plumbing.
library;

import '../cli/custom_providers.dart' show CustomProviderRegistry;

/// Resolves the API key for [baseUrl] given the catalog env [envNames] and
/// the spec's [defaultBaseUrl]. [envRead] reads genuine environment values;
/// [storeRead] reads the secure store (null store = env-only resolution,
/// e.g. tests or the web build). [activeCustomKeyName] is the active custom
/// registry entry's own key name, when known (wins over the host-scoped
/// entry for non-default endpoints).
String? resolveEndpointKey({
  required List<String> envNames,
  required String defaultBaseUrl,
  required String baseUrl,
  required String? Function(String name) envRead,
  required String? Function(String name)? storeRead,
  String? activeCustomKeyName,
}) {
  final name = resolveEndpointKeyName(
    envNames: envNames,
    defaultBaseUrl: defaultBaseUrl,
    baseUrl: baseUrl,
    envRead: envRead,
    storeRead: storeRead,
    activeCustomKeyName: activeCustomKeyName,
  );
  if (name == null) return null;
  // A name from the env leg resolves from the environment (the name step
  // already verified the value is genuine); every other leg reads the
  // store. One chain — the value can never disagree with the slot.
  if (envNames.contains(name)) {
    final env = envRead(name);
    if (env != null && env.isNotEmpty && env != storeRead?.call(name)) {
      return env;
    }
  }
  return storeRead?.call(name);
}

/// Resolves the effective key-slot NAME for [baseUrl] — the host-facing
/// half of the same chain [resolveEndpointKey] resolves values through
/// (issue #1322 Gap 2). Order mirrors the value chain exactly:
///
/// 1. (default endpoint only) the first [envNames] entry holding a
///    genuine environment value — the ecosystem convention stays first;
/// 2. the endpoint-scoped secure-store slot (`FA_KEY_<HOST>`, or
///    [activeCustomKeyName] for a non-default endpoint — the entry's own
///    pinned slot wins over the host-scoped one);
/// 3. (default endpoint only) legacy env-name store entries.
///
/// [defaultBaseUrl] is nullable: a host that does not know the catalog
/// default passes null (the default) and gets store-only resolution —
/// the env-name leg can then never hijack a custom endpoint (issue #40).
String? resolveEndpointKeyName({
  required List<String> envNames,
  required String? defaultBaseUrl,
  required String baseUrl,
  required String? Function(String name) envRead,
  required String? Function(String name)? storeRead,
  String? activeCustomKeyName,
}) {
  final defaultEndpoint = defaultBaseUrl != null && baseUrl == defaultBaseUrl;
  if (defaultEndpoint) {
    final genuine = _firstGenuineEnvName(envNames, envRead, storeRead);
    if (genuine != null) return genuine;
  }
  if (!defaultEndpoint && activeCustomKeyName != null) {
    if (_hasStoreValue(activeCustomKeyName, storeRead)) {
      return activeCustomKeyName;
    }
  }
  final scoped = CustomProviderRegistry.keyNameFor(baseUrl);
  if (_hasStoreValue(scoped, storeRead)) return scoped;
  if (defaultEndpoint) {
    for (final name in envNames) {
      if (_hasStoreValue(name, storeRead)) return name;
    }
  }
  return null;
}

/// The first env name holding a genuine environment value (differs from
/// the matching store entry — i.e. it came from the process environment).
String? _firstGenuineEnvName(
  List<String> envNames,
  String? Function(String name) envRead,
  String? Function(String name)? storeRead,
) {
  for (final name in envNames) {
    final value = envRead(name);
    if (value != null && value.isNotEmpty && value != storeRead?.call(name)) {
      return name;
    }
  }
  return null;
}

/// Whether [name] holds a single non-empty store value.
bool _hasStoreValue(String name, String? Function(String name)? storeRead) {
  final value = storeRead?.call(name);
  return value != null && value.isNotEmpty;
}

/// The host-facing answer to "which slot does this provider/model actually
/// resolve to?" (issue #1322 Gap 2). Pure data: [slotName] is what the
/// request path WILL use (env var or secure-store slot name — never the
/// value), [canonicalName] is the by-design `FA_KEY_<HOST>` slot the CLI
/// would write, and the two hint fields carry the same guidance the CLI
/// prints — a host surfaces them instead of drifting onto its own
/// resolution and silently binding an empty slot.
final class HostKeyResolution {
  /// The effective slot name (env var or store slot), or null when nothing
  /// resolves. THIS is the name a host must bind its session to.
  final String? slotName;

  /// Whether [slotName] came from the process environment (true) or the
  /// secure store (false). Meaningless when [slotName] is null.
  final bool fromEnv;

  /// The canonical `FA_KEY_<HOST>` slot for the endpoint — what a fresh
  /// `/provider`-style save would write. Never null.
  final String canonicalName;

  /// The pinned-slot drift warning (the CLI's migration hint), non-null
  /// when the effective slot is a pinned twin of [canonicalName] (`<canonical>_…`
  /// — the pre-gh-1226 doubling rule or a by-design per-account pin). The
  /// twin keeps winning while it holds a value; the hint names the move.
  final String? driftHint;

  /// The missing-key guidance, non-null when [slotName] is null: names the
  /// slot a key should be stored into (mirrors the CLI's fallback hint).
  final String? missingKeyHint;

  const HostKeyResolution({
    required this.slotName,
    required this.fromEnv,
    required this.canonicalName,
    this.driftHint,
    this.missingKeyHint,
  });
}

/// The host-injectable key-slot resolver (issue #1322 Gap 2): the ONE
/// resolution chain as a pure service. Keychain/SharedPreferences access
/// stays with the host — it injects [envRead]/[storeRead] over its own
/// stores; the SDK supplies only the chain, the slot naming, and the
/// drift hints.
final class HostKeyResolver {
  /// Reads a genuine process-environment value (the host's env, dotenv,
  /// dart-defines — its choice).
  final String? Function(String name) envRead;

  /// Reads the host's secure store (Keychain / SharedPreferences-backed /
  /// in-memory). Null = store-less host (env-only resolution).
  final String? Function(String name)? storeRead;

  /// The slot names the host KNOWS about (its saved provider entries' own
  /// slots — the registry leg). A known pinned twin of the canonical
  /// (`<canonical>_…`) holding a value wins over the canonical, exactly
  /// like the CLI's saved entries pin their own slots — and produces the
  /// drift hint instead of a silently empty request.
  final Iterable<String> knownSlotNames;

  const HostKeyResolver({
    required this.envRead,
    this.storeRead,
    this.knownSlotNames = const [],
  });

  /// Resolves the effective key-slot name for [provider]/[baseUrl]. The
  /// [model] argument is accepted for call-site symmetry with host config
  /// shapes; slot selection keys on provider + endpoint only (a model
  /// never has its own slot). [envNames] and [defaultBaseUrl] are the
  /// catalog facts — omit them (the defaults) and resolution is
  /// store-only, so the env-name leg can never hijack a custom endpoint.
  /// [activeCustomKeyName] is the active custom registry entry's own slot,
  /// when the host tracks one.
  HostKeyResolution resolveKey({
    String? provider,
    required String baseUrl,
    String? model,
    List<String> envNames = const [],
    String? defaultBaseUrl,
    String? activeCustomKeyName,
  }) {
    // The HOST-scoped canonical (no provider-name suffix) — the same slot
    // resolveEndpointKeyName probes, so the drift comparison is
    // like-for-like.
    final canonical = CustomProviderRegistry.keyNameFor(baseUrl);
    final chained = resolveEndpointKeyName(
      envNames: envNames,
      defaultBaseUrl: defaultBaseUrl,
      baseUrl: baseUrl,
      envRead: envRead,
      storeRead: storeRead,
      activeCustomKeyName: activeCustomKeyName,
    );
    // The registry leg: a known pinned twin holding a value keeps winning
    // while the chain landed on the canonical (or nothing) — the same
    // precedence the CLI's saved entries get from their own keyName
    // probes. This is what turns the issue's kimi trap into a working
    // binding plus a visible warning.
    final pinnedTwin = knownSlotNames.firstWhere(
      (slot) =>
          slot != canonical &&
          slot.startsWith('${canonical}_') &&
          _hasStoreValue(slot, storeRead),
      orElse: () => '',
    );
    final name =
        pinnedTwin.isNotEmpty && (chained == null || chained == canonical)
        ? pinnedTwin
        : chained;
    final fromEnv =
        name != null &&
        name == chained &&
        envNames.contains(name) &&
        _isGenuineEnv(name, envRead, storeRead);
    String? driftHint;
    if (name != null && name != canonical && name.startsWith('${canonical}_')) {
      final twin = _hasStoreValue(canonical, storeRead);
      driftHint =
          'key slot for this endpoint is "$name"; the canonical slot is '
          '"$canonical"'
          '${twin ? ' — a same-endpoint entry already uses "$canonical"' : ' — move the value with /key set $canonical <value>'}'
          '; then /key delete $name (the pinned slot keeps winning '
          'while it holds a value)';
    }
    String? missingKeyHint;
    if (name == null) {
      missingKeyHint =
          'no key resolved for '
          '${provider == null ? baseUrl : 'provider "$provider"'} — set it '
          'with /key set $canonical <value>';
    }
    return HostKeyResolution(
      slotName: name,
      fromEnv: fromEnv,
      canonicalName: canonical,
      driftHint: driftHint,
      missingKeyHint: missingKeyHint,
    );
  }

  static bool _isGenuineEnv(
    String name,
    String? Function(String name) envRead,
    String? Function(String name)? storeRead,
  ) {
    final value = envRead(name);
    return value != null && value.isNotEmpty && value != storeRead?.call(name);
  }
}
