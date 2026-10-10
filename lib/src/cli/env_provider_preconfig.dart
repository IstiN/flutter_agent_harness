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

import '../exceptions.dart';
import '../model_roles/capability_resolver.dart';
import '../model_roles/provider_catalog.dart';
import '../providers/thinking.dart';

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
    this.input,
    this.thinkingLevel,
    this.contextWindow,
    this.maxTokens,
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

  /// Declared input modalities (`["text","image"]`) or null when the
  /// config declares none — the catalog spec's modalities stand (issue
  /// #638: an explicit declaration wins, silence keeps today's behavior).
  final List<String>? input;

  /// The declared thinking level, normalized to its ladder rung
  /// (`xhigh`/`max` fold to `high`), or null when undeclared — no
  /// thinking requested and the boot behaves byte-identically to before
  /// (issue #734).
  final String? thinkingLevel;

  /// Declared context window in tokens (gh-1471 D4), or null when
  /// undeclared — the catalog/endpoint layers stand, exactly as before.
  /// Riding the resolver's override layer, a declared value wins over
  /// every layer below it (bench's kimi mapping pins 200000 so a catalog
  /// drift can never silently truncate the served window).
  final int? contextWindow;

  /// Declared max output tokens (gh-1471 D4), or null when undeclared —
  /// the ceiling table/spec layers stand, exactly as before.
  final int? maxTokens;
}

/// The supported `FA_PROVIDER_CONFIG` keys, in error-message order.
const _supportedConfigKeys = [
  'baseUrl',
  'model',
  'apiKeyEnvVar',
  'contextWindow',
  'maxTokens',
  'input',
  'thinkingLevel',
];

/// The keys an env-declared provider MUST spell out — a missing one is a
/// misconfiguration, never a silent catalog default.
const _requiredConfigKeys = ['baseUrl', 'model'];

/// Parses the `FA_PROVIDER_*` preconfig, or returns null when the feature
/// is off ([providerType] null/blank).
///
/// Throws [ConfigException] naming the offending input for every invalid
/// value: an unknown provider type, a missing/empty `FA_PROVIDER_CONFIG`,
/// malformed or non-object config JSON (plain or base64 twin), an unknown
/// config key, a missing required `baseUrl`/`model`, a non-integer or
/// below-floor `contextWindow`/`maxTokens` (gh-1471 D4), and a declared
/// key env var (or its `_BASE64` twin) left empty. Nothing falls back to
/// the catalog spec values.
EnvProviderPreconfig? parseEnvProviderPreconfig({
  required String? providerType,
  required String? providerName,
  required String? providerConfig,
  required String? providerConfigBase64,
  required String? Function(String name) envVarValue,
  required Iterable<String> takenNames,
}) {
  if (providerType == null || providerType.trim().isEmpty) return null;
  // Resolution goes through the one both-identifier seam (issue #772),
  // honoring the FA_PROVIDERS build filter — exactly what the switch-time
  // and validation surfaces do.
  final spec = resolveCliProviderSpec(providerType, honorBuildFilter: true);
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
    if (!config.values.containsKey(key)) {
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
  final ref = config.values['apiKeyEnvVar'];
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
    baseUrl: config.values['baseUrl']!,
    modelId: config.values['model']!,
    apiKeyEnvVar: keyVar,
    apiKey: apiKey,
    input: config.input,
    thinkingLevel: config.thinkingLevel,
    contextWindow: config.contextWindow,
    maxTokens: config.maxTokens,
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
/// [_supportedConfigKeys] allowed; string values with blanks treated as
/// absent, except `input`, a non-empty list of `"text"`/`"image"` (issue
/// #638 — validated by the same named-error rules as the `models.custom`
/// yaml field), and `contextWindow`/`maxTokens`, JSON integers at or
/// above the resolver floors (gh-1471 D4: a capability declaration is
/// explicit or absent — never a silent catalog default). The caller
/// guarantees a non-empty declaration.
({
  Map<String, String> values,
  List<String>? input,
  String? thinkingLevel,
  int? contextWindow,
  int? maxTokens,
})
_parseConfig(String raw) {
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
  // One mutable accumulator so the per-entry routing ([_takeConfigEntry])
  // stays a plain branch on the key — _parseConfig itself carries only
  // the shape checks (the CRAP ratchet counts every branch).
  final parsed = _ParsedConfig();
  for (final entry in decoded.entries) {
    // jsonDecode produces string keys for JSON objects.
    _takeConfigEntry(entry.key as String, entry.value, parsed);
  }
  return (
    values: parsed.values,
    input: parsed.input,
    thinkingLevel: parsed.thinkingLevel,
    contextWindow: parsed.contextWindow,
    maxTokens: parsed.maxTokens,
  );
}

/// The mutable destination for [_takeConfigEntry]: the plain string
/// values plus each typed, validated optional field.
final class _ParsedConfig {
  final Map<String, String> values = {};
  List<String>? input;
  String? thinkingLevel;
  int? contextWindow;
  int? maxTokens;
}

/// Routes one `FA_PROVIDER_CONFIG` entry to its typed parser, writing
/// the result into [into]: the structured keys delegate to their
/// validators, everything else is a required-shape plain string (blank =
/// absent, like every other text value).
void _takeConfigEntry(String key, Object? value, _ParsedConfig into) {
  if (!_supportedConfigKeys.contains(key)) {
    throw ConfigException(
      'unknown FA_PROVIDER_CONFIG key: "$key" — supported keys: '
      '${_supportedConfigKeys.join(', ')}',
    );
  }
  switch (key) {
    case 'input':
      into.input = _parseInputList(value);
    case 'thinkingLevel':
      into.thinkingLevel = _parseThinkingLevel(value);
    case 'contextWindow' || 'maxTokens':
      final parsed = _parseCapabilityInt(key, value);
      if (parsed != null) {
        if (key == 'contextWindow') {
          into.contextWindow = parsed;
        } else {
          into.maxTokens = parsed;
        }
      }
    default:
      if (value is! String) {
        throw ConfigException(
          'FA_PROVIDER_CONFIG key "$key" must be a string, got: $value',
        );
      }
      if (value.trim().isNotEmpty) into.values[key] = value;
  }
}

/// One `contextWindow`/`maxTokens` declaration: a JSON integer at or
/// above the resolver floor ([minOverrideContextWindow] /
/// [minOverrideMaxTokens] — the same boundary floors as the yaml
/// `models.overrides` layer; a declaration below the floor would strand
/// the compaction reserve / the answer budget). Null / blank-string
/// values are ABSENT, like every other optional input; a non-integer or
/// below-floor value fails loud naming the key.
int? _parseCapabilityInt(String key, Object? value) {
  if (value == null) return null;
  if (value is String && value.trim().isEmpty) return null;
  if (value is! int) {
    throw ConfigException(
      'FA_PROVIDER_CONFIG "$key" must be an integer, got: $value',
    );
  }
  final floor = key == 'contextWindow'
      ? minOverrideContextWindow
      : minOverrideMaxTokens;
  if (value < floor) {
    throw ConfigException(
      'FA_PROVIDER_CONFIG "$key" must be at least $floor '
      '(the ${key == 'contextWindow' ? 'compaction reserve' : 'answer budget'}'
      ' floor), got: $value',
    );
  }
  return value;
}

/// The `input` modality list: a non-empty JSON array whose entries are
/// exactly `"text"` or `"image"` — anything else fails loud naming the
/// key and the offending entry.
List<String> _parseInputList(Object? value) {
  if (value is! List || value.isEmpty) {
    throw ConfigException(
      'FA_PROVIDER_CONFIG "input" must be a non-empty list of '
      '"text"/"image", got: $value',
    );
  }
  return [
    for (final entry in value)
      if (entry is String && (entry == 'text' || entry == 'image'))
        entry
      else
        throw ConfigException(
          'FA_PROVIDER_CONFIG "input" entries must be "text" or "image", '
          'got: $entry',
        ),
  ];
}

/// The `thinkingLevel` rung (issue #734): one of [configThinkingLevels] —
/// `xhigh`/`max` are accepted and normalize to `high`, anything else fails
/// loud naming the ladder. A blank string is absent, like every other text
/// value.
String? _parseThinkingLevel(Object? value) {
  if (value is! String) {
    throw ConfigException(
      'FA_PROVIDER_CONFIG "thinkingLevel" must be one of '
      '${configThinkingLevels.join(', ')}, got: $value',
    );
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  return normalizeConfigThinkingLevel(trimmed) ??
      (throw ConfigException(
        'FA_PROVIDER_CONFIG "thinkingLevel" must be one of '
        '${configThinkingLevels.join(', ')}, got: $value',
      ));
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
