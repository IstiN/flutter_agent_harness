/// Headless API-key resolution for the `fah` executable
/// (`bin/fah.dart`): the env/store lookup behind `fa --provider <kind>`.
///
/// `dart:io` lives here (exported only from `lib/io.dart`) so the agent core
/// stays pure Dart.
library;

import 'dart:io';

import '../model_roles/provider_catalog.dart';
import '../secrets/secure_key_store.dart';
import 'custom_providers.dart' show CustomProviderRegistry, sameEndpoint;

/// The env names that can hold [provider]'s API key: the catalog spec's
/// names ([providerCatalog]; copilot → COPILOT_GITHUB_TOKEN,
/// kimi → KIMI_API_KEY, …), plus the two non-catalog slots; unknown kinds
/// keep the historical OpenRouter/OpenAI pair.
List<String> apiKeyEnvNames(String provider) => switch (provider) {
  'vision' => const ['VISION_API_KEY'],
  'transcribe' => const ['TRANSCRIBE_API_KEY'],
  _ =>
    _keySpec(provider)?.apiKeyEnvNames ??
        const ['OPENROUTER_API_KEY', 'OPENAI_API_KEY'],
};

/// The catalog spec for a provider name OR adapter kind, via
/// [resolveCliProviderSpec] — the ONE both-identifier lookup (issue #772).
/// The kind leg matters since the restored boot provider can be a kind
/// that is not itself a catalog name — `chatgpt-codex` → the `chatgpt`
/// spec, so its key resolves from `CHATGPT_OAUTH_CREDENTIALS`. Null for
/// ids no version knows. Intentionally NOT honoring the build-time
/// provider filter: the boot-restored provider's key must resolve in
/// every build (the seam's restore-path filter stance).
ProviderSpec? _keySpec(String provider) => resolveCliProviderSpec(provider);

/// Resolves [provider]'s API key headlessly. On the catalog spec's DEFAULT
/// endpoint: a genuine environment value of the catalog env names, then
/// endpoint-scoped secure-store entries (`FA_KEY_<HOST>` — what /provider
/// writes — plus any saved custom entry's name-scoped key for this
/// endpoint), then legacy env-name store entries from older versions. On
/// ANY OTHER endpoint only the endpoint-scoped entries resolve — the
/// catalog env names describe the default endpoint and must never hijack a
/// custom one (issue #40: the user's `OPENROUTER_API_KEY` environment key
/// silently serving api.z.ai), mirroring the shared
/// [resolveEndpointKey] chain. [env] overrides Platform.environment
/// (tests).
///
/// [pinnedKeyName] (gh-1000 AC1) is the restored folder state's saved
/// provider entry's own key slot: it resolves FIRST — the environment
/// value, then the store slot — because it names the account the session
/// actually ran on. A same-endpoint twin entry (or the host-scoped slot)
/// must never win over the pin.
String? optionalProviderApiKey(
  String provider,
  SecureKeyCache keys, {
  String? baseUrl,
  Iterable<String>? scopedKeyNames,
  Map<String, String>? env,
  String? pinnedKeyName,
}) {
  final environment = env ?? Platform.environment;
  final pinned = _pinnedKeyValue(pinnedKeyName, environment, keys);
  if (pinned != null) return pinned;
  final spec = _keySpec(provider);
  // Trailing-slash-normalized (the shared sameEndpoint rule, gh-1570
  // L10): a default endpoint saved/spelled with one trailing slash must
  // not classify as CUSTOM — the catalog env names would never be probed
  // and the boot would go keyless (401).
  final customEndpoint =
      spec != null &&
      baseUrl != null &&
      baseUrl.isNotEmpty &&
      !sameEndpoint(baseUrl, spec.defaultBaseUrl);
  if (!customEndpoint) {
    final envKey = _firstEnvValue(apiKeyEnvNames(provider), environment);
    if (envKey != null) return envKey;
  }
  return _storedValueFor(
    baseUrl,
    customEndpoint,
    provider,
    keys,
    scopedKeyNames: scopedKeyNames,
  );
}

/// The pinned saved-entry slot (gh-1000 AC1) resolving FIRST: the
/// environment value, then the store — it names the account the session
/// actually ran on, so it wins over every other slot. Null without a pin
/// or when the slot is empty.
String? _pinnedKeyValue(
  String? pinnedKeyName,
  Map<String, String> environment,
  SecureKeyCache keys,
) {
  if (pinnedKeyName == null) return null;
  final pinned =
      environment[pinnedKeyName] ?? _firstStoredValue([pinnedKeyName], keys);
  if (pinned == null || pinned.isEmpty) return null;
  return pinned;
}

/// The stored half of the chain: endpoint-scoped entries on ANY endpoint,
/// then the legacy catalog env-name entries on the DEFAULT endpoint only
/// (issue #40 — the catalog names must never hijack a custom endpoint).
String? _storedValueFor(
  String? baseUrl,
  bool customEndpoint,
  String provider,
  SecureKeyCache keys, {
  Iterable<String>? scopedKeyNames,
}) {
  if (baseUrl != null) {
    final stored = _firstStoredValue([
      CustomProviderRegistry.keyNameFor(baseUrl),
      ...?scopedKeyNames,
    ], keys);
    if (stored != null) return stored;
  }
  if (customEndpoint) return null;
  return _firstStoredValue(apiKeyEnvNames(provider), keys);
}

/// The first non-empty environment value among [names], or null.
String? _firstEnvValue(List<String> names, Map<String, String> environment) {
  for (final name in names) {
    final value = environment[name];
    if (value != null && value.isNotEmpty) return value;
  }
  return null;
}

/// The first non-empty store value among [names], or null.
String? _firstStoredValue(List<String> names, SecureKeyCache keys) {
  for (final name in names) {
    final stored = keys.read(name);
    if (stored != null && stored.isNotEmpty) return stored;
  }
  return null;
}

/// One known (endpoint, record) pair the boot migration considers: a
/// saved custom registry entry or a roles chain ref's endpoint.
typedef KeySlotMigrationSource = ({
  String baseUrl,
  String? providerName,
  String? pinnedKeyName,
});

/// Boot-time migration of key slots stranded by a derivation change
/// (gh-1570 incident: fa 1.0.556 → 1.0.564 moved a roles entry's endpoint
/// spelling, and the key stored under the old slot stopped resolving).
/// For each known endpoint, when the canonical slot is EMPTY and a legacy
/// cross-spelling slot holds a value, the value is COPIED onto the
/// canonical slot — non-destructive (the legacy slot stays, so a
/// rollback keeps working) — and a notice line is returned for the boot
/// to print. Keychain explicitly in scope: [keys].save writes through to
/// the OS store; an unavailable or failing store degrades to a notice
/// (resolution still falls back to the legacy slot), never a boot
/// failure. A canonical slot that already holds a value is never touched.
Future<List<String>> migrateLegacyKeySlots(
  Iterable<KeySlotMigrationSource> migrations,
  SecureKeyCache keys,
) async {
  final notices = <String>[];
  if (!keys.available) return notices;
  for (final (:baseUrl, providerName: name, pinnedKeyName: pinned)
      in migrations) {
    final canonical =
        pinned ??
        CustomProviderRegistry.keyNameFor(baseUrl, providerName: name);
    if (keys.read(canonical) != null) continue;
    for (final legacy in CustomProviderRegistry.keySlotCandidates(
      baseUrl,
      providerName: name,
    )) {
      if (legacy == canonical) continue;
      final value = keys.read(legacy);
      if (value == null) continue;
      final copied = await keys.save(canonical, value);
      notices.add(
        copied
            ? 'migrated the API key for "$baseUrl" from legacy key slot '
                  '"$legacy" to "$canonical" (the legacy slot is kept)'
            : 'could not migrate the API key for "$baseUrl" from "$legacy" '
                  'to "$canonical" '
                  '(${keys.lastSaveError ?? 'secure store refused the write'}) '
                  '— resolution still falls back to the legacy slot',
      );
      break; // one stranded source per canonical slot
    }
  }
  return notices;
}
