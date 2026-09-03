/// The `FA_PROVIDER_*` env preconfig: headless/Docker runs pass provider
/// configuration at container start as environment variables
/// (`FA_PROVIDER_TYPE`, `FA_PROVIDER_NAME`, plus `FA_PROVIDER_CONFIG` — or
/// its `FA_PROVIDER_CONFIG_BASE64` twin) plus the key itself in the env
/// var the config references (or that var's `_BASE64` twin), and the
/// harness boots that provider with no saved config. The declaration is
/// machine-written and self-contained: what it declares is what is used —
/// no catalog-guessed defaults, no env-name probing.
///
/// Precedence (wired by the host): an explicit `--provider` flag wins,
/// then this preconfig, then the saved config restore, then the catalog
/// env auto-pick, then the default. Env values arrive via an injected
/// reader function so this module stays pure Dart (no `dart:io`) and is
/// directly unit-testable.
library;

import 'dart:convert';

import 'package:flutter_sandbox/flutter_sandbox.dart';
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

  /// The endpoint base URL (required `baseUrl` config value — the catalog
  /// default is never a stand-in for an undeclared one).
  final String baseUrl;

  /// The boot model id (required `model` config value — the catalog
  /// default is never a stand-in for an undeclared one).
  final String modelId;

  /// The env var the API key was read from, or null when the config
  /// declares no `apiKeyEnvVar` (keyless boot; absent means absent — the
  /// spec's env names are never probed).
  final String? apiKeyEnvVar;

  /// The API key for the booted session — the env value (or its `_BASE64`
  /// twin) wins over any stored key. Empty for legitimate keyless
  /// endpoints.
  final String apiKey;
}

/// The supported `FA_PROVIDER_CONFIG` keys, in error-message order.
const _supportedConfigKeys = ['baseUrl', 'model', 'apiKeyEnvVar'];

/// The keys an env-declared provider MUST spell out — a missing one is a
/// misconfiguration, never a silent catalog default.
const _requiredConfigKeys = ['baseUrl', 'model'];

/// Parses the `FA_PROVIDER_*` preconfig, or returns null when the feature
/// is off ([providerType] null/blank).
///
/// Throws [ConfigException] naming the offending input for every invalid
/// value: an unknown provider type, a missing/empty `FA_PROVIDER_CONFIG`,
/// malformed or non-object config JSON (plain or base64 twin), an unknown
/// config key, a missing required `baseUrl`/`model`, and a declared key
/// env var (or its `_BASE64` twin) left empty. Nothing falls back to the
/// catalog spec values.
EnvProviderPreconfig? parseEnvProviderPreconfig({
  required String? providerType,
  required String? providerName,
  required String? providerConfig,
  required String? providerConfigBase64,
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

  final declared = _resolveTwin(
    'FA_PROVIDER_CONFIG',
    providerConfig,
    'FA_PROVIDER_CONFIG_BASE64',
    providerConfigBase64,
  );
  if (declared == null) {
    throw ConfigException(
      'FA_PROVIDER_CONFIG is required when FA_PROVIDER_TYPE is set — '
      'declare at least '
      '${_requiredConfigKeys.map((key) => '"$key"').join(' and ')}',
    );
  }
  final config = _parseConfig(declared);
  for (final key in _requiredConfigKeys) {
    if (!config.containsKey(key)) {
      throw ConfigException(
        'FA_PROVIDER_CONFIG is missing "$key" — an env-declared provider '
        'gets no catalog defaults; required keys: '
        '${_requiredConfigKeys.join(', ')}',
      );
    }
  }

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

  // `apiKeyEnvVar` is optional but strict when declared: the named env
  // var (or its `_BASE64` twin) MUST resolve to a non-empty key. Absent
  // means a legitimate keyless boot — no probing of the spec's env names
  // (an unnamed key source is exactly the silent misconfiguration class
  // this parser exists to prevent).
  final ref = config['apiKeyEnvVar'];
  final String? keyVar;
  final String apiKey;
  if (ref == null) {
    keyVar = null;
    apiKey = '';
  } else {
    final value =
        _resolveTwin(
          ref,
          envVarValue(ref),
          '${ref}_BASE64',
          envVarValue('${ref}_BASE64'),
        ) ??
        '';
    if (value.isEmpty) {
      throw ConfigException(
        'FA_PROVIDER_CONFIG apiKeyEnvVar "$ref" names an env variable that '
        'is empty or missing — set it before starting the harness',
      );
    }
    keyVar = ref;
    apiKey = value;
  }

  return EnvProviderPreconfig(
    spec: spec,
    name: name,
    baseUrl: config['baseUrl']!,
    modelId: config['model']!,
    apiKeyEnvVar: keyVar,
    apiKey: apiKey,
  );
}

/// Resolves a text input against its `_BASE64` twin: the plain value wins
/// when set (non-empty); otherwise the twin is base64-decoded. Returns
/// null when neither is set. Both set: the twin must decode to exactly
/// the plain value — same value is fine, anything else is ambiguous and
/// fails loud instead of picking one silently. Malformed base64 fails
/// loud naming the variable.
String? _resolveTwin(
  String name,
  String? plain,
  String twinName,
  String? twin,
) {
  final plainSet = plain != null && plain.trim().isNotEmpty;
  final twinSet = twin != null && twin.trim().isNotEmpty;
  if (!plainSet && !twinSet) return null;
  if (!twinSet) return plain;
  final decoded = _decodeBase64(twinName, twin);
  if (!plainSet) return decoded;
  if (plain != decoded) {
    throw ConfigException(
      '$name and $twinName are both set with different values — ambiguous; '
      'set only one (when both carry the same value either may be used)',
    );
  }
  return plain;
}

/// Base64-decodes [encoded] (whitespace stripped first — some CI
/// platforms wrap long values), naming [name] on failure.
String _decodeBase64(String name, String encoded) {
  final compacted = encoded.replaceAll(RegExp(r'\s'), '');
  try {
    return utf8.decode(base64.decode(compacted));
  } on FormatException catch (error) {
    throw ConfigException('$name is not valid base64: $error');
  }
}

/// Decodes `FA_PROVIDER_CONFIG`: strict JSON-object parsing — only
/// [_supportedConfigKeys] allowed, string values only, blanks treated as
/// absent. The caller guarantees a non-empty declaration.
Map<String, String> _parseConfig(String raw) {
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
