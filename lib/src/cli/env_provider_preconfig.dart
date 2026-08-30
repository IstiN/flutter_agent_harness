/// The `FA_PROVIDER_*` env preconfig: headless/Docker runs pass provider
/// configuration at container start as three environment variables
/// (`FA_PROVIDER_TYPE`, `FA_PROVIDER_NAME`, `FA_PROVIDER_CONFIG`) plus the
/// key itself in the referenced env var, and the harness boots that
/// provider with no saved config.
///
/// Precedence (wired by the host): an explicit `--provider` flag wins,
/// then this preconfig, then the saved config restore, then the catalog
/// env auto-pick, then the default. Env values arrive via an injected
/// reader function so this module stays pure Dart (no `dart:io`) and is
/// directly unit-testable.
library;

import 'dart:convert';

import '../exceptions.dart';
import '../model_roles/provider_catalog.dart';

/// One resolved `FA_PROVIDER_*` preconfig: the catalog spec the type maps
/// to plus the boot-ready name/endpoint/model/key tuple.
final class EnvProviderPreconfig {
  /// Creates a resolved preconfig.
  const EnvProviderPreconfig({
    required this.spec,
    required this.name,
    required this.baseUrl,
    required this.modelId,
    required this.apiKeyEnvVar,
    required this.apiKey,
  });

  /// The catalog spec [parseEnvProviderPreconfig] resolved the type
  /// against.
  final ProviderSpec spec;

  /// The unique entry name — defaults to the type, auto-suffixed `-2`,
  /// `-3`, ... on collision with a saved entry or another catalog
  /// provider name.
  final String name;

  /// The endpoint base URL (`baseUrl` config or the spec default).
  final String baseUrl;

  /// The boot model id (`model` config or the catalog default for the
  /// type).
  final String modelId;

  /// The env var the API key was read from, or null when the key came
  /// from the spec's default env names (or no key was found at all).
  final String? apiKeyEnvVar;

  /// The API key for the booted session — the env value wins over any
  /// stored key. Empty for legitimate keyless endpoints.
  final String apiKey;
}

/// The supported `FA_PROVIDER_CONFIG` keys, in error-message order.
const _supportedConfigKeys = ['baseUrl', 'model', 'apiKeyEnvVar'];

/// Parses the `FA_PROVIDER_*` preconfig, or returns null when the feature
/// is off ([providerType] null/blank).
///
/// Throws [ConfigException] naming the offending input for every invalid
/// value: an unknown provider type, malformed or non-object
/// `FA_PROVIDER_CONFIG`, an unknown config key, a named key env var left
/// empty, and a type with neither an explicit nor a catalog default model.
EnvProviderPreconfig? parseEnvProviderPreconfig({
  required String? providerType,
  required String? providerName,
  required String? providerConfig,
  required String? Function(String name) envVarValue,
  required Iterable<String> takenNames,
}) {
  if (providerType == null || providerType.trim().isEmpty) return null;
  final spec = catalogProvider(providerType);
  if (spec == null) {
    throw ConfigException(
      'unknown FA_PROVIDER_TYPE "$providerType" — supported providers: '
      '${enabledProviderNames().join(', ')}',
    );
  }

  final config = _parseConfig(providerConfig);

  // The entry name must not shadow a saved registry entry or another
  // catalog provider: auto-resolve `-2`, `-3`, ... to the first free
  // suffix. The resolved spec's own name is exempt — the default name
  // (== the type) is that provider's canonical identity, not a collision.
  final requested = (providerName ?? '').trim();
  final catalogNames = providerCatalog.keys.toSet()..remove(spec.name);
  final name = _uniqueName(requested.isEmpty ? spec.name : requested, {
    ...takenNames,
    ...catalogNames,
  });

  // An explicit ref wins; a set-but-empty ref means the container is
  // misconfigured — fail loud instead of silently booting keyless.
  final ref = config['apiKeyEnvVar'];
  final String? keyVar;
  final String apiKey;
  if (ref != null) {
    final value = envVarValue(ref) ?? '';
    if (value.isEmpty) {
      throw ConfigException(
        'FA_PROVIDER_CONFIG apiKeyEnvVar "$ref" names an env variable that '
        'is empty or missing — set it before starting the harness',
      );
    }
    keyVar = ref;
    apiKey = value;
  } else {
    // No ref: the first non-empty spec env name wins; none found means a
    // legitimate keyless endpoint, not an error.
    keyVar = null;
    apiKey =
        spec.apiKeyEnvNames
            .map(envVarValue)
            .firstWhere(
              (value) => (value ?? '').isNotEmpty,
              orElse: () => null,
            ) ??
        '';
  }

  final modelId = config['model'] ?? catalogDefaultModelId(spec.name);
  if (modelId == null) {
    throw ConfigException(
      'provider "${spec.name}" has no default model — set "model" in '
      'FA_PROVIDER_CONFIG',
    );
  }

  return EnvProviderPreconfig(
    spec: spec,
    name: name,
    baseUrl: config['baseUrl'] ?? spec.defaultBaseUrl,
    modelId: modelId,
    apiKeyEnvVar: keyVar,
    apiKey: apiKey,
  );
}

/// Decodes `FA_PROVIDER_CONFIG`: blank means no overrides; otherwise
/// strict JSON-object parsing — only [_supportedConfigKeys] allowed,
/// string values only, blanks treated as absent.
Map<String, String> _parseConfig(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const {};
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException catch (e) {
    throw ConfigException('FA_PROVIDER_CONFIG is not valid JSON: $e');
  }
  if (decoded is! Map) {
    throw ConfigException(
      'FA_PROVIDER_CONFIG must be a JSON object, got: $raw',
    );
  }
  final config = <String, String>{};
  for (final entry in decoded.entries) {
    // jsonDecode produces string keys for JSON objects.
    final key = entry.key as String;
    if (!_supportedConfigKeys.contains(key)) {
      throw ConfigException(
        'unknown FA_PROVIDER_CONFIG key: "$key" — supported keys: '
        '${_supportedConfigKeys.join(', ')}',
      );
    }
    final value = entry.value;
    if (value is! String) {
      throw ConfigException(
        'FA_PROVIDER_CONFIG key "$key" must be a string, got: $value',
      );
    }
    if (value.trim().isNotEmpty) config[key] = value;
  }
  return config;
}

/// The first name among [base], `[base]-2`, `[base]-3`, ... not in
/// [taken] — the env preconfig auto-resolve for name collisions.
String _uniqueName(String base, Set<String> taken) {
  if (!taken.contains(base)) return base;
  var n = 2;
  while (taken.contains('$base-$n')) {
    n++;
  }
  return '$base-$n';
}
