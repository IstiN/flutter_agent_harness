/// Headless API-key resolution for the `fah` executable
/// (`bin/fah.dart`): the env/store lookup behind `fa --provider <kind>`.
///
/// `dart:io` lives here (exported only from `lib/io.dart`) so the agent core
/// stays pure Dart.
library;

import 'dart:io';

import '../model_roles/provider_catalog.dart';
import '../secrets/secure_key_store.dart';
import 'custom_providers.dart';

/// The env names that can hold [provider]'s API key: the catalog spec's
/// names ([providerCatalog]; copilot → COPILOT_GITHUB_TOKEN,
/// kimi → KIMI_API_KEY, …), plus the two non-catalog slots; unknown kinds
/// keep the historical OpenRouter/OpenAI pair.
List<String> apiKeyEnvNames(String provider) => switch (provider) {
  'vision' => const ['VISION_API_KEY'],
  'transcribe' => const ['TRANSCRIBE_API_KEY'],
  _ =>
    providerCatalog[provider]?.apiKeyEnvNames ??
        const ['OPENROUTER_API_KEY', 'OPENAI_API_KEY'],
};

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
String? optionalProviderApiKey(
  String provider,
  SecureKeyCache keys, {
  String? baseUrl,
  Iterable<String>? scopedKeyNames,
  Map<String, String>? env,
}) {
  final environment = env ?? Platform.environment;
  final names = apiKeyEnvNames(provider);
  final spec = catalogProvider(provider);
  final customEndpoint =
      spec != null && baseUrl != null && baseUrl != spec.defaultBaseUrl;
  if (!customEndpoint) {
    for (final name in names) {
      final value = environment[name];
      if (value != null && value.isNotEmpty) return value;
    }
  }
  if (baseUrl != null) {
    final candidates = [
      CustomProviderRegistry.keyNameFor(baseUrl),
      ...?scopedKeyNames,
    ];
    for (final name in candidates) {
      final stored = keys.read(name);
      if (stored != null && stored.isNotEmpty) return stored;
    }
  }
  if (!customEndpoint) {
    for (final name in names) {
      final stored = keys.read(name);
      if (stored != null && stored.isNotEmpty) return stored;
    }
  }
  return null;
}
