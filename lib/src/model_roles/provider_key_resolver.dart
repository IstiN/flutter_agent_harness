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
  if (baseUrl == defaultBaseUrl) {
    // 1. A genuine environment value (differs from the stored entry).
    for (final name in envNames) {
      final value = envRead(name);
      if (value != null && value.isNotEmpty && value != storeRead?.call(name)) {
        return value;
      }
    }
    // 2. The endpoint-scoped store entry.
    final scoped = storeRead?.call(CustomProviderRegistry.keyNameFor(baseUrl));
    if (scoped != null && scoped.isNotEmpty) return scoped;
    // 3. Legacy env-name store entries.
    for (final name in envNames) {
      final value = storeRead?.call(name);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }
  // Any other endpoint: only endpoint-scoped store keys.
  if (activeCustomKeyName != null) {
    final value = storeRead?.call(activeCustomKeyName);
    if (value != null && value.isNotEmpty) return value;
  }
  final scoped = storeRead?.call(CustomProviderRegistry.keyNameFor(baseUrl));
  return scoped != null && scoped.isNotEmpty ? scoped : null;
}
