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
/// one-to-one to catalog specs.
const customProviderApiTypes = ['openai', 'anthropic', 'google'];

/// One saved custom provider.
final class CustomProviderEntry {
  /// Creates an entry. [keyName] is the secure-store/env name holding the
  /// API key (null = keyless); [modelId] is the last-used model.
  CustomProviderEntry({
    required this.name,
    required this.apiType,
    required this.baseUrl,
    required this.modelId,
    this.keyName,
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
    return CustomProviderEntry(
      name: requireString('name'),
      apiType: apiType,
      baseUrl: requireString('baseUrl'),
      modelId: requireString('modelId'),
      keyName: keyName is String && keyName.isNotEmpty ? keyName : null,
    );
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

  /// The last-used model id (rewritten on `/model` switches while active).
  String modelId;

  /// Serializes to the yaml section's map shape.
  Map<String, String> toYaml() {
    return {
      'name': name,
      'apiType': apiType,
      'baseUrl': baseUrl,
      'keyName': ?keyName,
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
  /// `[A-Za-z0-9_]+` only).
  static String keyNameFor(String baseUrl) {
    final uri = Uri.tryParse(baseUrl);
    var host = uri?.host ?? baseUrl;
    if (host.isEmpty) host = 'custom';
    final port = uri?.port;
    final defaultPort = uri?.scheme == 'https' ? 443 : 80;
    if (port != null && port != defaultPort) host = '${host}_$port';
    final sanitized = host
        .toUpperCase()
        .replaceAll(RegExp('[^A-Z0-9]+'), '_')
        .replaceAll(RegExp('^_+|_+\$'), '');
    return 'FA_KEY_${sanitized.isEmpty ? 'CUSTOM' : sanitized}';
  }
}
