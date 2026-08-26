/// The custom-provider registry: user-saved providers (api type + endpoint
/// + optional key reference + last-used model) persisted in the
/// `customProviders:` section of `~/.fah/config.yaml`.
///
/// A registry entry is what the `/provider` picker lists above the catalog
/// presets and what the `/provider custom` wizard appends to; switching to
/// an entry restores its last-used model, and `/model` while an entry is
/// active writes the new model id back (per-provider model memory).
library;

import '../exceptions.dart';
import '../model_roles/provider_catalog.dart';

/// The api types a custom provider can take (the adapter dialect), mapping
/// one-to-one to catalog specs. Includes OAuth/SSO-backed catalog providers
/// (openrouter, codemie) — their connect flows save registry entries so
/// connected providers show in the `/provider` picker — and `kimi`, whose
/// `/provider kimi` key flow saves a named entry per account.
const customProviderApiTypes = [
  'openai',
  'anthropic',
  'google',
  'dial',
  'openrouter',
  'minimax',
  'kimi',
  'chatgpt',
];

/// How a saved custom provider authenticates. Distinguishes regular API-key
/// entries from SSO/JWT-backed ones (e.g. CodeMie) so the CLI can pick the
/// right auth path when switching to a saved entry.
enum CustomProviderAuthMethod {
  /// Regular API-key or env-resolved auth (default).
  apiKey,

  /// Browser-based SSO (CodeMie cookie auth).
  sso,

  /// JWT Bearer token (CodeMie headless auth).
  jwt,
}

/// One saved custom provider.
final class CustomProviderEntry {
  /// Creates an entry. [keyName] is the secure-store/env name holding the
  /// API key (null = keyless); [modelId] is the last-used model.
  /// [authMethod] selects the auth path for SSO/JWT providers.
  CustomProviderEntry({
    required this.name,
    required this.apiType,
    required this.baseUrl,
    required this.modelId,
    this.keyName,
    this.authMethod = CustomProviderAuthMethod.apiKey,
  });

  /// Parses one yaml map from the `customProviders:` list. Throws
  /// [ConfigException] on bad shapes (bad config must surface, never
  /// silently vanish).
  factory CustomProviderEntry.fromYaml(Object? node) {
    if (node is! Map) {
      throw ConfigException('customProviders entries must be maps, got: $node');
    }
    String requireString(String field) {
      final value = node[field];
      if (value is! String || value.isEmpty) {
        throw ConfigException(
          'customProviders entry needs a non-empty "$field"',
        );
      }
      return value;
    }

    final apiType = requireString('apiType');
    if (!customProviderApiTypes.contains(apiType)) {
      throw ConfigException(
        'customProviders entry "$apiType" is not a supported apiType '
        '(${customProviderApiTypes.join(', ')})',
      );
    }
    final keyName = node['keyName'];
    final authMethod = _parseAuthMethod(node['authMethod']);
    return CustomProviderEntry(
      name: requireString('name'),
      apiType: apiType,
      baseUrl: requireString('baseUrl'),
      modelId: requireString('modelId'),
      keyName: keyName is String && keyName.isNotEmpty ? keyName : null,
      authMethod: authMethod,
    );
  }

  static CustomProviderAuthMethod _parseAuthMethod(Object? value) {
    if (value is! String) return CustomProviderAuthMethod.apiKey;
    switch (value) {
      case 'sso':
        return CustomProviderAuthMethod.sso;
      case 'jwt':
        return CustomProviderAuthMethod.jwt;
      default:
        return CustomProviderAuthMethod.apiKey;
    }
  }

  /// Display/lookup name (derived from the endpoint host at creation).
  final String name;

  /// The adapter dialect: `openai`, `anthropic`, or `google` (catalog spec
  /// names, see [providerCatalog]).
  final String apiType;

  /// The endpoint base URL.
  final String baseUrl;

  /// The secure-store/env name holding the API key, or null when keyless.
  String? keyName;

  /// How this entry authenticates. Used to pick the right path when switching
  /// to saved SSO/JWT providers.
  CustomProviderAuthMethod authMethod;

  /// The last-used model id (rewritten on `/model` switches while active).
  String modelId;

  /// Serializes to the yaml section's map shape.
  Map<String, String> toYaml() {
    return {
      'name': name,
      'apiType': apiType,
      'baseUrl': baseUrl,
      'keyName': ?keyName,
      'authMethod': authMethod.name,
      'modelId': modelId,
    };
  }

  /// The catalog spec backing this entry's adapter dialect.
  ProviderSpec get spec => providerCatalog[apiType]!;
}

/// The live list of saved custom providers (shared by the CLI, which
/// mutates it, and the executable, which persists it).
final class CustomProviderRegistry {
  /// Creates a registry over [entries] (a live, mutable list).
  CustomProviderRegistry(List<CustomProviderEntry> entries)
    : entries = List.of(entries);

  /// All saved entries, in insertion order.
  final List<CustomProviderEntry> entries;

  /// Finds an entry by [name] (case-insensitive), or null.
  CustomProviderEntry? find(String name) {
    final lower = name.toLowerCase();
    for (final entry in entries) {
      if (entry.name.toLowerCase() == lower) return entry;
    }
    return null;
  }

  /// Adds (or replaces, on name clash) [entry].
  void add(CustomProviderEntry entry) {
    final existing = find(entry.name);
    if (existing != null) entries.remove(existing);
    entries.add(entry);
  }

  /// Records the last-used model for the entry named [name] (no-op when
  /// absent).
  void updateModel(String name, String modelId) {
    find(name)?.modelId = modelId;
  }

  /// Derives a unique display name from [baseUrl]'s host (and non-default
  /// port), avoiding catalog provider names and existing entries:
  /// `localhost:11434`, `api.acme.com`, `api.acme.com-2`, ...
  String deriveName(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    var host = uri?.host ?? baseUrl;
    if (host.isEmpty) host = 'custom';
    final port = uri?.port;
    final defaultPort = uri?.scheme == 'https' ? 443 : 80;
    final candidate = port != null && port != defaultPort
        ? '$host:$port'
        : host;
    return _dedupe(candidate);
  }

  String _dedupe(String candidate) {
    final reserved = <String>{'custom', ...providerCatalog.keys};
    var name = candidate;
    var suffix = 2;
    while (reserved.contains(name) || find(name) != null) {
      name = '$candidate-${suffix++}';
    }
    return name;
  }

  /// The secure-store key name backing [baseUrl]'s key:
  /// `FA_KEY_LOCALHOST_11434`, `FA_KEY_API_ACME_COM` (the store accepts
  /// `[A-Za-z0-9_]+` only). With [providerName] (a saved entry's name) the
  /// name is appended — `FA_KEY_API_KIMI_COM_WORK` — so several accounts on
  /// the same endpoint keep separate keys instead of overwriting one
  /// host-scoped entry.
  static String keyNameFor(String baseUrl, {String? providerName}) {
    final uri = Uri.tryParse(baseUrl);
    final sanitized = _sanitizeKeyHost(_hostWithPort(uri, baseUrl));
    final base = 'FA_KEY_${sanitized.isEmpty ? 'CUSTOM' : sanitized}';
    final name = providerName == null ? null : _sanitizeKeyHost(providerName);
    // A provider named after its host (the default derived name) must not
    // double the suffix: FA_KEY_API_AIIN_BY, not FA_KEY_API_AIIN_BY_API_AIIN_BY.
    return name == null || name.isEmpty || name == sanitized
        ? base
        : '${base}_$name';
  }

  /// The host part of [uri] (falling back to [baseUrl]), with a non-default
  /// port appended.
  static String _hostWithPort(Uri? uri, String baseUrl) {
    var host = uri?.host ?? baseUrl;
    if (host.isEmpty) host = 'custom';
    final port = uri?.port;
    final defaultPort = uri?.scheme == 'https' ? 443 : 80;
    if (port != null && port != defaultPort) host = '${host}_$port';
    return host;
  }

  /// Uppercased, non-alphanumerics collapsed to `_`, edge underscores
  /// trimmed.
  static String _sanitizeKeyHost(String value) {
    return value
        .toUpperCase()
        .replaceAll(RegExp('[^A-Z0-9]+'), '_')
        .replaceAll(RegExp('^_+|_+\$'), '');
  }
}
